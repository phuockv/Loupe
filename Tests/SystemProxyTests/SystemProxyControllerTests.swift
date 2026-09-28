import Testing
import Foundation
@testable import SystemProxy

@Suite("SystemProxyController")
struct SystemProxyControllerTests {

    /// Configurer giả: giữ trạng thái trong bộ nhớ, ghi lại timeline thao tác.
    actor FakeConfigurer: SystemProxyConfiguring {
        enum Event: Equatable {
            case list
            case read(String)
            case apply(service: String, host: String, port: Int)
            case restore(ServiceProxySnapshot)
        }

        private(set) var events: [Event] = []
        private var services: [String]
        private var current: [String: ServiceProxySnapshot]
        private let failApplyAt: Int?
        private let failRestoreFor: String?
        /// Gọi ngay trước mỗi `apply`, để test soi trạng thái đĩa đúng lúc đó.
        var onApply: (@Sendable () -> Void)?

        init(services: [String],
             current: [String: ServiceProxySnapshot] = [:],
             failApplyAt: Int? = nil,
             failRestoreFor: String? = nil) {
            self.services = services
            self.current = current
            self.failApplyAt = failApplyAt
            self.failRestoreFor = failRestoreFor
        }

        func setOnApply(_ block: @escaping @Sendable () -> Void) { onApply = block }

        func activeServices() async throws -> [String] {
            events.append(.list)
            return services
        }

        func read(service: String) async throws -> ServiceProxySnapshot {
            events.append(.read(service))
            return current[service]
                ?? ServiceProxySnapshot(service: service, web: .off, secureWeb: .off)
        }

        func apply(host: String, port: Int, to service: String) async throws {
            onApply?()
            let applyCount = events.filter { if case .apply = $0 { return true }; return false }.count
            if let failApplyAt, applyCount + 1 == failApplyAt {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi apply")
            }
            events.append(.apply(service: service, host: host, port: port))
            current[service] = ServiceProxySnapshot(
                service: service,
                web: ProxySetting(enabled: true, server: host, port: port),
                secureWeb: ProxySetting(enabled: true, server: host, port: port))
        }

        func restore(_ snapshot: ServiceProxySnapshot) async throws {
            if snapshot.service == failRestoreFor {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi restore")
            }
            events.append(.restore(snapshot))
            current[snapshot.service] = snapshot
        }

        var applied: [String] {
            events.compactMap { if case .apply(let s, _, _) = $0 { return s }; return nil }
        }
        var restored: [String] {
            events.compactMap { if case .restore(let s) = $0 { return s.service }; return nil }
        }

        func clearEvents() { events.removeAll() }

        func lastRestored(for service: String) -> ServiceProxySnapshot? {
            events.reversed().compactMap {
                if case .restore(let s) = $0, s.service == service { return s }
                return nil
            }.first
        }
    }

    private func tempStore() -> ProxySnapshotStore {
        ProxySnapshotStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.json"))
    }

    @Test("Bật thì đặt proxy lên MỌI dịch vụ đang hoạt động")
    func enablesEveryActiveService() async throws {
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge", "phuoc.kieu-c-sg"])
        let sut = SystemProxyController(configurer: fake, store: tempStore())

        let applied = try await sut.enable(host: "127.0.0.1", port: 9090)

        #expect(applied == ["Wi-Fi", "Thunderbolt Bridge", "phuoc.kieu-c-sg"])
        #expect(await fake.applied == ["Wi-Fi", "Thunderbolt Bridge", "phuoc.kieu-c-sg"])
    }

    @Test("File snapshot tồn tại TRƯỚC lệnh apply đầu tiên")
    func writesSnapshotBeforeFirstApply() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"])

