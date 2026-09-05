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

/// Server HTTP tích luỹ trọn vẹn body rồi trả lại số byte + byte đầu/cuối +
/// checksum (tổng modulo) — đủ để phân biệt "origin A nhận đúng body A" và
/// "origin B nhận đúng body B" khi hai request dùng lại MỘT kết nối upstream
/// (không chỉ đếm byte, còn phát hiện nếu nội dung bị lẫn/lệch).
final class ChecksumEchoServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var body = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: body.removeAll()
        case .body(let buffer): body.append(Data(buffer.readableBytesView))
        case .end:
            let sum = body.reduce(UInt64(0)) { $0 &+ UInt64($1) }
            let payload = "count=\(body.count);first=\(body.first ?? 0);last=\(body.last ?? 0);sum=\(sum)"
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

/// Origin nhận `.head` rồi đóng kết nối NGAY, không bao giờ trả response —
/// mô phỏng origin chết giữa chừng (crash/RST) một cách TẤT ĐỊNH, để test
/// đường "upstream chết giữa lúc HTTPProxyHandler còn đang forward request".
final class DropAfterHeadServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head = unwrapInboundIn(data) {
            context.close(promise: nil)
        }
    }
}

/// Gom MỘT response HTTP trọn vẹn (head+body+end) qua promise được đăng ký
/// trước khi gửi request. Dùng trong `RawSequentialClient` để lái đúng MỘT
/// kết nối TCP tới proxy qua nhiều request tuần tự — thứ URLSession không
/// hứa hẹn (không lộ ra việc nó có mở connection mới cho origin khác không),
/// nên test tái dùng-upstream cần tự kiểm soát bằng client thô như thế này.
final class RawResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private var head: HTTPResponseHead?
    private var bodyData = Data()
    /// CHỈ được gán/đọc trên event loop của channel — xem `RawSequentialClient.send`.
    var pendingPromise: EventLoopPromise<(status: Int, body: String)>?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h; bodyData = Data()
        case .body(let buffer): bodyData.append(Data(buffer.readableBytesView))
        case .end:
            guard let head else { return }
            let text = String(data: bodyData, encoding: .utf8) ?? ""
            pendingPromise?.succeed((Int(head.status.code), text))
            pendingPromise = nil
            self.head = nil
        }
    }
}

/// Client HTTP thô, tự quản MỘT kết nối TCP duy nhất tới proxy, để gửi tuần
/// tự nhiều request absolute-form đảm bảo tái dùng đúng một connection —
/// điều kiện bắt buộc để test đường "đổi host trên cùng client connection"
/// một cách tất định, không phụ thuộc hành vi pool connection nội bộ (không
/// quan sát được từ bên ngoài) của URLSession.
struct RawSequentialClient {
    let channel: Channel
    let collector: RawResponseCollector

