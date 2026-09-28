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
            /// Chỉ lệnh THỨ NHẤT của `apply` chạy được — dịch vụ đang ở trạng
            /// thái nửa vời: HTTP đã trỏ vào ta, HTTPS thì chưa.
            case halfApply(service: String, host: String, port: Int)
            case restore(service: String, field: ProxyField, setting: ProxySetting)
        }

        private(set) var events: [Event] = []
        private var services: [String]
        private var current: [String: ServiceProxySnapshot]
        private let failApplyAt: Int?
        private let halfApplyAt: Int?
        private let failRestoreFor: String?
        private var applyCalls = 0
        /// Gọi ngay trước mỗi `apply`, để test soi trạng thái đĩa đúng lúc đó.
        var onApply: (@Sendable () -> Void)?

        /// - Parameter halfApplyAt: lần `apply` thứ mấy (1-based) chỉ chạy
        ///   được lệnh đầu rồi ném lỗi. `apply` thật phát HAI lệnh
        ///   (`-setwebproxy` rồi `-setsecurewebproxy`); một fake chỉ biết
        ///   "hoặc chưa đụng gì hoặc đã đặt cả hai" không diễn tả nổi đường
        ///   hỏng nguy hiểm nhất, nên nó giấu luôn bug ở đó.
        init(services: [String],
             current: [String: ServiceProxySnapshot] = [:],
             failApplyAt: Int? = nil,
             halfApplyAt: Int? = nil,
             failRestoreFor: String? = nil) {
            self.services = services
            self.current = current
            self.failApplyAt = failApplyAt
            self.halfApplyAt = halfApplyAt
            self.failRestoreFor = failRestoreFor
        }

        func setOnApply(_ block: @escaping @Sendable () -> Void) { onApply = block }

        /// Đặt thẳng trạng thái hiện tại, KHÔNG ghi event — dùng để giả lập
        /// người dùng tự đổi cấu hình bằng tay giữa chừng.
        func setCurrent(_ snapshot: ServiceProxySnapshot) {
            current[snapshot.service] = snapshot
        }

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
            applyCalls += 1
            let ours = ProxySetting(enabled: true, server: host, port: port)
            var snapshot = current[service]
                ?? ServiceProxySnapshot(service: service, web: .off, secureWeb: .off)

            if applyCalls == halfApplyAt {
                snapshot.web = ours              // `-setwebproxy` đã chạy xong
                current[service] = snapshot
                events.append(.halfApply(service: service, host: host, port: port))
                throw SystemProxyError.commandFailed(
                    status: 1, output: "giả lập lỗi ở lệnh -setsecurewebproxy")
            }
            if applyCalls == failApplyAt {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi apply")
            }

            snapshot.web = ours
            snapshot.secureWeb = ours
            current[service] = snapshot
            events.append(.apply(service: service, host: host, port: port))
        }

        func restore(_ setting: ProxySetting, field: ProxyField, of service: String) async throws {
            if service == failRestoreFor {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi restore")
            }
            events.append(.restore(service: service, field: field, setting: setting))
            var snapshot = current[service]
                ?? ServiceProxySnapshot(service: service, web: .off, secureWeb: .off)
            switch field {
            case .web: snapshot.web = setting
            case .secureWeb: snapshot.secureWeb = setting
            }
            current[service] = snapshot
        }

        var applied: [String] {
            events.compactMap { if case .apply(let s, _, _) = $0 { return s }; return nil }
        }

        /// Tên dịch vụ có ít nhất một field được trả lại, theo thứ tự lần đầu
        /// xuất hiện — một dịch vụ khôi phục cả hai field vẫn chỉ tính một lần.
        var restored: [String] {
            var seen: [String] = []
            for case .restore(let service, _, _) in events where !seen.contains(service) {
                seen.append(service)
            }
            return seen
        }

        func clearEvents() { events.removeAll() }

        /// Giá trị cuối cùng được ghi cho một field, hoặc `nil` nếu field đó
        /// KHÔNG hề được phát lệnh nào.
        func restoredSetting(for service: String, field: ProxyField) -> ProxySetting? {
            events.reversed().compactMap {
                if case .restore(let s, let f, let setting) = $0, s == service, f == field {
                    return setting
                }
                return nil
            }.first
        }

        func currentState(of service: String) -> ServiceProxySnapshot? { current[service] }
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

    @Test("Host không phải loopback thì ném lỗi, KHÔNG chụp snapshot")
    func rejectsNonLoopbackHost() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let sut = SystemProxyController(configurer: fake, store: store)

        await #expect(throws: SystemProxyError.nonLoopbackHost("192.168.1.20")) {
            _ = try await sut.enable(host: "192.168.1.20", port: 9090)
        }
        #expect(await fake.events.isEmpty,
                "luật nhận dấu vết §2.3 chỉ khớp loopback — host LAN lọt qua là app chụp chính cấu hình của mình làm nguyên bản")
        #expect(store.exists == false)
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
        #expect(store.exists == true,
                "giữ snapshot sau rollback là vô hại (khôi phục idempotent); xoá nhầm là không đảo ngược được")
    }

    @Test("Lệnh THỨ HAI của apply hỏng: dịch vụ nửa vời vẫn được lùi lại, và snapshot SỐNG SÓT")
    func rollsBackTheHalfAppliedService() async throws {
        let store = tempStore()
        let corporate = ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
        let original = ServiceProxySnapshot(
            service: "Thunderbolt Bridge", web: corporate, secureWeb: corporate)
        // Wi-Fi đặt xong; Thunderbolt Bridge chạy được `-setwebproxy` rồi
        // ném lỗi ở `-setsecurewebproxy`.
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                  current: ["Thunderbolt Bridge": original],
                                  halfApplyAt: 2)
        let sut = SystemProxyController(configurer: fake, store: store)

        await #expect(throws: SystemProxyError.self) {
            _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        }

        #expect(await fake.restoredSetting(for: "Thunderbolt Bridge", field: .web) == corporate,
                "dịch vụ đổi nửa vời phải nằm trong tập lùi lại, không thì nó kẹt ở cổng của ta")
        let state = try #require(await fake.currentState(of: "Thunderbolt Bridge"))
        #expect(state.web == corporate)
        #expect(state.secureWeb == corporate, "field chưa kịp đổi thì không được phát lệnh gì")
        #expect(store.exists == true,
                "xoá snapshot trong lúc còn dịch vụ có thể đang trỏ vào ta là mất đường về vĩnh viễn")
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

    @Test("Dùng lại snapshot cũ thì CẬP NHẬT cổng đang đặt, giữ nguyên services")
    func refreshesAppliedPortWhenReusingSnapshot() async throws {
        let store = tempStore()
        let corporate = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off)
        // Rollback giữ lại snapshot của lần bật đầu (cổng 54321).
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                  current: ["Wi-Fi": corporate], failApplyAt: 2)
        let sut = SystemProxyController(configurer: fake, store: store)
        await #expect(throws: SystemProxyError.self) {
            _ = try await sut.enable(host: "127.0.0.1", port: 54321)
        }
        #expect(store.exists == true)

        // Lần bật thứ hai bind được cổng khác (cấu hình dùng cổng 0).
        _ = try await sut.enable(host: "127.0.0.1", port: 54322)
        let saved = try #require(try store.read())
        #expect(saved.appliedPort == 54322,
                "giữ cổng cũ là làm mọi pointsAt trả về false: disable() bỏ qua hết rồi vẫn xoá file")
        #expect(saved.services.first { $0.service == "Wi-Fi" } == corporate,
                "trạng thái nguyên bản KHÔNG được chụp đè, chỉ cổng mới được ghi lại")

        // Và nhờ cổng đã đúng, gỡ ra mới nhận lại được dấu vết của mình.
        await fake.clearEvents()
        try await sut.disable()
        #expect(await fake.restored.sorted() == ["Thunderbolt Bridge", "Wi-Fi"])
        #expect(store.exists == false)
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
        await fake.setCurrent(ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off))
        await fake.clearEvents()

        try await sut.disable()

        #expect(await fake.restored == ["Thunderbolt Bridge"],
                "ý muốn mới của người dùng phải thắng dấu vết cũ của ta")
    }

    @Test("Chỉ HTTP bị đổi: KHÔNG phát lệnh nào cho HTTP, chỉ trả lại HTTPS")
    func restoresOnlyTheFieldStillPointingAtUs_httpChanged() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        // Người dùng tự đặt proxy công ty cho HTTP, để yên HTTPS (vẫn trỏ vào ta).
        let corporateHTTP = ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
        await fake.setCurrent(ServiceProxySnapshot(
            service: "Wi-Fi",
            web: corporateHTTP,
            secureWeb: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090)))
        await fake.clearEvents()

        try await sut.disable()

        #expect(await fake.restoredSetting(for: "Wi-Fi", field: .web) == nil,
                "`-setwebproxy` thừa xoá sạch credential của proxy có xác thực — field người dùng vừa đổi không được đụng tới")
        #expect(await fake.restoredSetting(for: "Wi-Fi", field: .secureWeb)?.enabled == false,
                "field vẫn còn là dấu vết của ta thì phải được trả lại")
        #expect(await fake.currentState(of: "Wi-Fi")?.web == corporateHTTP)
    }

    @Test("Chỉ HTTPS bị đổi: KHÔNG phát lệnh nào cho HTTPS, chỉ trả lại HTTP")
    func restoresOnlyTheFieldStillPointingAtUs_secureWebChanged() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        // Người dùng tự đặt proxy công ty cho HTTPS, để yên HTTP (vẫn trỏ vào ta).
        let corporateHTTPS = ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
        await fake.setCurrent(ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090),
            secureWeb: corporateHTTPS))
        await fake.clearEvents()

        try await sut.disable()

        #expect(await fake.restoredSetting(for: "Wi-Fi", field: .secureWeb) == nil,
                "field người dùng vừa đổi không được phát lệnh nào")
        #expect(await fake.restoredSetting(for: "Wi-Fi", field: .web)?.enabled == false,
                "field vẫn còn là dấu vết của ta thì phải được trả lại")
        #expect(await fake.currentState(of: "Wi-Fi")?.secureWeb == corporateHTTPS)
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
        // Dịch vụ hỏng là dịch vụ ĐẦU TIÊN: dịch vụ phía sau phải vẫn được
        // khôi phục. Ném ngay ở cái hỏng đầu tiên là bỏ mọi dịch vụ còn lại
        // ở cổng sắp chết — đúng thứ §7.3 cấm.
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                  failRestoreFor: "Wi-Fi")
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        await fake.clearEvents()

        await #expect(throws: SystemProxyError.restoreIncomplete(services: ["Wi-Fi"])) {
            try await sut.disable()
        }
        #expect(await fake.restored == ["Thunderbolt Bridge"],
                "một dịch vụ hỏng không được làm bỏ dở những dịch vụ còn lại")
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

    @Test("File sót nhưng người dùng đã tự đổi hết thì trả về false, không báo dọn khống")
    func recoverReturnsFalseWhenNothingWasOurs() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let first = SystemProxyController(configurer: fake, store: store)
        _ = try await first.enable(host: "127.0.0.1", port: 9090)

        // Sau khi app chết, người dùng tự đặt proxy công ty.
        await fake.setCurrent(ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)))

        let afterRelaunch = SystemProxyController(configurer: fake, store: store)
        #expect(try await afterRelaunch.recoverIfNeeded() == false,
                "không trả lại field nào mà vẫn báo true là nói dối đúng chỗ người đọc log tin nhất")
        #expect(store.exists == false)
    }

    @Test("Bấm Chạy lúc đang khôi phục thì phải ĐỢI khôi phục xong")
    func enableWaitsForLaunchRecovery() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"])
        let first = SystemProxyController(configurer: fake, store: store)
        _ = try await first.enable(host: "127.0.0.1", port: 9090)
        // Không disable — giả lập SIGKILL, file còn sót.

        let afterRelaunch = SystemProxyController(configurer: fake, store: store)
        // Đăng ký khôi phục rồi bấm Chạy ngay — đúng cảnh người dùng mở lại
        // app sau một lần crash và bấm Chạy trước khi app kịp dọn xong.
        await afterRelaunch.beginRecovery()
        _ = try await afterRelaunch.enable(host: "127.0.0.1", port: 9091)
        #expect(await afterRelaunch.recoverAtLaunch() == true)

        // Khôi phục xong TRƯỚC khi enable chụp lại, nên snapshot của lần bật
        // mới phải là trạng thái nguyên bản (tắt) và mang cổng mới.
        let saved = try #require(try store.read())
        #expect(saved.appliedPort == 9091)
        #expect(saved.services.allSatisfy { !$0.web.enabled && !$0.secureWeb.enabled })
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
        #expect(await fake.restoredSetting(for: "Wi-Fi", field: .web)?.enabled == false)
        #expect(await fake.restoredSetting(for: "Wi-Fi", field: .secureWeb)?.enabled == false)
    }
}

/// Hộp ghi nhận giá trị quan sát được từ trong closure `@Sendable`.
final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var first: Bool? { lock.lock(); defer { lock.unlock() }; return values.first }
}
