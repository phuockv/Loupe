import Testing
import Foundation
import TrafficModel
import CertKit
import ProxyCore
import SystemProxy
@testable import AppCore

/// Test double cho `TrustStoreInstaller`. Không bao giờ exec `security`/
/// `osascript` thật — mọi hành vi cấu hình sẵn qua các setter dưới đây, nên
/// test không bao giờ hiện hộp thoại mật khẩu hay chạm keychain thật.
actor FakeTrustStoreInstaller: TrustStoreInstaller {
    private(set) var installCallCount = 0
    private(set) var isInstalledCallCount = 0
    private var installResult: Result<Void, Error> = .success(())
    private var isInstalledResult: Result<Bool, Error> = .success(false)

    func setInstallResult(_ result: Result<Void, Error>) {
        installResult = result
    }

    func setIsInstalledResult(_ result: Result<Bool, Error>) {
        isInstalledResult = result
    }

    func install(pemPath: URL) async throws {
        installCallCount += 1
        try installResult.get()
    }

    func isInstalled(pemPath: URL) async throws -> Bool {
        isInstalledCallCount += 1
        return try isInstalledResult.get()
    }
}

/// Test double cho `SystemProxyConfiguring`. Giữ trạng thái trong bộ nhớ,
/// KHÔNG BAO GIỜ shell-out `/usr/sbin/networksetup` thật — nếu không, mọi
/// test ở đây gọi `start()` sẽ đổi cấu hình mạng thật của máy đang chạy
/// `swift test` (đúng lỗi mà toàn bộ tính năng System Proxy sinh ra để tránh).
actor FakeSystemProxyConfigurer: SystemProxyConfiguring {
    enum Event: Equatable {
        case list
        case read(String)
        case apply(service: String, host: String, port: Int)
        case restore(ServiceProxySnapshot)
    }

    private(set) var events: [Event] = []
    private let services: [String]
    /// Trạng thái hiện tại của mỗi dịch vụ — CẦN cập nhật ở `apply(...)` và
    /// đọc lại ở `read(service:)`, vì `SystemProxyController.restore` tự đọc
    /// lại qua `read` để kiểm tra "dịch vụ còn trỏ vào ta hay không" trước
    /// khi quyết định khôi phục; nếu fake luôn báo "tắt" thì `restore` không
    /// bao giờ được gọi và mọi khẳng định về khôi phục ở test sẽ sai.
    private var current: [String: ServiceProxySnapshot] = [:]

    init(services: [String] = ["Wi-Fi"]) {
        self.services = services
    }

    func activeServices() async throws -> [String] {
        events.append(.list)
        return services
    }

    func read(service: String) async throws -> ServiceProxySnapshot {
        events.append(.read(service))
        return current[service] ?? ServiceProxySnapshot(service: service, web: .off, secureWeb: .off)
    }

    func apply(host: String, port: Int, to service: String) async throws {
        events.append(.apply(service: service, host: host, port: port))
        current[service] = ServiceProxySnapshot(
            service: service,
            web: ProxySetting(enabled: true, server: host, port: port),
            secureWeb: ProxySetting(enabled: true, server: host, port: port))
    }

    func restore(_ snapshot: ServiceProxySnapshot) async throws {
        events.append(.restore(snapshot))
        current[snapshot.service] = snapshot
    }
}

@MainActor
@Suite("AppModel")
struct AppModelTests {