    static func connect(group: EventLoopGroup, proxyPort: Int) async throws -> RawSequentialClient {
        let collector = RawResponseCollector()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.pipeline.addHandler(collector)
                }
            }
            .connect(host: "127.0.0.1", port: proxyPort)
            .get()
        return RawSequentialClient(channel: channel, collector: collector)
    }

    /// Gửi một request absolute-form POST rồi đợi trọn vẹn response. Đăng ký
    /// promise và ghi request đều được đẩy vào đúng event loop của channel
    /// (qua `submit`/`flatMap`, không có bước nào chạy ngoài nó), nên
    /// `collector.pendingPromise` không bao giờ bị đụng từ hai nơi cùng lúc.
    ///
    /// Có timeout tường minh: nếu bug tái xuất, origin không bao giờ nhận
    /// `.end` nên không bao giờ trả response — không có timeout, test sẽ
    /// treo vĩnh viễn thay vì thất bại rõ ràng (đã tự kiểm chứng bằng cách
    /// chạy thử, treo >3 phút, phải kill process).
    func send(host: String, port: Int, path: String, body: Data,
             timeout: TimeAmount = .seconds(5)) async throws -> (status: Int, body: String) {
        let eventLoop = channel.eventLoop
        let collector = self.collector
        let channel = self.channel
        let future: EventLoopFuture<(status: Int, body: String)> = eventLoop.submit {
            eventLoop.makePromise(of: (status: Int, body: String).self)
        }.flatMap { promise in
            collector.pendingPromise = promise
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "\(host):\(port)")
            headers.add(name: "Content-Length", value: "\(body.count)")
            let head = HTTPRequestHead(version: .http1_1, method: .POST,
                                       uri: "http://\(host):\(port)\(path)", headers: headers)
            channel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
            channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)

            let timeoutTask = eventLoop.scheduleTask(in: timeout) {
                // Nếu response không bao giờ tới (bug tái xuất), đừng để
                // channelRead sau này (nếu có) succeed() một promise đã
                // fail() — dọn tham chiếu trước.
                collector.pendingPromise = nil
                promise.fail(RawSequentialClientTimeoutError())
            }
            promise.futureResult.whenComplete { _ in timeoutTask.cancel() }
            return promise.futureResult
        }
        return try await future.get()
    }

    /// Giống `send`, nhưng gửi `.head` trước rồi đợi `delayBeforeBody` mới
    /// gửi phần body/end còn lại. Dùng để test đường "upstream chết giữa
    /// lúc ta còn đang forward request": khoảng nghỉ đủ lớn để FIN từ origin
    /// (nếu origin đóng ngay khi nhận head, như `DropAfterHeadServerHandler`)
    /// kịp lan tới proxy và được NIO xử lý xong (channelInactive chạy hết)
    /// TRƯỚC KHI ta gửi tiếp — biến một race thật (không chắc thắng) thành
    /// tất định (ta CHỜ cho nó ngã ngũ thay vì đua với nó).
    func sendWithDelayBeforeBody(
        host: String, port: Int, path: String, body: Data,
        delayBeforeBody: Duration, timeout: TimeAmount = .seconds(5)
    ) async throws -> (status: Int, body: String) {
        let eventLoop = channel.eventLoop
        let collector = self.collector
        let channel = self.channel

        let promise: EventLoopPromise<(status: Int, body: String)> =
            try await eventLoop.submit { () -> EventLoopPromise<(status: Int, body: String)> in
                let promise = eventLoop.makePromise(of: (status: Int, body: String).self)
                collector.pendingPromise = promise
                var headers = HTTPHeaders()
                headers.add(name: "Host", value: "\(host):\(port)")
                headers.add(name: "Content-Length", value: "\(body.count)")
                let head = HTTPRequestHead(version: .http1_1, method: .POST,
                                           uri: "http://\(host):\(port)\(path)", headers: headers)
                channel.writeAndFlush(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
                return promise
            }.get()

        try await Task.sleep(for: delayBeforeBody)

        try await eventLoop.submit {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
            channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)

            let timeoutTask = eventLoop.scheduleTask(in: timeout) {
                collector.pendingPromise = nil
                promise.fail(RawSequentialClientTimeoutError())
            }
            promise.futureResult.whenComplete { _ in timeoutTask.cancel() }
        }.get()

        return try await promise.futureResult.get()
    }
}

struct RawSequentialClientTimeoutError: Error, CustomStringConvertible {
    var description: String { "RawSequentialClient.send timed out waiting for a response" }
}

@Suite("Proxy HTTP plaintext")
struct PlainHTTPProxyTests {

