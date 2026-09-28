// Sources/SystemProxy/SystemProxyController.swift
import Foundation

/// Điều phối việc đặt/gỡ proxy trên NHIỀU dịch vụ, và quản file snapshot.
///
/// Đặt lên tất cả dịch vụ đang hoạt động chứ không chỉ dịch vụ chính: macOS
/// chỉ đọc cấu hình của dịch vụ chính, nhưng dịch vụ nào là chính thì đổi
/// theo thời gian — bật VPN là đổi, rút cáp là đổi. Đặt lên tất cả làm câu
/// hỏi "cái nào đang là chính" biến mất khỏi thiết kế thay vì phải theo dõi
/// nó suốt phiên.
public actor SystemProxyController {
    private let configurer: any SystemProxyConfiguring
    private let store: ProxySnapshotStore

    public init(configurer: any SystemProxyConfiguring = NetworkSetupConfigurer(),
                store: ProxySnapshotStore = ProxySnapshotStore(url: ProxySnapshotStore.defaultURL)) {
        self.configurer = configurer
        self.store = store
    }

    /// Đặt proxy lên mọi dịch vụ đang hoạt động. Trả về danh sách đã đặt.
    @discardableResult
    public func enable(host: String, port: Int) async throws -> [String] {
        let services = try await configurer.activeServices()
        guard !services.isEmpty else {
            // Báo lỗi chứ không lặng lẽ thành công: người dùng bấm Chạy và
            // thấy "đã đặt proxy" trong khi không đặt được gì là kiểu nói dối
            // dẫn tới nửa giờ chẩn đoán sai.
            throw SystemProxyError.commandFailed(
                status: -1, output: "Không có dịch vụ mạng nào đang hoạt động.")
        }

        // Chụp trạng thái gốc CHỈ khi chưa có snapshot. Bật lần hai mà chụp
        // đè là chụp nhằm trạng thái ta vừa đổi; luật chuẩn hoá sẽ biến nó
        // thành "tắt", và nếu gốc là proxy công ty thì đường về mất vĩnh viễn.
        if !store.exists {
            var originals: [ServiceProxySnapshot] = []
            for service in services {
                let current = try await configurer.read(service: service)
                originals.append(ServiceProxySnapshot(
                    service: service,
                    web: current.web.normalizedAsOriginal(appliedHost: host, appliedPort: port),
                    secureWeb: current.secureWeb.normalizedAsOriginal(appliedHost: host, appliedPort: port)
                ))
            }
            // Ghi và fsync TRƯỚC khi đổi bất cứ thứ gì. Đây là cốt lõi của
            // toàn bộ thiết kế: crash giữa vòng apply bên dưới thì file đã mô
            // tả đủ MỌI dịch vụ ta định đụng vào, kể cả cái chưa kịp đụng.
            // Khôi phục thừa thì vô hại; khôi phục thiếu thì mất mạng.
            try store.write(ProxySnapshot(takenAt: Date(), appliedHost: host,
                                          appliedPort: port, services: originals))
        }

        var applied: [String] = []
        do {
            for service in services {
                try await configurer.apply(host: host, port: port, to: service)
                applied.append(service)
            }
        } catch {
            await rollBack(applied)
            throw error
        }
        return applied
    }

    /// Lùi lại những dịch vụ đã đặt trong CHÍNH lần gọi này, rồi bỏ snapshot
    /// CHỈ KHI mọi lần restore đều thành công.
    ///
    /// Lỗi trong lúc lùi được nuốt có chủ ý: ta đang xử lý một lỗi khác và
    /// sắp ném nó lên trên; ném đè một lỗi thứ hai sẽ giấu mất nguyên nhân
    /// đầu tiên, thứ người dùng cần để hiểu chuyện gì đã xảy ra. Nhưng nuốt
    /// lỗi không có nghĩa lờ nó đi: nếu một restore hỏng, dịch vụ đó vẫn còn
    /// trỏ vào ta, và file snapshot chính là đường về DUY NHẤT — xoá nó lúc
    /// này là đúng lỗi mà cả tính năng sinh ra để tránh. Giữ file lại thì vô
    /// hại (khôi phục là idempotent), xoá nhầm thì mất mạng.
    private func rollBack(_ applied: [String]) async {
        guard let snapshot = try? store.read() else { return }
        var allRestored = true
        for service in applied {
            guard let original = snapshot.services.first(where: { $0.service == service }) else { continue }
            do {
                try await configurer.restore(original)
            } catch {
                allRestored = false
            }
        }
        if allRestored {
            try? store.delete()
        }
    }

    /// Trả mọi dịch vụ về trạng thái đã lưu, rồi xoá file.
    ///
    /// Xoá file CHỈ khi tất cả thành công. Hỏng cái nào thì giữ lại để lần mở
    /// sau thử tiếp — xoá lúc chưa khôi phục xong là vứt mất bản đồ đường về.
    public func disable() async throws {
        guard let snapshot = try store.read() else { return }
        try await restore(snapshot)
        try store.delete()
    }

    /// Gọi lúc app khởi động. Trả về true nếu có dọn gì đó.
    ///
    /// File còn sót nghĩa là lần trước chết bất thường (SIGKILL, mất điện) —
    /// không có cách nào chạy code sau SIGKILL, nên đây là đường về duy nhất.
    ///
    /// - Parameter fallbackPort: cổng dùng để nhận diện dấu vết của chính app
    ///   khi file snapshot hỏng không đọc được `appliedPort` từ trong đó.
    @discardableResult
    public func recoverIfNeeded(fallbackPort: Int = 9090) async throws -> Bool {
        guard store.exists else { return false }

        let snapshot: ProxySnapshot
        do {
            guard let read = try store.read() else { return false }
            snapshot = read
        } catch {
            // File hỏng: vẫn còn một đường cứu không cần tới nó. Dấu vết
            // loopback đúng cổng ta chắc chắn do ta để lại, nên tắt nó an
            // toàn kể cả khi không biết trạng thái gốc. Không đoán gì thêm
            // ngoài phạm vi đó — proxy của người khác không bị đụng.
            let changed = try await turnOffOwnLeftovers(host: "127.0.0.1", port: fallbackPort)
            try store.delete()
            return changed
        }

        try await restore(snapshot)
        try store.delete()
        return true
    }

    /// Luật chung cho mọi đường khôi phục: chỉ đụng dịch vụ mà cấu hình HIỆN
    /// TẠI vẫn đang trỏ vào ta — và xét TỪNG FIELD riêng, không gộp chung.
    ///
    /// Không có luật này thì kịch bản sau làm hỏng việc thật: app crash →
    /// người dùng mất mạng → họ tự đặt proxy công ty → mở lại app → app lẳng
    /// lặng đạp mất cấu hình vừa đặt, viện cớ "khôi phục". Ý muốn mới của
    /// người dùng phải thắng dấu vết cũ của ta.
    ///
    /// Xét theo dịch vụ (gộp OR hai field rồi khôi phục CẢ HAI) là sai: người
    /// dùng thường chỉ đổi một field (vd. tự đặt proxy công ty cho HTTP, để
    /// yên HTTPS vẫn trỏ vào ta) — gộp OR sẽ khôi phục luôn field họ vừa đổi,
    /// đạp mất nó. Xét theo field, mỗi bên độc lập: field nào người dùng đã
    /// đổi thì giữ nguyên giá trị hiện tại của họ; field nào vẫn còn là dấu
    /// vết của ta thì trả về bản gốc. Không field nào còn là của ta thì bỏ
    /// qua cả dịch vụ, không gọi lệnh nào.
    ///
    /// Luật này cũng làm việc khôi phục idempotent: chạy lại bao nhiêu lần
    /// cũng không hại.
    private func restore(_ snapshot: ProxySnapshot) async throws {
        for original in snapshot.services {
            let current = try await configurer.read(service: original.service)
            let webStillOurs =
                current.web.pointsAt(host: snapshot.appliedHost, port: snapshot.appliedPort)
            let secureStillOurs =
                current.secureWeb.pointsAt(host: snapshot.appliedHost, port: snapshot.appliedPort)
            guard webStillOurs || secureStillOurs else { continue }
            try await configurer.restore(ServiceProxySnapshot(
                service: original.service,
                web: webStillOurs ? original.web : current.web,
                secureWeb: secureStillOurs ? original.secureWeb : current.secureWeb))
        }
    }

    /// Trả về true nếu có dịch vụ nào thực sự bị đổi.
    @discardableResult
    private func turnOffOwnLeftovers(host: String, port: Int) async throws -> Bool {
        var changedAny = false
        for service in try await configurer.activeServices() {
            let current = try await configurer.read(service: service)
            let web = current.web.pointsAt(host: host, port: port) ? ProxySetting.off : current.web
            let secure = current.secureWeb.pointsAt(host: host, port: port)
                ? ProxySetting.off : current.secureWeb
            guard web != current.web || secure != current.secureWeb else { continue }
            try await configurer.restore(
                ServiceProxySnapshot(service: service, web: web, secureWeb: secure))
            changedAny = true
        }
        return changedAny
    }
}
