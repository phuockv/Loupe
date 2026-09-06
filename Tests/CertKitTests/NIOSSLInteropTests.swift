import Testing
import Foundation
import Crypto
import SwiftASN1
import X509
import NIOSSL
import NIOCore
import NIOPosix
import NIOTLS

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
            let handshakeCompletedPromise = group.next().makePromise(of: String?.self)
            let client = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    do {
                        let tls = try NIOSSLClientHandler(context: clientContext, serverHostname: nil)
                        return channel.pipeline.addHandler(tls).flatMap {
                            channel.pipeline.addHandler(HandshakeCompletionHandler(promise: handshakeCompletedPromise))
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: "127.0.0.1", port: port)
                .get()

            // `connect().get()` chỉ chờ TCP `channelActive`, TRƯỚC khi
            // ClientHello/ServerHello/Finished chạy xong — `client.isActive` không
            // chứng minh handshake TLS đã hoàn tất. `TLSUserEvent.handshakeCompleted`
            // do chính NIOSSLHandler bắn ra sau khi handshake thật sự xong mới là
            // bằng chứng đúng, và giá trị ALPN đi kèm còn xác nhận luôn cấu hình
            // "http/1.1" có hiệu lực.
            let negotiatedProtocol = try await handshakeCompletedPromise.futureResult.get()
            #expect(negotiatedProtocol == "http/1.1")
            try await client.close()
            try await server.close()
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

/// Lý do bắt tay không bao giờ hoàn tất, đủ để đọc thẳng từ output của test.
private struct HandshakeNeverCompleted: Error, CustomStringConvertible {
    let reason: String
    var description: String { "bắt tay TLS không hoàn tất: \(reason)" }
}

/// Bắt sự kiện `TLSUserEvent.handshakeCompleted` mà `NIOSSLHandler` bắn ra sau
/// khi handshake TLS thật sự hoàn tất, để test có bằng chứng đúng thay vì suy
/// diễn từ trạng thái TCP.
///
/// Promise phải được HOÀN TẤT trên mọi đường, kể cả đường hỏng: người chờ nó
/// là một `try await ...futureResult.get()` không có hạn giờ, nên một bắt tay
/// hỏng mà không ai fail promise sẽ treo cả bộ test VĨNH VIỄN thay vì đỏ. Một
/// suite treo đắt hơn nhiều một suite đỏ — CI không nói được gì cho tới khi
/// hết hạn của cả job.
///
/// Hai đường hỏng, cả hai đều phải có: `errorCaught` (bắt tay thất bại) và
/// `channelInactive` (peer đóng TCP mà chưa có lỗi nào được bắn ra).
/// `@unchecked Sendable` (trước đây là `Sendable` thật) vì nay có trạng thái
/// khả biến: cùng lập luận với các handler test khác trong repo — cả ba lối
/// vào đều là callback của pipeline nên luôn chạy trên event loop của channel
/// này, không có lối nào khác chạm tới `hasCompleted`.
private final class HandshakeCompletionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<String?>
    /// `EventLoopPromise` TRAP khi bị hoàn tất hai lần, và đường tới đó có
    /// thật: bắt tay xong rồi channel lỗi/đóng lúc dọn dẹp là chuyện thường
    /// (`NIOSSLError.uncleanShutdown`). Không cần khoá — cả ba lối vào bên
    /// dưới đều là callback của pipeline, tức luôn trên event loop của channel
    /// này (cùng lập luận với các handler trong `ProxyCore`).
    private var hasCompleted = false

    init(promise: EventLoopPromise<String?>) {
        self.promise = promise
    }

    /// `true` nếu lần gọi này là lần đầu — tức được phép hoàn tất promise.
    private func claimCompletion() -> Bool {
        defer { hasCompleted = true }
        return !hasCompleted
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted(let negotiatedProtocol) = event as? TLSUserEvent,
           claimCompletion() {
            promise.succeed(negotiatedProtocol)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if claimCompletion() {
            promise.fail(HandshakeNeverCompleted(reason: "lỗi trên channel — \(error)"))
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if claimCompletion() {
            promise.fail(HandshakeNeverCompleted(
                reason: "channel đóng trước khi có TLSUserEvent.handshakeCompleted"))
        }
        context.fireChannelInactive()
    }
}
