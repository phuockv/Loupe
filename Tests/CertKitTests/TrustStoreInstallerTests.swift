import Testing
import Foundation
@testable import CertKit

@Suite("TrustStoreInstaller")
struct TrustStoreInstallerTests {

    @Test("install cài vào USER domain — không -d, không System keychain")
    func buildsCorrectInstallCommand() async throws {
        let captured = CommandCapture()
        let installer = SecurityCommandInstaller(runner: captured.run)
        try await installer.install(pemPath: URL(fileURLWithPath: "/tmp/ca.pem"))

        let arguments = await captured.arguments
        #expect(arguments == [
            "/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "/tmp/ca.pem",
        ])
    }

    @Test("isInstalled dựng đúng lệnh verify-cert, đi qua readRunner chứ không phải runner cần admin")
    func buildsCorrectIsInstalledCommand() async throws {
        let captured = CommandCapture()
        let installer = SecurityCommandInstaller(
            runner: { _ in throw TestError.shouldNotBeCalled },
            readRunner: captured.run
        )
        _ = try await installer.isInstalled(pemPath: URL(fileURLWithPath: "/tmp/ca.pem"))

        let arguments = await captured.arguments
        #expect(arguments == [
            "/usr/bin/security", "verify-cert", "-l", "-L", "-c", "/tmp/ca.pem",
        ])
    }

    @Test("isInstalled true khi verify-cert thành công (đúng cert, đang được trust làm root)")
    func detectsInstalledCertificate() async throws {
        let installer = SecurityCommandInstaller(
            readRunner: { _ in "...certificate verification successful.\n" }
        )
        #expect(try await installer.isInstalled(pemPath: URL(fileURLWithPath: "/tmp/ca.pem")))
    }

    @Test("isInstalled false khi verify-cert thoát khác 0 (không throw)")
    func detectsMissingCertificateWithoutThrowing() async throws {
        // security thật thoát khác 0 khi cert không được trust làm root (hoặc
        // không tồn tại) — do shell script biến điều đó thành lỗi AppleScript,
        // và runProcess biến lỗi đó thành TrustStoreError.commandFailed.
        // isInstalled phải bắt đúng lỗi này và trả về false, không được để
        // nó văng ra ngoài thành throw (đây từng là bug: "not installed" —
        // trạng thái mặc định của mọi máy trước khi cài — surfaced như một
        // exception).
        let installer = SecurityCommandInstaller(
            readRunner: { _ in
                throw TrustStoreError.commandFailed(
                    status: 1, output: "Cert Verify Result: CSSMERR_TP_NOT_TRUSTED\n"
                )
            }
        )
        #expect(try await installer.isInstalled(pemPath: URL(fileURLWithPath: "/tmp/ca.pem")) == false)
    }

    @Test("isInstalled không nuốt lỗi không phải commandFailed — vẫn throw ra ngoài")
    func propagatesUnexpectedErrors() async throws {
        let installer = SecurityCommandInstaller(
            readRunner: { _ in throw TestError.unexpected }
        )
        await #expect(throws: TestError.self) {
            _ = try await installer.isInstalled(pemPath: URL(fileURLWithPath: "/tmp/ca.pem"))
        }
    }

    @Test("SecurityCommandInstaller.runProcess ép đối số đầu tiên là đường dẫn tuyệt đối")
    func rejectsNonAbsoluteFirstArgument() async throws {
        // Guard này chạy TRƯỚC khi tạo Process — không có lệnh thật nào được
        // exec ở đây, nên phép kiểm này không đụng osascript/security thật.
        await #expect(throws: TrustStoreError.self) {
            _ = try await SecurityCommandInstaller.runProcess(["-e", "return \"INJECTED\""])
        }
    }
}


@Suite("TrustStoreError")
struct TrustStoreErrorTests {

    @Test("commandFailed hiện đúng output cho người dùng, không phải câu chung chung")
    func commandFailedDescribesOutput() {
        let error = TrustStoreError.commandFailed(status: 1, output: "Cert Verify Result: CSSMERR_TP_NOT_TRUSTED")
        #expect(error.errorDescription?.contains("CSSMERR_TP_NOT_TRUSTED") == true)
    }

    @Test("cancelled và commandFailed hiện thông báo khác nhau")
    func cancelledDiffersFromCommandFailed() {
        let cancelled = TrustStoreError.cancelled.errorDescription
        let failed = TrustStoreError.commandFailed(status: 1, output: "lỗi khác").errorDescription
        #expect(cancelled != failed)
        #expect(cancelled != nil)
    }
}

private enum TestError: Error, Equatable {
    case shouldNotBeCalled
    case unexpected
}

/// Bắt lại tham số của lần gọi cuối.
actor CommandCapture {
    private(set) var arguments: [String] = []
    func run(_ arguments: [String]) async throws -> String {
        self.arguments = arguments
        return ""
    }

    /// Khoá chặt hai cờ này, vì đúng chúng đã làm tính năng không chạy được.
    ///
    /// `-d` (admin store) buộc `SecTrustSettingsSetTrustSettings` phải xin
    /// authorization qua hộp thoại trong phiên GUI — thứ một tiến trình root
    /// sinh từ osascript không có. Kết quả là cert vào được keychain nhưng
    /// KHÔNG BAO GIỜ được tin, và app báo "The authorization was denied since
    /// no user interaction was possible". Ai thêm lại `-d` để "cài cho cả máy"
    /// sẽ tái lập đúng lỗi đó.
    @Test("install KHÔNG được dùng -d hay chỉ định System keychain")
    func installNeverRequestsAdminDomain() async throws {
        let captured = CommandCapture()
        let installer = SecurityCommandInstaller(runner: captured.run)
        try await installer.install(pemPath: URL(fileURLWithPath: "/tmp/ca.pem"))
        let arguments = await captured.arguments
        #expect(!arguments.contains("-d"), "-d đưa về admin store, không cài được từ app GUI")
        #expect(!arguments.contains { $0.contains("System.keychain") })
    }

    @Test("Text huỷ được nhận ra; lỗi thật thì KHÔNG bị gán là người dùng huỷ")
    func cancellationDetectionStaysNarrow() {
        #expect(SecurityCommandInstaller.looksCancelled("SecKeychain: User canceled the operation"))
        #expect(SecurityCommandInstaller.looksCancelled("errAuthorizationCanceled"))
        #expect(!SecurityCommandInstaller.looksCancelled(
            "SecTrustSettingsSetTrustSettings: The authorization was denied"),
            "lỗi authorization KHÔNG phải người dùng huỷ — gán nhầm là đổ lỗi cho họ")
        #expect(!SecurityCommandInstaller.looksCancelled("Error reading file"))
    }
}
