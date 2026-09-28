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
}
