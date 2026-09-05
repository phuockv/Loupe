import Testing
import Foundation
import X509
import NIOSSL
@testable import CertKit

@Suite("LeafCertificateCache")
struct LeafCertificateCacheTests {

    private func makeAuthority() throws -> CertificateAuthority {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafTests-\(UUID().uuidString)")
        return try CertificateAuthority.loadOrCreate(in: dir)
    }

    @Test("Leaf mang đúng SAN dNSName của host")
    func leafCarriesHostSAN() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let leaf = try await cache.certificate(forHost: "api.example.com")

        let san = try leaf.extensions.subjectAlternativeNames
        let names = san?.compactMap { name -> String? in
            if case .dnsName(let value) = name { return value }
            return nil
        } ?? []
        #expect(names == ["api.example.com"])
    }

    @Test("Leaf chain hợp lệ tới Root CA")
    func leafChainsToAuthority() async throws {
        let authority = try makeAuthority()
        let cache = try LeafCertificateCache(authority: authority)
        let leaf = try await cache.certificate(forHost: "api.example.com")

        var verifier = Verifier(rootCertificates: CertificateStore([authority.certificate])) {
            RFC5280Policy()
        }
        let result = await verifier.validate(leaf: leaf, intermediates: CertificateStore())

        guard case .validCertificate = result else {
            Issue.record("chain không verify được: \(result)"); return
        }
    }

    @Test("notBefore lùi về quá khứ để chịu lệch đồng hồ")
    func notBeforeIsBackdated() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let leaf = try await cache.certificate(forHost: "api.example.com")
        #expect(leaf.notValidBefore < Date().addingTimeInterval(-1800))
    }

    @Test("Cùng host thì trả lại cert đã cache, không mint mới")
    func cachesPerHost() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let first = try await cache.certificate(forHost: "api.example.com")
        let second = try await cache.certificate(forHost: "api.example.com")
        #expect(first.serialNumber == second.serialNumber)
    }

    @Test("Vượt capacity thì host cũ nhất bị đẩy ra")
    func evictsLeastRecentlyUsed() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority(), capacity: 2)
        let a1 = try await cache.certificate(forHost: "a.com")
        _ = try await cache.certificate(forHost: "b.com")
        _ = try await cache.certificate(forHost: "c.com")   // đẩy a.com ra
        let a2 = try await cache.certificate(forHost: "a.com")
        #expect(a1.serialNumber != a2.serialNumber, "a.com lẽ ra đã bị evict và phải mint lại")
    }

    @Test("identity() trả về vật liệu NIOSSL dùng được")
    func producesUsableNIOSSLIdentity() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let identity = try await cache.identity(forHost: "api.example.com")

        // Dựng được NIOSSLContext nghĩa là BoringSSL đã chấp nhận cặp cert/key.
        let config = TLSConfiguration.makeServerConfiguration(
            certificateChain: identity.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(identity.privateKey)
        )
        _ = try NIOSSLContext(configuration: config)
    }
}
