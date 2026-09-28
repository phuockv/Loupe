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

    /// Instance dùng chung cho toàn app.
    ///
    /// Trạng thái chia sẻ thật không nằm trong object này mà nằm ở file
    /// snapshot và ở cấu hình của hệ điều hành — hai instance khác nhau thao
    /// tác trên đúng hai thứ đó mà không hề biết nhau. Một instance duy nhất
    /// là điều kiện cần để `recoveryTask` bên dưới có nghĩa: nó chỉ chặn
    /// được `enable()` của chính nó.
    public static let shared = SystemProxyController()

    /// Lần khôi phục lúc mở app, nếu đang chạy.
    ///
    /// Actor KHÔNG loại trừ hai lời gọi async lẫn nhau: mỗi `await` bên trong
    /// là một chỗ lời gọi khác chen vào được (reentrancy). Không có cái chốt
    /// này thì người dùng bấm Chạy ngay sau một lần crash sẽ xen giữa vòng
    /// khôi phục: `enable()` thấy snapshot còn đó nên không chụp lại, apply
    /// xong; vòng khôi phục đi tiếp tới những dịch vụ nó chưa kịp đọc, thấy
    /// chúng "đang trỏ vào ta", trả chúng về gốc rồi xoá file — kết cục là
    /// máy bị proxy, toggle báo "đang bật", và không còn snapshot nào.
    private var recoveryTask: Task<Bool, Never>?

    public init(configurer: any SystemProxyConfiguring = NetworkSetupConfigurer(),
                store: ProxySnapshotStore = ProxySnapshotStore(url: ProxySnapshotStore.defaultURL)) {
        self.configurer = configurer
        self.store = store
    }

    /// Tên các dịch vụ trong snapshot còn sót, để in ra đúng lệnh tự cứu.
    ///
    /// Rỗng khi không có file hoặc file hỏng — người gọi phải có phương án
    /// cho trường hợp đó, không được in ra một tên bịa.
    public func snapshotServices() -> [String] {
        (try? store.read())?.services.map(\.service) ?? []
    }

    /// Đặt proxy lên mọi dịch vụ đang hoạt động. Trả về danh sách đã đặt.
    @discardableResult
    public func enable(host: String, port: Int) async throws -> [String] {
        // §2.3 chỉ nhận ra dấu vết của chính app khi host là loopback. Một
        // host LAN lọt qua đây sẽ làm mọi `pointsAt` trả về false: app chụp
        // chính cấu hình của mình làm "nguyên bản", và không có gì đỏ lên.
        guard Loopback.isLoopback(host) else {
            throw SystemProxyError.nonLoopbackHost(host)
        }

        // Đợi lần khôi phục lúc mở app xong hẳn rồi mới đụng vào gì.
        if let recoveryTask { _ = await recoveryTask.value }

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
        } else {
            try refreshAppliedEndpoint(host: host, port: port)
        }

        var applied: [String] = []
        for service in services {
            // Ghi tên vào `applied` TRƯỚC khi gọi `apply`: `apply` phát HAI
            // lệnh (`-setwebproxy` rồi `-setsecurewebproxy`), nên lệnh thứ
            // hai hỏng để lại dịch vụ đã đổi một nửa. Ghi tên sau khi `apply`
            // trả về thì dịch vụ nửa vời đó nằm NGOÀI danh sách lùi lại —
            // nó sẽ kẹt ở cổng của ta trong khi rollback tưởng mình đã sạch.
            applied.append(service)
            do {
                try await configurer.apply(host: host, port: port, to: service)
            } catch {
                await rollBack(applied)
                throw error
            }
        }
        return applied
    }

    /// Cập nhật `appliedHost`/`appliedPort` khi dùng lại một snapshot cũ.
    ///
    /// Snapshot sống sót qua một lần rollback hoặc một lần `disable()` hỏng
    /// là đúng — `services` trong đó vẫn là trạng thái nguyên bản và KHÔNG
    /// được đụng vào. Nhưng cổng thì khác: lần bật này đang đặt một cổng
    /// khác (cấu hình dùng cổng 0 thì mỗi lần bind là một cổng mới). Để
    /// nguyên cổng cũ là làm mọi `pointsAt` sau đó trả về false — `restore`
    /// bỏ qua sạch mọi dịch vụ, `disable()` vẫn đi tới `store.delete()`, và
    /// máy ở lại với proxy trỏ vào một cổng đang chết.
    private func refreshAppliedEndpoint(host: String, port: Int) throws {
        // File hỏng thì im lặng bỏ qua: `recoverIfNeeded` có đường cứu riêng
        // cho nó, và ghi đè một file không đọc được là xoá nốt cơ hội cứu tay.
        guard let existing = try? store.read() else { return }
        guard existing.appliedHost != host || existing.appliedPort != port else { return }
        var updated = existing
        updated.appliedHost = host
        updated.appliedPort = port
        try store.write(updated)
    }

    /// Lùi lại những dịch vụ đã đụng vào trong CHÍNH lần gọi này.
    ///
    /// Lỗi trong lúc lùi được nuốt có chủ ý: ta đang xử lý một lỗi khác và
    /// sắp ném nó lên trên; ném đè một lỗi thứ hai sẽ giấu mất nguyên nhân
    /// đầu tiên, thứ người dùng cần để hiểu chuyện gì đã xảy ra.
    ///
    /// KHÔNG xoá snapshot ở đây, kể cả khi mọi lần lùi đều báo thành công.
    /// Giữ file lại thì vô hại — luật "chỉ đụng dịch vụ còn trỏ vào ta" làm
    /// việc khôi phục idempotent, nên `disable()` hay lần mở sau chạy lại chỉ
    /// tốn vài lệnh đọc rồi tự xoá file. Xoá nhầm thì không có gì đảo ngược
    /// được: chỉ cần một dịch vụ còn trỏ vào ta mà ta tưởng đã sạch là mất
    /// mạng vĩnh viễn, không lỗi, không log, không đường về.
    private func rollBack(_ services: [String]) async {
        guard let snapshot = try? store.read() else { return }
        let subset = ProxySnapshot(
            takenAt: snapshot.takenAt,
            appliedHost: snapshot.appliedHost,
            appliedPort: snapshot.appliedPort,
            services: snapshot.services.filter { services.contains($0.service) })
        // Đi qua đúng `restore` của mọi đường khác: xét từng field, chỉ đụng
        // field còn trỏ vào ta. Với dịch vụ đổi nửa vời, field đã đổi được
        // trả lại còn field chưa kịp đổi để yên — không phát lệnh thừa.
        _ = try? await restore(subset)
    }

    /// Trả mọi dịch vụ về trạng thái đã lưu, rồi xoá file.
    ///
    /// Xoá file CHỈ khi tất cả thành công. Hỏng cái nào thì giữ lại để lần mở
    /// sau thử tiếp — xoá lúc chưa khôi phục xong là vứt mất bản đồ đường về.
    public func disable() async throws {
        guard let snapshot = try store.read() else { return }
        _ = try await restore(snapshot)
        try store.delete()
    }

    /// Gọi lúc app khởi động, và đợi cho xong TRƯỚC khi vẽ cửa sổ (§4.3).
    ///
    /// Gọi nhiều lần thì chỉ chạy một lần: lần gọi thứ hai đợi chung kết quả
    /// của lần đầu. `enable()` cũng đợi chính task này, nên bấm Chạy lúc đang
    /// khôi phục không còn chen được vào giữa.
    @discardableResult
    public func recoverAtLaunch(fallbackPort: Int = 9090) async -> Bool {
        beginRecovery(fallbackPort: fallbackPort)
        guard let recoveryTask else { return false }
        return await recoveryTask.value
    }

    /// Đăng ký lần khôi phục rồi trả về NGAY, không đợi.
    ///
    /// Tách khỏi `recoverAtLaunch` vì thứ chặn `enable()` là việc `recoveryTask`
    /// ĐÃ được gán, chứ không phải việc nó đã chạy xong — và hàm này không có
    /// `await` nào bên trong, nên sau khi nó trả về thì cái chốt chắc chắn đã
    /// ở đúng chỗ, không phụ thuộc lịch chạy của task.
    public func beginRecovery(fallbackPort: Int = 9090) {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [self] in
            (try? await recoverIfNeeded(fallbackPort: fallbackPort)) ?? false
        }
    }

    /// Trả về true nếu thực sự có dọn gì đó — tức có ít nhất một field được
    /// trả lại. File còn sót nhưng không dịch vụ nào còn trỏ vào ta (người
    /// dùng đã tự đổi hết) thì trả về false, giống `SyncProxyRestore`.
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

        let restoredAny = try await restore(snapshot)
        try store.delete()
        return restoredAny
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
    /// đổi thì KHÔNG phát lệnh nào cả; field nào vẫn còn là dấu vết của ta
    /// thì trả về bản gốc.
    ///
    /// Lỗi trên MỘT dịch vụ không được làm hỏng các dịch vụ còn lại (§7.3):
    /// bắt tại chỗ, đi tiếp, gom lại và ném ở cuối. Ném giữa chừng là để mọi
    /// dịch vụ phía sau ở lại với cổng sắp chết. Ném ở cuối cũng đúng là thứ
    /// giữ file snapshot lại cho lần thử sau.
    ///
    /// - Returns: true nếu có ít nhất một field thực sự được trả lại.
    @discardableResult
    private func restore(_ snapshot: ProxySnapshot) async throws -> Bool {
        var restoredAny = false
        var failures: [String] = []

        for original in snapshot.services {
            do {
                let current = try await configurer.read(service: original.service)
                for (field, currentSetting, originalSetting) in [
                    (ProxyField.web, current.web, original.web),
                    (ProxyField.secureWeb, current.secureWeb, original.secureWeb),
                ] {
                    guard currentSetting.pointsAt(host: snapshot.appliedHost,
                                                  port: snapshot.appliedPort) else { continue }
                    try await configurer.restore(originalSetting, field: field,
                                                 of: original.service)
                    restoredAny = true
                }
            } catch {
                failures.append(original.service)
            }
        }

        guard failures.isEmpty else {
            throw SystemProxyError.restoreIncomplete(services: failures)
        }
        return restoredAny
    }

    /// Trả về true nếu có dịch vụ nào thực sự bị đổi.
    ///
    /// Cũng chịu lỗi theo từng dịch vụ như `restore`: dịch vụ hỏng không được
    /// làm những dịch vụ còn dấu vết khác bị bỏ qua.
    @discardableResult
    private func turnOffOwnLeftovers(host: String, port: Int) async throws -> Bool {
        var changedAny = false
        var failures: [String] = []

        for service in try await configurer.activeServices() {
            do {
                let current = try await configurer.read(service: service)
                for (field, setting) in [
                    (ProxyField.web, current.web),
                    (ProxyField.secureWeb, current.secureWeb),
                ] {
                    guard setting.pointsAt(host: host, port: port) else { continue }
                    try await configurer.restore(.off, field: field, of: service)
                    changedAny = true
                }
            } catch {
                failures.append(service)
            }
        }

        guard failures.isEmpty else {
            throw SystemProxyError.restoreIncomplete(services: failures)
        }
        return changedAny
    }
}
