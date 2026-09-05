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

    @Test("Chỉ có ca.pem mà thiếu ca.key.pem thì báo lỗi, không ghi đè ca.pem")
    func throwsWhenOnlyCertificateFileExists() throws {
        let dir = tempDir()
        _ = try CertificateAuthority.loadOrCreate(in: dir)

        let certURL = dir.appendingPathComponent("ca.pem")
        let keyURL = dir.appendingPathComponent("ca.key.pem")
        try FileManager.default.removeItem(at: keyURL)
        let certBefore = try String(contentsOf: certURL, encoding: .utf8)

        #expect(throws: CertificateAuthorityError.self) {
            _ = try CertificateAuthority.loadOrCreate(in: dir)
        }

        // Bằng chứng thật: ca.pem cũ (mà hệ thống có thể đã trust) không bị đè.
        let certAfter = try String(contentsOf: certURL, encoding: .utf8)
        #expect(certAfter == certBefore)
    }

    @Test("Chỉ có ca.key.pem mà thiếu ca.pem thì báo lỗi, không ghi đè ca.key.pem")
    func throwsWhenOnlyKeyFileExists() throws {
        let dir = tempDir()
        _ = try CertificateAuthority.loadOrCreate(in: dir)

        let certURL = dir.appendingPathComponent("ca.pem")
        let keyURL = dir.appendingPathComponent("ca.key.pem")
        try FileManager.default.removeItem(at: certURL)
        let keyBefore = try String(contentsOf: keyURL, encoding: .utf8)

        #expect(throws: CertificateAuthorityError.self) {
            _ = try CertificateAuthority.loadOrCreate(in: dir)
        }

        let keyAfter = try String(contentsOf: keyURL, encoding: .utf8)
        #expect(keyAfter == keyBefore)
    }

    @Test("ca.pem và ca.key.pem không khớp nhau thì báo lỗi thay vì trả về CA hỏng")
    func throwsWhenCertificateAndKeyMismatch() throws {
        let dirA = tempDir()
        let dirB = tempDir()
        _ = try CertificateAuthority.loadOrCreate(in: dirA)
        _ = try CertificateAuthority.loadOrCreate(in: dirB)

        // Trộn cert của A với key của B: cả hai file đều parse được, nhưng không khớp nhau.
        let mixedDir = tempDir()
        try FileManager.default.createDirectory(at: mixedDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: dirA.appendingPathComponent("ca.pem"),
            to: mixedDir.appendingPathComponent("ca.pem")
        )
        try FileManager.default.copyItem(
            at: dirB.appendingPathComponent("ca.key.pem"),
            to: mixedDir.appendingPathComponent("ca.key.pem")
        )

        #expect(throws: CertificateAuthorityError.self) {
            _ = try CertificateAuthority.loadOrCreate(in: mixedDir)
        }
    }
}
