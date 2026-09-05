import Testing
import Foundation
@testable import CertKit

@Suite("TrustStoreInstaller")
struct TrustStoreInstallerTests {

    @Test("install dựng đúng lệnh add-trusted-cert vào System keychain")
    func buildsCorrectInstallCommand() async throws {
        let captured = CommandCapture()
        let installer = SecurityCommandInstaller(runner: captured.run)
        try await installer.install(pemPath: URL(fileURLWithPath: "/tmp/ca.pem"))

        let arguments = await captured.arguments
        #expect(arguments.contains("add-trusted-cert"))
        #expect(arguments.contains("trustRoot"))
        #expect(arguments.contains("/Library/Keychains/System.keychain"))
        #expect(arguments.contains("/tmp/ca.pem"))
    }

    @Test("isInstalled true khi security tìm thấy common name")
    func detectsInstalledCertificate() async throws {
        let installer = SecurityCommandInstaller(
            runner: { _ in "1 certificates found\n    \"alis\"<blob>=\"ProxyManClone Root CA\"" }
        )
        #expect(try await installer.isInstalled(commonName: "ProxyManClone Root CA"))
    }

    @Test("isInstalled false khi không tìm thấy")
    func detectsMissingCertificate() async throws {
        let installer = SecurityCommandInstaller(runner: { _ in "" })
        #expect(try await installer.isInstalled(commonName: "ProxyManClone Root CA") == false)
    }
}

/// Bắt lại tham số của lần gọi cuối.
actor CommandCapture {
    private(set) var arguments: [String] = []
    func run(_ arguments: [String]) async throws -> String {
        self.arguments = arguments
        return ""
    }
}
