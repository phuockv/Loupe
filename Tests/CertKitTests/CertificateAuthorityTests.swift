import Testing
import Foundation
import X509
@testable import CertKit

@Suite("CertificateAuthority")
struct CertificateAuthorityTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CATests-\(UUID().uuidString)")
    }

    @Test("Sinh mới thì ghi ra hai file PEM với quyền 0600")
    func createsPEMFilesWithTightPermissions() throws {
        let dir = tempDir()
        _ = try CertificateAuthority.loadOrCreate(in: dir)

        for name in ["ca.pem", "ca.key.pem"] {
            let path = dir.appendingPathComponent(name).path
            #expect(FileManager.default.fileExists(atPath: path))
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
            #expect(perms == 0o600, "khoá CA lộ quyền đọc là lỗi bảo mật thật")
        }
    }

    @Test("Gọi lần hai thì nạp lại đúng CA cũ, không sinh mới")
    func reloadsExistingAuthority() throws {
        let dir = tempDir()
        let first = try CertificateAuthority.loadOrCreate(in: dir)
        let second = try CertificateAuthority.loadOrCreate(in: dir)
        #expect(first.certificate.serialNumber == second.certificate.serialNumber)
    }

    @Test("CA có BasicConstraints isCA và KeyUsage keyCertSign")
    func hasCorrectCAExtensions() throws {
        let ca = try CertificateAuthority.loadOrCreate(in: tempDir())

        let basic = try ca.certificate.extensions.basicConstraints
        #expect(basic == .isCertificateAuthority(maxPathLength: 0))

        let usage = try ca.certificate.extensions.keyUsage
        #expect(usage?.keyCertSign == true)
        #expect(usage?.cRLSign == true)
    }

    @Test("Hạn CA khoảng 10 năm")
    func validForAboutTenYears() throws {
        let ca = try CertificateAuthority.loadOrCreate(in: tempDir())
        let years = ca.certificate.notValidAfter
            .timeIntervalSince(ca.certificate.notValidBefore) / (365 * 24 * 3600)
        #expect(years > 9.9 && years < 10.1)
    }
}
