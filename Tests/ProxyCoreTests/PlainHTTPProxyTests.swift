import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import TrafficModel
import CertKit
@testable import ProxyCore

/// Server HTTP tối giản để test không phải gọi ra mạng ngoài.
final class EchoServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var body = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: body.clear()
        case .body(var buffer): body.writeBuffer(&buffer)
        case .end:
            let payload = "xin chao tu upstream"
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(payload.utf8.count)")
            headers.add(name: "X-Test", value: "1")
            context.write(wrapOutboundOut(.head(
                HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            )), promise: nil)
            var out = context.channel.allocator.buffer(capacity: payload.utf8.count)
            out.writeString(payload)
            context.write(wrapOutboundOut(.body(.byteBuffer(out))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

/// Server HTTP tích luỹ trọn vẹn body nhận được rồi trả lại đúng số byte và
/// checksum trong response, để test có thể khẳng định origin nhận ĐÚNG những
/// gì client gửi — không chỉ "có response 200 là xong".
final class BodyEchoServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var body = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: body.removeAll()
        case .body(let buffer): body.append(Data(buffer.readableBytesView))
        case .end:
            let payload = "bytes=\(body.count)"
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(payload.utf8.count)")
            context.write(wrapOutboundOut(.head(
                HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            )), promise: nil)
            var out = context.channel.allocator.buffer(capacity: payload.utf8.count)
            out.writeString(payload)
            context.write(wrapOutboundOut(.body(.byteBuffer(out))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

@Suite("Proxy HTTP plaintext")
struct PlainHTTPProxyTests {

    private func makeLeafCache() throws -> LeafCertificateCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyTests-\(UUID().uuidString)")
        return try LeafCertificateCache(authority: .loadOrCreate(in: dir))
    }

    private func startEchoServer(group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(EchoServerHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    @Test("GET qua proxy trả đúng body và ghi transaction hoàn tất")
    func proxiesGETAndRecordsTransaction() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        // `syncShutdownGracefully()` is unavailable from async contexts (would block
        // the calling thread); fire-and-forget the async variant instead, matching
        // the shutdown pattern already used below for `server.shutdown()`.
        defer { Task { try? await group.shutdownGracefully() } }

        let origin = try await startEchoServer(group: group)
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        // Thu event ở một task riêng trước khi phát request.
        let collected = Task {
            var events: [TrafficEvent] = []
            for await event in server.events {
                events.append(event)
                if case .completed = event { break }
            }
            return events
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
        ]
        let session = URLSession(configuration: sessionConfig)

        let url = URL(string: "http://127.0.0.1:\(originPort)/hello?q=1")!
        let (data, response) = try await session.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "xin chao tu upstream")

        let events = await collected.value
        guard case .started(let transaction)? = events.first else {
            Issue.record("thiếu event .started"); return
        }
        #expect(transaction.request.method == "GET")
        #expect(transaction.host == "127.0.0.1")
        #expect(transaction.port == originPort)
        #expect(transaction.scheme == .http)
        #expect(transaction.request.queryItems.first?.name == "q")

        guard case .completed(_, let responseModel, _)? = events.last else {
            Issue.record("thiếu event .completed"); return
        }
        #expect(responseModel.statusCode == 200)
        #expect(responseModel.headers.contains { $0.name.lowercased() == "x-test" })
    }

    @Test("Không nối được upstream thì trả 502 và transaction .failed")
    func returns502WhenUpstreamUnreachable() async throws {
        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
        ]
        let session = URLSession(configuration: sessionConfig)

        // Port 1 trên localhost chắc chắn không có ai nghe.
        let url = URL(string: "http://127.0.0.1:1/x")!
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
    }

    @Test("POST body lớn qua proxy tới đúng origin nguyên vẹn, kể cả khi connect upstream chưa xong")
    func postBodySurvivesInFlightUpstreamConnect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(BodyEchoServerHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
        ]
        let session = URLSession(configuration: sessionConfig)

        // 4 MB: đủ lớn để chắc chắn nhiều chunk .body tới trong lúc connect
        // upstream (chỉ mất một round-trip loopback) còn đang xử lý — đây
        // chính là race khiến bug "im lặng đánh rơi byte" tái hiện tất định.
        let bodySize = 4 * 1024 * 1024
        let bodyData = Data(repeating: 0x41, count: bodySize)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(originPort)/upload")!)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        // Trước khi vá: request treo tới khi hết 60s mặc định (origin không
        // bao giờ nhận .end nên không bao giờ trả response). Rút ngắn để
        // test thất bại nhanh thay vì phải đợi timeout mặc định.
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "bytes=\(bodySize)")
    }
}
