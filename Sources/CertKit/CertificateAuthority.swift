import Foundation
import Crypto
import SwiftASN1
import X509

/// Lỗi khi trạng thái CA trên đĩa không dùng được an toàn.
public enum CertificateAuthorityError: Error, Sendable {
    /// Chỉ một trong hai file `ca.pem` / `ca.key.pem` tồn tại. Không tự sinh CA mới ở đây:
    /// hệ thống có thể đã trust CA cũ trong keychain, sinh mới sẽ âm thầm ghi đè và làm
    /// mọi kết nối HTTPS bị chặn lỗi TLS mà không rõ lý do.
    case incompleteOnDiskState(present: String, missing: String)

    /// `ca.key.pem` đọc được nhưng public key của nó không khớp `ca.pem`.
    case keyDoesNotMatchCertificate
}

extension CertificateAuthorityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .incompleteOnDiskState(let present, let missing):
            return """
            CA trên đĩa không đầy đủ: có \(present) nhưng thiếu \(missing). \
            Khôi phục \(missing) từ backup nếu có, hoặc xoá \(present) nếu muốn cố ý sinh CA \
            mới (và chấp nhận phải trust lại CA mới trong keychain hệ thống).
            """
        case .keyDoesNotMatchCertificate:
            return "ca.key.pem không khớp public key với ca.pem — cặp file CA trên đĩa không hợp lệ."
        }
    }
}

/// Root CA của ứng dụng. Sinh một lần rồi nạp lại từ đĩa các lần sau.
public struct CertificateAuthority: Sendable {
    public let certificate: Certificate
    public let signingKey: P256.Signing.PrivateKey

    public var privateKey: Certificate.PrivateKey { Certificate.PrivateKey(signingKey) }

    /// Thư mục mặc định khi chạy thật.
    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loupe/ca", isDirectory: true)
    }

    public static func loadOrCreate(in directory: URL) throws -> CertificateAuthority {
        let certURL = directory.appendingPathComponent("ca.pem")
        let keyURL = directory.appendingPathComponent("ca.key.pem")

        let certExists = FileManager.default.fileExists(atPath: certURL.path)
        let keyExists = FileManager.default.fileExists(atPath: keyURL.path)

        if certExists, keyExists {
            let certificate = try Certificate(pemEncoded: String(contentsOf: certURL, encoding: .utf8))
            let key = try P256.Signing.PrivateKey(
                pemRepresentation: String(contentsOf: keyURL, encoding: .utf8)
            )
            guard Certificate.PublicKey(key.publicKey) == certificate.publicKey else {
                throw CertificateAuthorityError.keyDoesNotMatchCertificate
            }
            return CertificateAuthority(certificate: certificate, signingKey: key)
        }

        // Chỉ một trong hai file tồn tại: KHÔNG được sinh mới đè lên, vì hệ thống có thể
        // đã trust file còn lại (ca.pem) trong keychain.
        if certExists != keyExists {
            throw CertificateAuthorityError.incompleteOnDiskState(
                present: certExists ? "ca.pem" : "ca.key.pem",
                missing: certExists ? "ca.key.pem" : "ca.pem"
            )
        }

        let authority = try generate()
        try authority.persist(certURL: certURL, keyURL: keyURL, directory: directory)
        return authority
    }

    public func certificatePEM() throws -> String {
        try certificate.serializeAsPEM().pemString
    }

    public func certificateDER() throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    private static func generate() throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("Loupe Root CA")
            OrganizationName("Loupe")
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 3600 - 3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                // maxPathLength 0: CA này chỉ được ký leaf, không ký CA con.
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: certKey.publicKey)
            },
            issuerPrivateKey: certKey
        )
        return CertificateAuthority(certificate: certificate, signingKey: key)
    }

    private func persist(certURL: URL, keyURL: URL, directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try certificatePEM().write(to: certURL, atomically: true, encoding: .utf8)
        try signingKey.pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)

        // atomically:true ghi qua file tạm rồi rename, nên quyền phải set SAU khi ghi.
        for url in [certURL, keyURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
