import Foundation
import Observation
import TrafficModel

/// Cầu nối engine (NIO event loop, phát `TrafficEvent` qua `AsyncStream`) và
/// UI (SwiftUI, đọc `transactions`/`filtered` trên MainActor).
///
/// Toàn bộ logic quyết định performance của UI nằm ở đây: `enqueue` KHÔNG
/// bao giờ chạm `transactions` — event được gom vào `pending` và chỉ áp
/// dụng khi `flushNow()` chạy (mỗi 100 ms qua `consume(_:)`, hoặc ngay lập
/// tức khi test gọi trực tiếp). Một trang web nặng có thể phát vài trăm
/// event mỗi giây; cập nhật mảng observable theo từng event sẽ làm UI đứng
/// hình bất kể lớp hiển thị là gì.
@MainActor
@Observable
public final class TrafficStore {
    public private(set) var transactions: [Transaction] = []
    public var searchText: String = ""
    public var methodFilter: String?

    /// id -> vị trí trong `transactions`. Được xây lại toàn bộ mỗi lần
    /// eviction dịch chuyển mảng — xem `evictIfNeeded()`.
    private var index: [UUID: Int] = [:]
    private var pending: [TrafficEvent] = []
    private let capacity: Int

    public init(capacity: Int = 5000) {
        self.capacity = capacity
    }

    public var filtered: [Transaction] {
        guard !searchText.isEmpty || methodFilter != nil else { return transactions }
        let needle = searchText.lowercased()
        return transactions.filter { transaction in
            if let methodFilter, transaction.request.method != methodFilter { return false }
            guard !needle.isEmpty else { return true }
            return transaction.request.url.absoluteString.lowercased().contains(needle)
        }
    }

    /// Gom event vào hàng chờ. KHÔNG chạm mảng observable.
    public func enqueue(_ event: TrafficEvent) {
        pending.append(event)
    }

    /// Áp toàn bộ event đang chờ vào `transactions` trong một lần cập nhật
    /// observable duy nhất, rồi evict nếu cần. Test gọi thẳng hàm này thay
    /// vì chờ timer — không có sleep nào trong test.
    public func flushNow() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        for event in batch { apply(event) }
        evictIfNeeded()
    }

    /// Tiêu thụ stream của engine, flush mỗi 100 ms. Trả về `Task` để nơi
    /// gọi (`AppModel`, Task 11) huỷ khi view biến mất: `for await` trên
    /// `AsyncStream` đã cancellation-aware sẵn (đã kiểm chứng thực nghiệm
    /// trên toolchain này) — huỷ `Task` này khiến vòng lặp thoát ngay, không
    /// cần tự kiểm `Task.isCancelled` trong thân vòng lặp.
    ///
    /// Stream cũng tự kết thúc khi `ProxyServer.shutdown()` chạy xong (nó gọi
    /// `continuation.finish()`), nên vòng lặp `for await` dưới đây thoát ra
    /// bình thường mà `AppModel` không bắt buộc phải huỷ `Task` này — huỷ vẫn
    /// an toàn (idempotent) cho trường hợp `stop()` được gọi khi consumer
    /// muốn dừng ngay, không đợi shutdown xong.
    public func consume(_ events: AsyncStream<TrafficEvent>) -> Task<Void, Never> {
        Task { @MainActor in
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self.flushNow()
                }
            }
            defer { ticker.cancel() }
            for await event in events {
                self.enqueue(event)
            }
            self.flushNow()
        }
    }

    public func clear() {
        for transaction in transactions { deleteSpilledBodies(of: transaction) }
        transactions = []
        index = [:]
        pending = []
    }

    /// Áp một event vào `transactions`. Cả bốn case còn lại ngoài
    /// `.started` đều chỉ chạm transaction đã tồn tại qua `index`; nếu id
    /// chưa từng thấy, event bị BỎ QUA thay vì bịa ra một `Transaction` giả.
    ///
    /// Lý do: `ProxyServer` dựng stream với `.bufferingNewest(10_000)`,
    /// nghĩa là dưới tải nặng nó rớt phần tử CŨ NHẤT trước — `.started`
    /// của một transaction có thể bị rớt trong khi `.completed`/`.failed`
    /// của chính nó sống sót. Một event kết thúc cho id lạ không có nghĩa
    /// "chưa từng tunnelled" hay bất kỳ suy luận nào khác — nó chỉ có
    /// nghĩa "ta chưa từng thấy request này", và ta không có đủ dữ liệu
    /// (scheme/host/port/request) để dựng một `Transaction` trung thực từ
    /// một event kết thúc. Bịa ra các trường đó sẽ tạo một dòng sai còn tệ
    /// hơn im lặng bỏ qua, nên lựa chọn ở đây là bỏ qua.
    private func apply(_ event: TrafficEvent) {
        switch event {
        case .started(let transaction):
            index[transaction.id] = transactions.count
            transactions.append(transaction)

        case .responseHead(let id, let response):
            guard let position = index[id] else { return }
            transactions[position].response = response

        case .requestBody(let id, let payload):
            guard let position = index[id] else { return }
            transactions[position].request.body = payload

        case .bytesRelayed(let id, let sent, let received):
            guard let position = index[id] else { return }
            // Gán chứ không cộng dồn: event này được phát ĐÚNG MỘT LẦN với
            // tổng cuối cùng (xem `TunnelReporter.legClosed`), nên cộng dồn ở
            // đây sẽ nhân đôi con số nếu event bị áp lại vì bất cứ lý do gì.
            transactions[position].bytesSent = sent
            transactions[position].bytesReceived = received

        case .completed(let id, let response, let endedAt):
            guard let position = index[id] else { return }
            transactions[position].response = response
            transactions[position].endedAt = endedAt
            transactions[position].state = .completed

        case .failed(let id, let message, let endedAt):
            guard let position = index[id] else { return }
            transactions[position].endedAt = endedAt
            transactions[position].state = .failed(reason: message)
        }
    }

    private func evictIfNeeded() {
        guard transactions.count > capacity else { return }
        // Cắt theo lô 10% thay vì từng cái một: reindex là O(n), làm mỗi
        // transaction mới sẽ đốt CPU vô ích ở trạng thái đầy.
        let overflow = transactions.count - capacity
        let dropCount = min(transactions.count, max(overflow, capacity / 10))

        for transaction in transactions.prefix(dropCount) {
            deleteSpilledBodies(of: transaction)
        }
        transactions.removeFirst(dropCount)

        index.removeAll(keepingCapacity: true)
        for (position, transaction) in transactions.enumerated() {
            index[transaction.id] = position
        }
    }

    /// Xoá file body đã spill ra đĩa của một transaction sắp biến mất khỏi
    /// store (evict hoặc `clear()`). Bỏ bước này nghĩa là leak đĩa suốt
    /// đời phiên chạy — file tạm không ai khác dọn.
    private func deleteSpilledBodies(of transaction: Transaction) {
        deleteSpilledBody(transaction.request.body)
        if let responseBody = transaction.response?.body {
            deleteSpilledBody(responseBody)
        }
    }

    private func deleteSpilledBody(_ payload: BodyPayload) {
        if case .file(let url, _) = payload {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
