import Foundation

/// Bọc thao tác ghi/đóng file thật thành closure, chỉ để test có seam thay
/// bằng bản giả mô phỏng ghi giữa chừng thất bại (đĩa đầy) mà không cần đụng
/// hệ thống file thật. Không phải một abstraction filesystem tổng quát —
/// chỉ hai thao tác BodyCollector cần.
struct BodyCollectorWriteHandle {
    let write: (Data) throws -> Void
    let close: () throws -> Void
}

/// Tích luỹ byte của một body. Dưới ngưỡng thì giữ RAM, vượt thì spill ra đĩa.
///
/// Không `Sendable` một cách có chủ ý: mỗi instance chỉ sống trong một
/// ChannelHandler và chỉ được chạm trên event loop của channel đó.
public final class BodyCollector {
    private let limit: Int
    private let spillDirectory: URL
    private var buffer = Data()
    private var totalBytes = 0
    private var fileURL: URL?
    private var handle: BodyCollectorWriteHandle?
    private var spillFailed = false

    /// Seam nội bộ cho test (xem `BodyCollectorWriteHandle`). Mặc định mở
    /// `FileHandle` thật; không mở rộng ra public API.
    var openWriteHandle: (URL) throws -> BodyCollectorWriteHandle = { url in
        let fileHandle = try FileHandle(forWritingTo: url)
        return BodyCollectorWriteHandle(
            write: { try fileHandle.write(contentsOf: $0) },
            close: { try fileHandle.close() }
        )
    }

    public init(limit: Int, spillDirectory: URL) {
        self.limit = limit
        self.spillDirectory = spillDirectory
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        totalBytes += data.count
        guard !spillFailed else { return }   // đã hỏng: chỉ còn đếm byte, không thu nội dung nữa

        if handle != nil {
            write(data)
            return
        }
        if buffer.count + data.count <= limit {
            buffer.append(data)
            return
        }
        startSpilling(with: data)
    }

    public func finish() -> BodyPayload {
        try? handle?.close()
        handle = nil

        if spillFailed { return .truncated(buffer, totalBytes: totalBytes) }
        if let fileURL { return .file(fileURL, totalBytes: totalBytes) }
        return buffer.isEmpty ? .none : .inMemory(buffer)
    }

    private func startSpilling(with data: Data) {
        let url = spillDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(
                at: spillDirectory, withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try openWriteHandle(url)
            try handle.write(buffer)
            try handle.write(data)
            self.handle = handle
            self.fileURL = url
            self.buffer = Data()            // đã nằm trên đĩa, nhả RAM
        } catch {
            // Lỗi xảy ra trước dòng `self.buffer = Data()` ở trên, nên buffer
            // vẫn giữ nguyên phần đầu thật -> .truncated đúng hợp đồng: giữ
            // phần đầu, totalBytes vẫn là con số thật.
            spillFailed = true
        }
    }

    private func write(_ data: Data) {
        do {
            try handle?.write(data)
        } catch {
            // Phần đầu đã nằm trên đĩa và buffer đã rỗng từ lúc spill thành công
            // (nhả RAM ngay), nên hai lựa chọn còn lại đều tệ: (1) chỉ nil hoá
            // fileURL sẽ mồ côi file dở vĩnh viễn — không ai còn URL để dọn nó,
            // hoặc (2) giữ lại `data` vừa lỗi rồi trả về như phần "đầu" thì thực
            // ra đó là byte GIỮA/CUỐI của stream, sai hợp đồng của `.truncated`.
            // Nên: xoá file dở, trả rỗng tay — thà thừa nhận không còn giữ nội
            // dung nào hơn là giả làm phần đầu bằng phần đuôi. `totalBytes` vẫn
            // là con số thật vì nó được cộng dồn độc lập ở `append`.
            try? handle?.close()
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            handle = nil
            fileURL = nil
            spillFailed = true
        }
    }
}
