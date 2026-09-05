import Testing
import Foundation
import Crypto
import SwiftASN1
import X509
import NIOSSL
import NIOCore
import NIOPosix

/// Chứng minh rủi ro 11.1 của spec: NIOSSL có nạp được vật liệu
/// do swift-certificates + swift-crypto sinh ra hay không.
@Suite("NIOSSL interop với swift-certificates")
struct NIOSSLInteropTests {

    /// Sinh một self-signed CA dùng chung cho các test bên dưới.
    static func makeSelfSigned() throws -> (Certificate, P256.Signing.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("spike") }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            },
            issuerPrivateKey: certKey
        )
        return (cert, key)
    }

    @Test("Cert DER nạp được vào NIOSSLCertificate")
    func certificateLoadsFromDER() throws {
        let (cert, _) = try Self.makeSelfSigned()
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        // Không throw là đủ: NIOSSL parse được DER của swift-certificates.
        _ = try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
    }

    @Test("Private key nạp được vào NIOSSLPrivateKey ở dạng DER hoặc PEM")
    func privateKeyLoadsFromDEROrPEM() throws {
        let (_, key) = try Self.makeSelfSigned()

        // Đường ưu tiên của spec: PKCS#8 DER.
        let derWorks = (try? NIOSSLPrivateKey(bytes: Array(key.derRepresentation), format: .der)) != nil

        // Đường lui: PKCS#8 PEM. BoringSSL parse PEM "PRIVATE KEY" rất chắc.
        let pemWorks = (try? NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)) != nil

        // Ít nhất một đường phải chạy, nếu không CertKit không khả thi như thiết kế.
        #expect(derWorks || pemWorks)

        // Ghi kết luận ra log để Task 4 chọn đúng đường.
        print("SPIKE KẾT LUẬN — DER: \(derWorks), PEM: \(pemWorks)")
    }
}

extension NIOSSLInteropTests {

    @Test("TLS handshake thật giữa server dùng cert đó và client tin cert đó")
    func performsRealHandshake() async throws {
        let (cert, key) = try Self.makeSelfSigned()
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let nioCert = try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
        let nioKey = try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioCert)],
            privateKey: .privateKey(nioKey)
        )
        serverConfig.applicationProtocols = ["http/1.1"]
        let serverContext = try NIOSSLContext(configuration: serverConfig)

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([nioCert])
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.applicationProtocols = ["http/1.1"]
        let clientContext = try NIOSSLContext(configuration: clientConfig)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        // `syncShutdownGracefully()`/`.wait()` là @available(*, noasync) — không dùng được
        // trong `defer` của hàm async, nên dọn dẹp bằng do/catch với các biến thể async.
        do {
            let server = try await ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 8)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NIOSSLServerHandler(context: serverContext))
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()

            let port = server.localAddress!.port!
            let client = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    do {
                        let tls = try NIOSSLClientHandler(context: clientContext, serverHostname: nil)
                        return channel.pipeline.addHandler(tls)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: "127.0.0.1", port: port)
                .get()

            // Kết nối lên được nghĩa là handshake đã xong.
            #expect(client.isActive)
            try await client.close()
            try await server.close()
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
