import Foundation
import Crypto
import SwiftASN1
import X509

/// Root CA của ứng dụng. Sinh một lần rồi nạp lại từ đĩa các lần sau.
public struct CertificateAuthority: Sendable {
    public let certificate: Certificate
    public let signingKey: P256.Signing.PrivateKey

    public var privateKey: Certificate.PrivateKey { Certificate.PrivateKey(signingKey) }

    /// Thư mục mặc định khi chạy thật.
    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyManClone/ca", isDirectory: true)
    }

    public static func loadOrCreate(in directory: URL) throws -> CertificateAuthority {
        let certURL = directory.appendingPathComponent("ca.pem")
        let keyURL = directory.appendingPathComponent("ca.key.pem")

        if FileManager.default.fileExists(atPath: certURL.path),
           FileManager.default.fileExists(atPath: keyURL.path) {
            let certificate = try Certificate(pemEncoded: String(contentsOf: certURL, encoding: .utf8))
            let key = try P256.Signing.PrivateKey(
                pemRepresentation: String(contentsOf: keyURL, encoding: .utf8)
            )
            return CertificateAuthority(certificate: certificate, signingKey: key)
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
            CommonName("ProxyManClone Root CA")
            OrganizationName("ProxyManClone")
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
