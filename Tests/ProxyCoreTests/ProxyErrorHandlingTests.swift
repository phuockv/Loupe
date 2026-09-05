import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import CertKit
import TrafficModel
@testable import ProxyCore

/// Gom mọi byte nhận được cho tới khi peer đóng, rồi hoàn tất promise.
///
/// Dùng EOF làm mốc dừng chứ không đếm byte: ba nhánh lỗi dưới đây đều kết thúc
/// bằng "proxy trả lời rồi đóng", nên EOF là tín hiệu quan sát được và không
/// phải đoán trước độ dài của một message có thể đổi.
final class ResponseUntilCloseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var received = Data()
    private let promise: EventLoopPromise<Data>

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(Data(unwrapInboundIn(data).readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.succeed(received)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

@Suite("Xử lý lỗi")
struct ProxyErrorHandlingTests {

    private func makeServer(
        configure: (inout ProxyConfiguration) -> Void = { _ in }
    ) async throws -> (server: ProxyServer, port: Int, caPath: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrTests-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []
        configure(&config)
        let server = ProxyServer(
            configuration: config,
            leafCache: try LeafCertificateCache(authority: authority)
        )
        let port = try await server.start()
        return (server, port, dir.appendingPathComponent("ca.pem").path)
    }

    /// Gửi một request thô tới proxy rồi đọc TẤT CẢ byte trả về cho tới khi
    /// proxy đóng kết nối.
    private func rawExchange(
        group: EventLoopGroup, proxyPort: Int, request: String
    ) async throws -> String {
        let promise = group.next().makePromise(of: Data.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ResponseUntilCloseHandler(promise: promise))
            }
            .connect(host: "127.0.0.1", port: proxyPort)
            .get()
        // Hạn cứng để một hồi quy "proxy im lặng treo" làm test ĐỎ chứ không
        // treo theo — đây là điều kiện thất bại, không phải cách đồng bộ hoá.
        channel.eventLoop.scheduleTask(in: .seconds(10)) {
            promise.fail(TimedOutWaitingForProxy())
        }
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await channel.writeAndFlush(buffer)
        let data = try await promise.futureResult.get()
        try? await channel.close()
        return String(decoding: data, as: UTF8.self)
    }

    struct TimedOutWaitingForProxy: Error, CustomStringConvertible {
        var description: String { "hết giờ chờ proxy trả lời rồi đóng" }
    }

    /// Leaf cert dùng SAN `dNSName`; một IP trần cần SAN `iPAddress`. Mint
    /// `dNSName: "192.0.2.1"` sẽ ra một cert không client nào chấp nhận, và
    /// triệu chứng là lỗi TLS khó đoán thay vì một câu đọc được.
    ///
    /// Dùng socket thô chứ không phải curl vì bài này khẳng định cả THÔNG BÁO,
    /// mà curl nuốt body của một response CONNECT thất bại.
    @Test("CONNECT tới IP trần bị từ chối bằng 502 có thông báo đọc được")
    func rejectsBareIPConnect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let (server, port, _) = try await makeServer()
        defer { Task { try? await server.shutdown() } }

        // 192.0.2.0/24 là TEST-NET-1 (RFC 5737): không định tuyến ở đâu cả, nên
        // kể cả một hồi quy làm proxy thử kết nối cũng không ra được Internet.
        let response = try await rawExchange(
            group: group, proxyPort: port,
            request: "CONNECT 192.0.2.1:443 HTTP/1.1\r\nHost: 192.0.2.1:443\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"),
                "response: \(response)")
        #expect(response.contains("bypass list"),
                "thông báo phải chỉ ra lối đi tiếp, nhận: \(response)")
    }

    /// IPv6 trần đi qua `parseConnectTarget` ở dạng CÓ NGOẶC (`[::1]`), nên
    /// phép kiểm phải cắt ngoặc trước khi `inet_pton`. Thiếu bước đó thì nhánh
    /// IPv6 lọt lưới và đi thẳng vào MitM với một leaf vô dụng.
    @Test("CONNECT tới IPv6 trần trong ngoặc cũng bị từ chối bằng 502")
    func rejectsBareIPv6Connect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let (server, port, _) = try await makeServer()
        defer { Task { try? await server.shutdown() } }

        let response = try await rawExchange(
            group: group, proxyPort: port,
            request: "CONNECT [2001:db8::1]:443 HTTP/1.1\r\nHost: [2001:db8::1]:443\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"),
                "response: \(response)")
    }

    /// `bootstrap.connect` hoàn tất ngay khi TCP nối được — bắt tay TLS xảy ra
    /// SAU đó. Nên lỗi verify cert upstream KHÔNG rơi vào nhánh `.failure` của
    /// `connectUpstream` mà tới `errorCaught` của `UpstreamHandler`. Nếu chỗ đó
    /// chỉ ghi event, client không nhận được gì và treo tới timeout.
    @Test("Origin dùng cert không tin được thì client nhận 502, không phải treo")
    func returns502WhenUpstreamCertificateUntrusted() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer { Task { try? await group.shutdownGracefully() } }

        // CA của origin KHÁC CA của proxy, và KHÔNG nằm trong additionalTrustRoots.
        let strangerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stranger-\(UUID().uuidString)")
        let stranger = try CertificateAuthority.loadOrCreate(in: strangerDir)
        let origin = try await startTLSOriginServer(
            group: group, authority: stranger, host: "localhost"
        )
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        let (server, proxyPort, caPath) = try await makeServer()
        defer { Task { try? await server.shutdown() } }

        // curl tin CA của PROXY (nên bắt tay phía client xong xuôi), nhưng proxy
        // không tin CA của origin.
        let curl = try runCurl([
            "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "--cacert", caPath,
            "-x", "http://127.0.0.1:\(proxyPort)",
            "https://localhost:\(originPort)/",
        ])
        #expect(curl.output == "502", "proxy phải báo 502 chứ không im lặng treo")
    }

    /// Nhánh lỗi hay gặp NHẤT khi bắt app thật. Bài trong `ConnectTunnelTests`
    /// phủ đường "client không nói TLS chút nào" (record hỏng); bài này phủ
    /// đường KHÁC trong BoringSSL: một client TLS thật bắt tay đàng hoàng rồi
    /// bắn TLS alert vì không tin CA — đúng hành vi của một app pin cert.
    @Test("Client từ chối cert của proxy thì transaction ghi gợi ý cert pinning")
    func hintsAtCertificatePinningWhenClientRejectsLeaf() async throws {
        let (server, port, _) = try await makeServer()
        defer { Task { try? await server.shutdown() } }

        let collected = Task { () -> String? in
            for await event in server.events {
                if case .failed(_, let message, _) = event { return message }
            }
            return nil
        }

        // Không truyền --cacert: curl không tin CA của proxy và sẽ gửi TLS
        // alert, đúng như một app có cert pinning. `.invalid` (RFC 6761) không
        // bao giờ phân giải được, nên kể cả một hồi quy làm proxy thử kết nối
        // upstream cũng không chạm tới mạng ngoài.
        _ = try runCurl([
            "-sS", "-o", "/dev/null",
            "-x", "http://127.0.0.1:\(port)", "https://pinned.invalid/",
        ])

        // `?? nil` làm phẳng `String??`: lớp ngoài là "hết giờ", lớp trong là
        // "stream kết thúc mà không có .failed nào". Cả hai đều là thất bại.
        let message = try #require((await awaitEventsWithTimeout(collected, seconds: 10)) ?? nil)
        #expect(message.lowercased().contains("pinning"),
                "người dùng cần gợi ý bypass list, không phải một chuỗi lỗi TLS thô: \(message)")
    }
}
