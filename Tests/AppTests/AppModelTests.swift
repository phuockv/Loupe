import Testing
import Foundation
import TrafficModel
import CertKit
import ProxyCore
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

@MainActor
@Suite("AppModel")
struct AppModelTests {

    /// `caDirectory` luôn là một thư mục tạm riêng cho test — không bao giờ
    /// `CertificateAuthority.defaultDirectory` thật, nếu không mỗi lần chạy
    /// test sẽ ghi CA xuống đúng Application Support của máy đang chạy nó.
    private func makeModel(
        installer: FakeTrustStoreInstaller = FakeTrustStoreInstaller()
    ) -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)")
        var config = ProxyConfiguration()
        config.listenPort = 0
        return AppModel(configuration: config, installer: installer, caDirectory: dir)
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

        #expect(model.statusMessage.contains("Đã cài"))
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
}