    private func makeLeafCache() throws -> LeafCertificateCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyTests-\(UUID().uuidString)")
        return try LeafCertificateCache(authority: .loadOrCreate(in: dir))
    }

    /// Đợi `task` tối đa `seconds` giây; hết giờ thì huỷ `task` và trả `nil`.
    /// Không có hàm này, một hồi quy trong tương lai khiến sự kiện mong đợi
    /// (ví dụ `.completed`) không bao giờ tới sẽ làm cả bộ test TREO thay vì
    /// đỏ — đúng bài học đã áp dụng cho `RawSequentialClient.send`, áp dụng
    /// lại cho việc gom `server.events`.
    private func awaitWithTimeout<T: Sendable>(
        _ task: Task<T, Never>, seconds: Double
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            task.cancel()
            return result
        }
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

        guard let events = await awaitWithTimeout(collected, seconds: 10) else {
            Issue.record("timeout chờ server.events phát đủ .completed"); return
        }
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

        // Thu event ở một task riêng trước khi phát request (cùng pattern
        // với test GET ở trên).
        let collected = Task {
            var events: [TrafficEvent] = []
            for await event in server.events {
                events.append(event)
                if case .completed = event { break }
            }
            return events
        }

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

        // requirement 1 của dispatch gốc: .requestBody phải được phát, mang
        // đúng id của transaction và đúng tổng số byte đã gửi — không có nó,
        // UI (Task 10) không bao giờ hiện được body của request.
        guard let events = await awaitWithTimeout(collected, seconds: 10) else {
            Issue.record("timeout chờ server.events phát đủ .completed"); return
        }
        guard case .started(let transaction)? = events.first else {
            Issue.record("thiếu event .started"); return
        }
        let requestBodyEvents = events.compactMap { event -> (id: UUID, payload: BodyPayload)? in
            guard case .requestBody(let id, let payload) = event else { return nil }
            return (id, payload)
        }
        #expect(requestBodyEvents.count == 1)
        #expect(requestBodyEvents.first?.id == transaction.id)
        #expect(requestBodyEvents.first?.payload.totalBytes == bodySize)
    }

    @Test("POST body nguyên vẹn cho cả hai origin khi request thứ hai đổi host trên cùng kết nối client")
    func postBodySurvivesUpstreamHostSwitch() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await originGroup.shutdownGracefully() } }

        func startChecksumOrigin() async throws -> Channel {
            try await ServerBootstrap(group: originGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(ChecksumEchoServerHandler())
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
        }

        // Hai origin RIÊNG BIỆT: request thứ hai nhắm origin B bắt buộc
        // handler phải mở upstream MỚI (khác host:port với origin A) — đúng
        // đường tái dùng-upstream mà bug CRITICAL (fix round 2, mục 1) từng
        // ghi đè lên channel cũ đã đóng.
        let originA = try await startChecksumOrigin()
        defer { try? originA.close().wait() }
        let originAPort = originA.localAddress!.port!

        let originB = try await startChecksumOrigin()
        defer { try? originB.close().wait() }
        let originBPort = originB.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        // Thu event: phải thấy đủ hai `.completed`, KHÔNG được có `.failed`
        // xen giữa — đó chính xác là triệu chứng của bug mục 2 (đóng upstream
        // cũ rút nhầm transaction MỚI khỏi SessionState dùng chung).
        let collected = Task {
            var events: [TrafficEvent] = []
            var completedCount = 0
            for await event in server.events {
                events.append(event)
                if case .completed = event {
                    completedCount += 1
                    if completedCount == 2 { break }
                }
            }
            return events
        }

        // MỘT kết nối TCP duy nhất tới proxy, tự lái — đảm bảo tái dùng
        // connection thật (không phải giả định về pool của URLSession, thứ
        // không hứa hẹn và không quan sát được từ bên ngoài).
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }
        let client = try await RawSequentialClient.connect(group: clientGroup, proxyPort: proxyPort)
        defer { client.channel.close(promise: nil) }

        // Hai body PHÂN BIỆT rõ ràng (byte lấp đầy khác nhau, độ dài khác
        // nhau) để nếu nội dung bị lẫn giữa hai origin, checksum lệch ngay,
        // không chỉ "count" trùng hợp giống nhau.
        let bodyA = Data(repeating: 0xAA, count: 300_000)
        let bodyB = Data(repeating: 0xBB, count: 500_000)

        let responseA = try await client.send(host: "127.0.0.1", port: originAPort,
                                               path: "/upload-a", body: bodyA)
        let sumA = bodyA.reduce(UInt64(0)) { $0 &+ UInt64($1) }
        #expect(responseA.status == 200)
        #expect(responseA.body == "count=\(bodyA.count);first=170;last=170;sum=\(sumA)")

        let responseB = try await client.send(host: "127.0.0.1", port: originBPort,
                                               path: "/upload-b", body: bodyB)
        let sumB = bodyB.reduce(UInt64(0)) { $0 &+ UInt64($1) }
        #expect(responseB.status == 200)
        #expect(responseB.body == "count=\(bodyB.count);first=187;last=187;sum=\(sumB)")

        guard let events = await awaitWithTimeout(collected, seconds: 10) else {
            Issue.record("timeout chờ server.events phát đủ hai .completed"); return
        }
        let failedEvents = events.filter {
            if case .failed = $0 { return true }
            return false
        }
        #expect(failedEvents.isEmpty)
        let completedCount = events.filter {
            if case .completed = $0 { return true }
            return false
        }.count
        #expect(completedCount == 2)
    }

    @Test("Upstream chết giữa lúc còn đang forward body: transaction .failed đúng một lần, client nhận 502, không có .requestBody")
    func upstreamDeathMidRequestFailsCleanly() async throws {
        let originGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await originGroup.shutdownGracefully() } }

        // Origin đóng kết nối NGAY khi nhận .head, trước khi trả response —
        // tái hiện tất định "upstream chết giữa chừng" (không phụ thuộc
        // timing thật của crash/RST như trên mạng thật).
        let origin = try await ServerBootstrap(group: originGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(DropAfterHeadServerHandler())
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

        // Thu event tới khi có .failed — không đợi .completed (sẽ không
        // bao giờ tới ở test này).
        let collected = Task {
            var events: [TrafficEvent] = []
            for await event in server.events {
                events.append(event)
                if case .failed = event { break }
            }
            return events
        }

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }
        let client = try await RawSequentialClient.connect(group: clientGroup, proxyPort: proxyPort)
        defer { client.channel.close(promise: nil) }

        // 300ms: rất lớn so với một round-trip loopback — đủ để FIN từ
        // origin lan tới proxy và UpstreamHandler.channelInactive chạy xong
        // TRƯỚC KHI ta gửi phần body/end còn lại.
        let response = try await client.sendWithDelayBeforeBody(
            host: "127.0.0.1", port: originPort, path: "/x",
            body: Data(repeating: 0x43, count: 1024),
            delayBeforeBody: .milliseconds(300)
        )
        #expect(response.status == 502)

        guard let events = await awaitWithTimeout(collected, seconds: 10) else {
            Issue.record("timeout chờ .failed event"); return
        }
        let failedCount = events.filter {
            if case .failed = $0 { return true }
            return false
        }.count
        #expect(failedCount == 1)
        let requestBodyCount = events.filter {
            if case .requestBody = $0 { return true }
            return false
        }.count
        #expect(requestBodyCount == 0)
    }
}