        // Soi đĩa ngay tại thời điểm apply đầu tiên được gọi.
        let sawFile = SeenBox()
        await fake.setOnApply { sawFile.record(store.exists) }

        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        #expect(sawFile.first == true,
                "crash giữa chừng mà chưa có file là mất sạch đường về")
    }

    @Test("Dấu vết cũ của chính app được ghi vào snapshot là TẮT")
    func normalisesOwnLeftoverBeforeSaving() async throws {
        let leftover = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090),
            secureWeb: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090))
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"], current: ["Wi-Fi": leftover])
        let sut = SystemProxyController(configurer: fake, store: store)

        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        let saved = try #require(try store.read())
        #expect(saved.services[0].web.enabled == false)
        #expect(saved.services[0].secureWeb.enabled == false)
    }

    @Test("Proxy công ty được lưu nguyên vẹn, không bị chuẩn hoá nhầm")
    func preservesCorporateProxyInSnapshot() async throws {
        let corporate = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128))
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"], current: ["Wi-Fi": corporate])
        let sut = SystemProxyController(configurer: fake, store: store)

        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        #expect(try #require(try store.read()).services[0] == corporate)
    }

    @Test("Apply hỏng giữa chừng thì lùi lại dịch vụ đã đặt và ném lỗi")
    func rollsBackOnPartialFailure() async throws {
        let store = tempStore()
        // Hỏng ở lần apply thứ hai.
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"], failApplyAt: 2)
        let sut = SystemProxyController(configurer: fake, store: store)

        await #expect(throws: SystemProxyError.self) {
            _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        }
        #expect(await fake.restored == ["Wi-Fi"], "dịch vụ đã đặt phải được trả lại")
        #expect(store.exists == false, "lùi xong thì không còn gì để khôi phục")
    }

    @Test("Rollback mà restore cũng hỏng thì GIỮ LẠI snapshot, không xoá")
    func keepsSnapshotWhenRollbackRestoreAlsoFails() async throws {
        let store = tempStore()
        // Hỏng ở lần apply thứ hai, và dịch vụ đầu tiên (đã apply xong) lại
        // hỏng luôn lúc restore trong rollback.
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                   failApplyAt: 2, failRestoreFor: "Wi-Fi")
        let sut = SystemProxyController(configurer: fake, store: store)

        await #expect(throws: SystemProxyError.self) {
            _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        }
        #expect(store.exists == true,
                "Wi-Fi vẫn trỏ vào ta mà restore hỏng — xoá file lúc này là mất đường về duy nhất")
    }

    @Test("Bật lần hai khi snapshot đã tồn tại thì KHÔNG chụp đè")
    func doesNotOverwriteExistingSnapshot() async throws {
        let corporate = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off)
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"], current: ["Wi-Fi": corporate])
        let sut = SystemProxyController(configurer: fake, store: store)

        _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)   // lần hai

        #expect(try #require(try store.read()).services[0] == corporate,
                "chụp đè lần hai sẽ chụp nhằm trạng thái ta vừa đổi, xoá vĩnh viễn đường về")
    }

    @Test("Không có dịch vụ nào đang hoạt động thì ném lỗi, không báo thành công giả")
    func failsLoudlyWhenNoActiveServices() async throws {
        let store = tempStore()
        let sut = SystemProxyController(configurer: FakeConfigurer(services: []), store: store)

        await #expect(throws: SystemProxyError.self) {
            _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        }
        #expect(store.exists == false, "không đặt được gì thì đừng để lại file trống")
    }

    @Test("Gỡ thì trả mọi dịch vụ về trạng thái đã lưu rồi xoá file")
    func disableRestoresEverythingThenDeletesFile() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"])
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        try await sut.disable()

        #expect(await fake.restored == ["Wi-Fi", "Thunderbolt Bridge"])
        #expect(store.exists == false)
    }

    @Test("Chỉ khôi phục dịch vụ CÒN đang trỏ vào ta; ai đã đổi đi thì để yên")
    func skipsServicesChangedBySomeoneElse() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"])
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        // Người dùng tự đặt Wi-Fi sang proxy công ty trong lúc app đang chạy.
        try await fake.restore(ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off))
        await fake.clearEvents()

        try await sut.disable()

        #expect(await fake.restored == ["Thunderbolt Bridge"],
                "ý muốn mới của người dùng phải thắng dấu vết cũ của ta")
    }

    @Test("Nhận diện dấu vết dùng appliedPort trong snapshot, không dùng cổng hiện tại")
    func usesAppliedPortFromSnapshotNotCurrentPort() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let sut = SystemProxyController(configurer: fake, store: store)
        // Cấu hình cổng 0 → kernel cấp 54321 cho lần chạy này.
        _ = try await sut.enable(host: "127.0.0.1", port: 54321)
        await fake.clearEvents()

        try await sut.disable()

        #expect(await fake.restored == ["Wi-Fi"],
                "đọc cổng ở chỗ khác ngoài snapshot là bỏ sót dịch vụ cần trả lại")
    }

    @Test("Khôi phục hỏng một dịch vụ thì GIỮ file lại để lần sau thử tiếp")
    func keepsSnapshotWhenRestoreFails() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                  failRestoreFor: "Thunderbolt Bridge")
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        await #expect(throws: SystemProxyError.self) { try await sut.disable() }
        #expect(store.exists, "xoá file lúc chưa khôi phục xong là vứt mất bản đồ đường về")
    }

    @Test("Mở app mà không có file sót thì KHÔNG chạy lệnh nào")
    func recoverDoesNothingWithoutSnapshot() async throws {
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let sut = SystemProxyController(configurer: fake, store: tempStore())

        #expect(try await sut.recoverIfNeeded() == false)
        #expect(await fake.events.isEmpty, "app mở bình thường không được đụng vào cài đặt mạng")
    }

    @Test("File sót thì khôi phục rồi xoá")
    func recoverRestoresLeftoverSnapshot() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let first = SystemProxyController(configurer: fake, store: store)
        _ = try await first.enable(host: "127.0.0.1", port: 9090)
        // Không gọi disable — giả lập app bị SIGKILL.

        let afterRelaunch = SystemProxyController(configurer: fake, store: store)
        #expect(try await afterRelaunch.recoverIfNeeded() == true)
        #expect(store.exists == false)
    }

    @Test("JSON hỏng thì đi đường cứu: chỉ tắt dịch vụ đang trỏ vào ta")
    func corruptSnapshotFallsBackToTurningOffOwnLeftovers() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ hỏng".utf8).write(to: url)

        let ours = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090),
            secureWeb: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090))
        let corporate = ServiceProxySnapshot(
            service: "Thunderbolt Bridge",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off)
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                  current: ["Wi-Fi": ours, "Thunderbolt Bridge": corporate])
        let sut = SystemProxyController(configurer: fake,
                                        store: ProxySnapshotStore(url: url))

        _ = try await sut.recoverIfNeeded(fallbackPort: 9090)

        #expect(await fake.restored == ["Wi-Fi"], "chỉ gỡ dấu vết chắc chắn của ta")
        let restoredWiFi = await fake.lastRestored(for: "Wi-Fi")
        #expect(restoredWiFi?.web.enabled == false)
    }
}

/// Hộp ghi nhận giá trị quan sát được từ trong closure `@Sendable`.
final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var first: Bool? { lock.lock(); defer { lock.unlock() }; return values.first }
}