    /// `caDirectory` luôn là một thư mục tạm riêng cho test — không bao giờ
    /// `CertificateAuthority.defaultDirectory` thật, nếu không mỗi lần chạy
    /// test sẽ ghi CA xuống đúng Application Support của máy đang chạy nó.
    ///
    /// `systemProxy` cũng luôn là một `SystemProxyController` cô lập — một
    /// `FakeSystemProxyConfigurer` mới cộng một `ProxySnapshotStore` trỏ vào
    /// thư mục tạm riêng — KHÔNG BAO GIỜ controller mặc định của `AppModel`.
    /// Toggle `setSystemProxy` mặc định BẬT, nên bất kỳ test nào ở đây gọi
    /// `start()` mà dùng controller thật sẽ đổi cấu hình mạng thật của máy
    /// đang chạy `swift test`.
    private func makeModel(
        installer: FakeTrustStoreInstaller = FakeTrustStoreInstaller(),
        listenPort: Int = 0,
        systemProxyConfigurer: FakeSystemProxyConfigurer = FakeSystemProxyConfigurer()
    ) -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)")
        var config = ProxyConfiguration()
        config.listenPort = listenPort
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-snapshot-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.json")
        let systemProxy = SystemProxyController(
            configurer: systemProxyConfigurer,
            store: ProxySnapshotStore(url: snapshotURL)
        )
        return AppModel(configuration: config, installer: installer, caDirectory: dir,
                         systemProxy: systemProxy)
    }

    @Test("Trạng thái khởi tạo: chưa chạy, chưa biết CA đã cài hay chưa")
    func initialState() {
        let model = makeModel()
        #expect(model.isRunning == false)
        #expect(model.certificateInstalled == nil)
        #expect(model.selection == nil)
    }

    @Test("start() rồi stop(): isRunning bật lên rồi tắt lại, statusMessage phản ánh đúng")
    func startAndStopTogglesRunningState() async {
        let model = makeModel()

        await model.start()
        #expect(model.isRunning == true)
        #expect(model.statusMessage.contains("Đang nghe"))

        await model.stop()
        #expect(model.isRunning == false)
        #expect(model.statusMessage == "Đã dừng")
    }

    @Test("start() khi đang chạy là no-op, không đổi statusMessage")
    func startWhileRunningIsNoOp() async {
        let model = makeModel()
        await model.start()
        let messageAfterFirstStart = model.statusMessage

        await model.start()

        #expect(model.statusMessage == messageAfterFirstStart)
        await model.stop()
    }

    /// Bind hỏng vì port đã bị chiếm là đường thất bại HAY GẶP NHẤT của
    /// `start()`, và cũng là đường người dùng bấm lại ngay lập tức. `catch`
    /// của `start()` giờ có thêm một `await` (shutdown group của server vừa
    /// cấp phát — không có nó thì mỗi lần bấm rò rỉ `coreCount` thread vĩnh
    /// viễn, xem chú thích trong `start()`).
    ///
    /// GIỚI HẠN, nói thẳng: bài này KHÔNG chứng minh group đã được giải phóng
    /// — số thread của process không quan sát được qua bề mặt của `AppModel`,
    /// và bộ test chạy song song nên đếm thread cũng vô nghĩa. Nó chứng minh
    /// phần CÒN LẠI quan sát được: lần start hỏng báo lỗi thay vì treo, không
    /// bật `isRunning`, và lần bấm lại sau khi port được nhả vẫn chạy được.
    @Test("start() thất bại vì port đã bị chiếm: báo lỗi, không treo, vẫn start lại được")
    func failedStartIsReportedAndRecoverable() async {
        let occupier = makeModel()
        await occupier.start()
        #expect(occupier.isRunning)
        // Port thật đang nghe chỉ lộ ra qua statusMessage ("Đang nghe ở host:port").
        // Từ Task 8, statusMessage có thể có thêm hậu tố sau phần port (ví dụ
        // "— đã đặt proxy cho N dịch vụ mạng"), nên tách thêm theo khoảng
        // trắng để chỉ lấy đúng chữ số của port.
        let portText = occupier.statusMessage.split(separator: ":").last?.split(separator: " ").first
        guard let portText, let port = Int(portText) else {
            Issue.record("không đọc được port từ: \(occupier.statusMessage)")
            await occupier.stop()
            return
        }

        let blocked = makeModel(listenPort: port)
        await blocked.start()
        #expect(blocked.isRunning == false)
        #expect(blocked.statusMessage.contains("Không khởi động được"),
                "statusMessage: \(blocked.statusMessage)")

        await occupier.stop()
        await blocked.start()
        #expect(blocked.isRunning,
                "port đã được nhả thì lần bấm lại phải chạy được: \(blocked.statusMessage)")
        await blocked.stop()
    }

    @Test("stop() khi chưa chạy là no-op, không crash")
    func stopWhileNotRunningIsNoOp() async {
        let model = makeModel()
        await model.stop()
        #expect(model.isRunning == false)
        #expect(model.statusMessage == "Chưa chạy")
    }

    @Test("installCertificate() thành công: statusMessage báo thành công, certificateInstalled được refresh")
    func installSucceeds() async {
        let installer = FakeTrustStoreInstaller()
        await installer.setIsInstalledResult(.success(true))
        let model = makeModel(installer: installer)

        await model.installCertificate()

        // Khẳng định cả PHẠM VI, không chỉ "thành công": CA được tin cho
        // riêng tài khoản này chứ không phải cả máy, và người dùng cần biết
        // điều đó — nói "đã cài" trống không là để họ tự suy diễn sai.
        #expect(model.statusMessage.contains("tài khoản này"),
                "status: \(model.statusMessage)")
        #expect(model.certificateInstalled == true)
        #expect(await installer.installCallCount == 1)
    }

    @Test("installCertificate() bị huỷ (TrustStoreError.cancelled) hiện thông báo KHÁC với thất bại thường")
    func installCancelledDiffersFromGenericFailure() async {
        let cancelledInstaller = FakeTrustStoreInstaller()
        await cancelledInstaller.setInstallResult(.failure(TrustStoreError.cancelled))
        let cancelledModel = makeModel(installer: cancelledInstaller)
        await cancelledModel.installCertificate()
        let cancelledMessage = cancelledModel.statusMessage

        let failingInstaller = FakeTrustStoreInstaller()
        await failingInstaller.setInstallResult(
            .failure(TrustStoreError.commandFailed(status: 1, output: "boom"))
        )
        let failingModel = makeModel(installer: failingInstaller)
        await failingModel.installCertificate()
        let failureMessage = failingModel.statusMessage

        #expect(cancelledMessage != failureMessage)
        #expect(cancelledMessage.localizedCaseInsensitiveContains("huỷ"))
    }

    @Test("Hai lần gọi installCertificate() chồng nhau chỉ cài MỘT lần, không bật hai hộp thoại mật khẩu")
    func concurrentInstallCallsShareOneInstall() async {
        let installer = FakeTrustStoreInstaller()
        let model = makeModel(installer: installer)

        async let first: () = model.installCertificate()
        async let second: () = model.installCertificate()
        _ = await (first, second)

        #expect(await installer.installCallCount == 1)
    }

    @Test("refreshCertificateStatus() phản ánh đúng true/false từ installer")
    func refreshReflectsInstallerResult() async {
        let installer = FakeTrustStoreInstaller()
        let model = makeModel(installer: installer)

        await installer.setIsInstalledResult(.success(true))
        await model.refreshCertificateStatus()
        #expect(model.certificateInstalled == true)

        await installer.setIsInstalledResult(.success(false))
        await model.refreshCertificateStatus()
        #expect(model.certificateInstalled == false)
    }

    @Test("refreshCertificateStatus() khi installer throw: certificateInstalled về nil thay vì giữ giá trị cũ, không throw ra ngoài")
    func refreshHandlesThrowingInstaller() async {
        let installer = FakeTrustStoreInstaller()
        await installer.setIsInstalledResult(.success(true))
        let model = makeModel(installer: installer)
        await model.refreshCertificateStatus()
        #expect(model.certificateInstalled == true)

        await installer.setIsInstalledResult(.failure(TrustStoreError.commandFailed(status: 1, output: "no security binary")))
        await model.refreshCertificateStatus()
        #expect(model.certificateInstalled == nil)
        #expect(model.statusMessage.contains("Không kiểm tra được"))
    }

    /// Chốt lại phát hiện ở Task 8: `start()`/`stop()` phải đi qua controller
    /// ĐƯỢC TIÊM VÀO, không bao giờ chạm `/usr/sbin/networksetup` thật.
    /// Khẳng định qua fake nhận đúng lệnh (list + apply lúc start, restore
    /// lúc stop) — đây là cách khẳng định "không gọi lệnh thật" khả thi, vì
    /// bản thân fake chính là thứ được gọi thay cho lệnh thật.
    @Test("start()/stop() gọi qua SystemProxyController được tiêm vào, không đụng networksetup thật")
    func usesInjectedSystemProxyController() async {
        let fake = FakeSystemProxyConfigurer(services: ["Wi-Fi"])
        let model = makeModel(systemProxyConfigurer: fake)

        await model.start()
        #expect(model.setSystemProxy == true)
        #expect(model.statusMessage.contains("đã đặt proxy cho 1 dịch vụ mạng"),
                "statusMessage: \(model.statusMessage)")

        let eventsAfterStart = await fake.events
        #expect(eventsAfterStart.contains(.list))
        #expect(eventsAfterStart.contains { event in
            if case .apply(service: "Wi-Fi", host: "127.0.0.1", port: _) = event { return true }
            return false
        })

        await model.stop()
        let eventsAfterStop = await fake.events
        #expect(eventsAfterStop.contains { event in
            if case .restore(let snapshot) = event { return snapshot.service == "Wi-Fi" }
            return false
        })
    }
}
