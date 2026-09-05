import Foundation
import Crypto
import SwiftASN1
import X509
import NIOSSL

/// Vật liệu TLS sẵn sàng nạp vào NIOSSL cho một host.
public struct TLSIdentity: Sendable {
    public let certificateChain: [NIOSSLCertificate]
    public let privateKey: NIOSSLPrivateKey
}

/// Mint leaf cert theo host, ký bằng Root CA, cache LRU.
public actor LeafCertificateCache {
    private let authority: CertificateAuthority
    private let capacity: Int

    /// Một khoá dùng chung cho MỌI leaf. Nhanh hơn nhiều so với sinh khoá mỗi
    /// host, và không giảm an toàn: khoá vốn nằm cùng process với khoá CA.
    private let leafKey: P256.Signing.PrivateKey
    private let nioLeafKey: NIOSSLPrivateKey
    private let caCertificate: NIOSSLCertificate

    private var cache: [String: Certificate] = [:]
    private var identityCache: [String: TLSIdentity] = [:]
    private var usageOrder: [String] = []   // cuối mảng = vừa dùng gần nhất

    public init(authority: CertificateAuthority, capacity: Int = 512) throws {
        self.authority = authority
        self.capacity = capacity
        self.leafKey = P256.Signing.PrivateKey()
        self.nioLeafKey = try NIOSSLPrivateKey(bytes: Array(leafKey.derRepresentation), format: .der)
        self.caCertificate = try NIOSSLCertificate(
            bytes: authority.certificateDER(), format: .der
        )
    }

    public func identity(forHost host: String) throws -> TLSIdentity {
        if let cached = identityCache[host] {
            touch(host)
            return cached
        }
        let leaf = try certificate(forHost: host)
        var serializer = DER.Serializer()
        try serializer.serialize(leaf)
        let nioLeaf = try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
        // Gửi kèm cert CA để client nào chưa có nó vẫn dựng được chain.
        let identity = TLSIdentity(certificateChain: [nioLeaf, caCertificate], privateKey: nioLeafKey)
        identityCache[host] = identity
        return identity
    }

    public func certificate(forHost host: String) throws -> Certificate {
        if let cached = cache[host] {
            touch(host)
            return cached
        }
        let leaf = try mint(forHost: host)
        cache[host] = leaf
        usageOrder.append(host)
        evictIfNeeded()
        return leaf
    }

    private func mint(forHost host: String) throws -> Certificate {
        let publicKey = Certificate.PublicKey(leafKey.publicKey)
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            // Lùi 1 giờ: máy client lệch đồng hồ là chuyện thường và
            // sẽ biểu hiện thành lỗi TLS rất khó đoán.
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(365 * 24 * 3600),
            issuer: authority.certificate.subject,
            subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
            },
            issuerPrivateKey: authority.privateKey
        )
    }

    private func touch(_ host: String) {
        usageOrder.removeAll { $0 == host }
        usageOrder.append(host)
    }

    private func evictIfNeeded() {
        while usageOrder.count > capacity {
            let oldest = usageOrder.removeFirst()
            cache.removeValue(forKey: oldest)
            identityCache.removeValue(forKey: oldest)
        }
    }
}
