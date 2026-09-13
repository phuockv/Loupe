import Testing
import Foundation
import NIOCore
import NIOEmbedded
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

}

struct RawSequentialClientTimeoutError: Error, CustomStringConvertible {
    var description: String { "RawSequentialClient.send timed out waiting for a response" }
}

/// Cho mọi write outbound đi tiếp xuống dưới NHƯNG giữ lại promise của chúng,
/// chưa hoàn tất cho tới khi test gọi `completeAll()`.
///
/// Dựng lại một trạng thái CÓ THẬT mà `HTTPProxyHandler.respond` phụ thuộc
/// vào: send buffer phía client đang đầy, nên `writeAndFlush` chưa xong, nên
/// `channel.close()` xếp trong completion của nó CHƯA chạy — trong khi decoder
/// vẫn giao nốt `.body`/`.end` của CÙNG một lượt đọc. Trên `EmbeddedChannel`
/// promise hoàn tất ngay lập tức, nên không có handler này thì channel đóng
/// trước khi phần body kịp tới và nhánh cần kiểm không chạy được lần nào.
final class StallingWriteHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private var stalled: [EventLoopPromise<Void>] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Dữ liệu vẫn đi tiếp để `readOutbound` quan sát được; chỉ promise bị giữ.
        if let promise { stalled.append(promise) }
        context.write(data, promise: nil)
    }

    /// Nhả hết promise đang giữ. BẮT BUỘC gọi trước khi test kết thúc: NIO bắt
    /// một `EventLoopPromise` chưa hoàn tất khi nó bị giải phóng.
    func completeAll() {
        let pending = stalled
        stalled = []
        for promise in pending { promise.succeed(()) }
    }
}

/// Thu MỌI `TrafficEvent` mà proxy phát ra (không dừng ở event đầu tiên nào
/// cả), và tuỳ chọn chạy một hành động đúng lúc `.started` đang được phát.
///
/// Thu hết là điểm mấu chốt: một vòng lặp `break` ngay ở `.failed` đầu tiên
/// thì mệnh đề "chỉ có đúng MỘT `.failed`" không thể sai được, nên nó cũng
/// không chứng minh được gì.
///
/// `onStarted` mô phỏng thứ mà `sink` thật sự là: closure do NGƯỜI GỌI cung
/// cấp, chạy xen giữa lúc `HTTPProxyHandler` kiểm tra upstream còn sống và
/// lúc nó thực sự ghi head ra upstream.
///
/// `@unchecked Sendable` giống các handler test khác trong file này: mọi
/// truy cập đều nằm trên đúng một thread — các test dùng lớp này tự lái
/// `EmbeddedEventLoop` đồng bộ, không có điểm await nào ở giữa.
final class RecordingSink: @unchecked Sendable {
    private(set) var events: [TrafficEvent] = []
    var onStarted: (() -> Void)?

    func record(_ event: TrafficEvent) {
        events.append(event)
        if case .started = event { onStarted?() }
    }

    var startedCount: Int {
        events.filter { if case .started = $0 { return true }; return false }.count
    }
    var completedCount: Int {
        events.filter { if case .completed = $0 { return true }; return false }.count
    }
    var failedCount: Int {
        events.filter { if case .failed = $0 { return true }; return false }.count
    }
    var requestBodyCount: Int {
        events.filter { if case .requestBody = $0 { return true }; return false }.count
    }
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

        // Lời hứa NẶNG NHẤT của một công cụ bắt gói: body nó HIỆN đúng bằng
        // byte đã đi trên dây. Khẳng định phía trên (và cả `data` mà client
        // nhận được) chỉ chứng minh việc CHUYỂN TIẾP; nếu `UpstreamHandler`
        // ngừng tích luỹ vào `BodyCollector` thì mọi thứ đó vẫn xanh trong
        // khi bản GHI rỗng. Đây là chỗ duy nhất trong bộ test soi bản ghi đó.
        guard case .inMemory(let recordedBody) = responseModel.body else {
            Issue.record("body ghi lại phải là .inMemory, nhận: \(responseModel.body)")
            return
        }
        #expect(String(decoding: recordedBody, as: UTF8.self) == "xin chao tu upstream")
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

    @Test("Origin đóng trước khi trả response: client nhận 502 và .failed mang đúng id transaction")
    func upstreamDeathBeforeResponseReaches502() async throws {
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

        // Không có sleep nào ở đây: origin đóng ngay khi nhận `.head` và
        // KHÔNG BAO GIỜ trả response, nên dù proxy có kịp forward hết
        // body/end trước khi thấy FIN hay không, kết cục vẫn y hệt —
        // `UpstreamHandler.channelInactive` thấy transaction đang chờ, phát
        // `.failed` và trả 502. Kết quả tất định theo mọi thứ tự đan xen.
        let response = try await client.send(host: "127.0.0.1", port: originPort,
                                             path: "/x",
                                             body: Data(repeating: 0x43, count: 1024))
        #expect(response.status == 502)

        guard let events = await awaitWithTimeout(collected, seconds: 10) else {
            Issue.record("timeout chờ .failed event"); return
        }
        guard case .started(let transaction)? = events.first else {
            Issue.record("thiếu event .started"); return
        }
        guard case .failed(let failedID, _, _)? = events.last else {
            Issue.record("thiếu event .failed"); return
        }
        // Đúng transaction bị đánh hỏng — không phải "có một .failed nào đó".
        #expect(failedID == transaction.id)
        // CHÚ Ý: vòng thu ở trên dừng ngay tại `.failed` ĐẦU TIÊN, nên test
        // này KHÔNG chứng minh được "chỉ có đúng một `.failed`" (một báo cáo
        // trùng lặp sẽ không quan sát được ở đây). Tính chất đó được kiểm
        // tất định, thu trọn vẹn mọi event, ở
        // `upstreamDeathWithPendingTransactionReportsExactlyOnce`.
    }

    // MARK: - Test tất định trên EmbeddedChannel
    //
    // Ba test dưới đây lái thẳng `HTTPProxyHandler` trên `EmbeddedChannel`,
    // với upstream do test cầm trực tiếp. Lý do không dùng socket thật:
    // trạng thái cần kiểm là "upstream đã chết mà handler chưa biết", và qua
    // socket thật ta không dựng được nó tất định — trong đúng khoảnh khắc
    // upstream chết, `UpstreamHandler.channelInactive` đã trả 502 và đóng
    // client, nên phần body còn lại của client không bao giờ tới được chỗ
    // cần kiểm (đó chính là chỗ hỏng của phiên bản test cũ dùng sleep 300ms:
    // nhánh cần kiểm không hề chạy trong một lần chạy PASS).
    //
    // Stub "đã chết" là một `EmbeddedChannel` CHƯA connect: `isActive ==
    // false` y như một channel đã chết, nhưng còn MỞ nên nó GHI LẠI mọi
    // write lọt qua guard. Một channel đóng thật thì nuốt luôn write — tức
    // là chính sự im lặng ta muốn chứng minh lại không quan sát được.

    private func makeEmbeddedProxy(
        loop: EmbeddedEventLoop, recorder: RecordingSink,
        configuration: ProxyConfiguration, target: HTTPProxyHandler.Target
    ) throws -> (handler: HTTPProxyHandler, client: EmbeddedChannel) {
        let handler = HTTPProxyHandler(configuration: configuration,
                                       sink: { recorder.record($0) },
                                       fixedTarget: target)
        let client = EmbeddedChannel(handler: handler, loop: loop)
        client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        return (handler, client)
    }

    private func requestHead(contentLength: Int?) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:8080")
        if let contentLength {
            headers.add(name: "Content-Length", value: "\(contentLength)")
        }
        return HTTPRequestHead(version: .http1_1, method: .POST, uri: "/upload",
                               headers: headers)
    }

    @Test("Head không được ghi ra upstream đã chết, kể cả khi nó chết ngay trong lúc sink .started chạy")
    func headNeverWrittenToUpstreamThatDiedDuringStartedSink() throws {
        let loop = EmbeddedEventLoop()
        // Đóng channel xong mới `run()`: `EmbeddedChannel.close` xếp một task
        // dọn pipeline lên loop, còn `EmbeddedEventLoop.deinit` precondition
        // là không còn task nào chưa chạy. defer đăng ký TRƯỚC nên chạy SAU.
        defer { loop.run() }
        let target = HTTPProxyHandler.Target(host: "127.0.0.1", port: 8080, scheme: .http)
        let recorder = RecordingSink()
        let (handler, client) = try makeEmbeddedProxy(
            loop: loop, recorder: recorder,
            configuration: ProxyConfiguration(), target: target)
        defer { client.close(promise: nil) }

        let live = EmbeddedChannel(loop: loop)
        defer { live.close(promise: nil) }
        live.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: live, target: target)

        let dead = EmbeddedChannel(loop: loop)
        defer { dead.close(promise: nil) }
        #expect(dead.isActive == false)

        // `sink` chạy giữa "isUpstreamReusable vừa xác nhận upstream còn
        // sống" và "handleUpstreamReady ghi head ra upstream" — và nó là
        // closure do người gọi truyền vào. Ở đây nó làm đúng cái mà một sink
        // thật (hoặc một handler Task 7/8 gắn thêm vào pipeline) có thể làm
        // gián tiếp: khiến upstream không còn dùng được, mà không sửa một
        // dòng nào trong `HTTPProxyHandler`.
        recorder.onStarted = { [weak handler] in
            handler?.upstream = HTTPProxyHandler.UpstreamConnection(channel: dead, target: target)
        }

        try client.writeInbound(HTTPServerRequestPart.head(requestHead(contentLength: nil)))

        #expect(recorder.startedCount == 1)
        #expect(try dead.readOutbound(as: HTTPClientRequestPart.self) == nil)
        #expect(try live.readOutbound(as: HTTPClientRequestPart.self) == nil)
    }

    @Test("Origin trả lời sớm rồi đóng: phần body còn lại bị nuốt, không ghi ra upstream chết, không có response thứ hai")
    func deadUpstreamAfterEarlyResponseNeitherWritesNorAnswersTwice() throws {
        let loop = EmbeddedEventLoop()
        defer { loop.run() }
        var config = ProxyConfiguration()
        // Cap nhỏ để phần body gửi SAU khi upstream chết vượt cap ngay: đó
        // là cách duy nhất làm cho lỗi "phân loại lại phần còn lại thành
        // bufferable" lộ ra ngoài — nó biến thành một 502 THỨ HAI.
        config.maxInMemoryBodyBytes = 1024
        let target = HTTPProxyHandler.Target(host: "127.0.0.1", port: 8080, scheme: .http)
        let recorder = RecordingSink()
        let (handler, client) = try makeEmbeddedProxy(
            loop: loop, recorder: recorder, configuration: config, target: target)
        defer { client.close(promise: nil) }

        // Upstream "thật": đã connect, mang `UpstreamHandler` dùng CHUNG
        // `SessionState` với handler — đúng như `connectUpstream` dựng.
        let live = EmbeddedChannel(
            handler: UpstreamHandler(clientChannel: client, configuration: config,
                                     sink: { recorder.record($0) }, state: handler.state),
            loop: loop)
        defer { live.close(promise: nil) }
        live.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: live, target: target)

        try client.writeInbound(HTTPServerRequestPart.head(requestHead(contentLength: 4096)))
        guard case .head? = try live.readOutbound(as: HTTPClientRequestPart.self) else {
            Issue.record("upstream còn sống phải nhận được request head"); return
        }

        // Origin trả lời SỚM (413) rồi đóng, trong khi client vẫn đang
        // upload. Đây là đường đi CÓ THẬT tới nhánh "upstream đã chết":
        // transaction đã `.completed`, nên khi upstream đóng,
        // `failAllPending` thấy hàng đợi rỗng (`hadPending == false`) →
        // không phát `.failed` và KHÔNG đóng client. Client cứ thế gửi nốt
        // body vào một kết nối upstream đã chết.
        try live.writeInbound(HTTPClientResponsePart.head(
            HTTPResponseHead(version: .http1_1, status: .payloadTooLarge)))
        try live.writeInbound(HTTPClientResponsePart.end(nil))
        guard case .head(let firstResponse)? = try client.readOutbound(as: HTTPServerResponsePart.self) else {
            Issue.record("client phải nhận được response 413"); return
        }
        #expect(firstResponse.status == .payloadTooLarge)
        guard case .end? = try client.readOutbound(as: HTTPServerResponsePart.self) else {
            Issue.record("response 413 phải kết thúc bằng .end"); return
        }

        // Upstream chết. Trong production `handler.upstream` lúc này vẫn trỏ
        // vào chính channel vừa đóng (`isActive == false`); ta thay bằng stub
        // chưa-connect chỉ để mọi write lọt qua guard trở nên NHÌN THẤY được.
        live.close(promise: nil)
        let dead = EmbeddedChannel(loop: loop)
        defer { dead.close(promise: nil) }
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: dead, target: target)

        try client.writeInbound(HTTPServerRequestPart.body(ByteBuffer(repeating: 0x43, count: 512)))
        #expect(try dead.readOutbound(as: HTTPClientRequestPart.self) == nil)

        // Chunk kế VƯỢT cap buffer: nếu phần còn lại của request bị phân loại
        // lại thành "bufferable" (chỉ nil hoá upstream, không đánh dấu abort),
        // chỗ này bắn một response 502 THỨ HAI xuống một client vừa nhận đủ
        // response đầu tiên.
        try client.writeInbound(HTTPServerRequestPart.body(ByteBuffer(repeating: 0x44, count: 2048)))
        try client.writeInbound(HTTPServerRequestPart.end(nil))

        #expect(try dead.readOutbound(as: HTTPClientRequestPart.self) == nil)
        #expect(try client.readOutbound(as: HTTPServerResponsePart.self) == nil)
        #expect(recorder.startedCount == 1)
        #expect(recorder.completedCount == 1)
        #expect(recorder.failedCount == 0)
        #expect(recorder.requestBodyCount == 0)
    }

    @Test("Upstream chết khi transaction còn đang chờ: đúng MỘT .failed và đúng một 502 cho client")
    func upstreamDeathWithPendingTransactionReportsExactlyOnce() throws {
        let loop = EmbeddedEventLoop()
        defer { loop.run() }
        let config = ProxyConfiguration()
        let target = HTTPProxyHandler.Target(host: "127.0.0.1", port: 8080, scheme: .http)
        let recorder = RecordingSink()
        let (handler, client) = try makeEmbeddedProxy(
            loop: loop, recorder: recorder, configuration: config, target: target)
        defer { client.close(promise: nil) }

        let live = EmbeddedChannel(
            handler: UpstreamHandler(clientChannel: client, configuration: config,
                                     sink: { recorder.record($0) }, state: handler.state),
            loop: loop)
        defer { live.close(promise: nil) }
        live.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: live, target: target)

        try client.writeInbound(HTTPServerRequestPart.head(requestHead(contentLength: 4096)))
        try client.writeInbound(HTTPServerRequestPart.body(ByteBuffer(repeating: 0x43, count: 512)))
        guard case .started(let transaction)? = recorder.events.first else {
            Issue.record("thiếu event .started"); return
        }

        // Upstream chết khi transaction VẪN đang chờ response. Đúng một bên
        // được phép báo: `UpstreamHandler.channelInactive`.
        live.close(promise: nil)

        // `RecordingSink` thu HẾT, không dừng ở event đầu tiên — nên con số 1
        // dưới đây thật sự có thể sai được nếu có bên thứ hai cùng báo.
        #expect(recorder.failedCount == 1)
        guard case .failed(let failedID, _, _)? = recorder.events.last else {
            Issue.record("thiếu event .failed"); return
        }
        #expect(failedID == transaction.id)

        guard case .head(let response)? = try client.readOutbound(as: HTTPServerResponsePart.self) else {
            Issue.record("client phải nhận được 502"); return
        }
        #expect(response.status == .badGateway)
    }

    /// Request head KHÔNG phân giải được target (origin-form gửi tới cổng
    /// plaintext của proxy) bị trả 400 — nhưng phần `.body`/`.end` của chính
    /// nó vẫn đi tiếp trong cùng lượt đọc. Nếu head hỏng không đánh dấu
    /// "request này đã bỏ dở", phần body đó tìm thấy `upstream` còn sót lại từ
    /// một request TRƯỚC trên cùng kết nối keep-alive và được ghi thẳng vào
    /// đó: một body không có head, tiêm vào một cuộc hội thoại đang sống với
    /// origin thật.
    @Test("Request head sai định dạng: body của nó không được tiêm vào upstream của request TRƯỚC")
    func malformedHeadDoesNotInjectBodyIntoPreviousUpstream() throws {
        let loop = EmbeddedEventLoop()
        defer { loop.run() }
        let recorder = RecordingSink()
        // `fixedTarget: nil` = đường plaintext, request BUỘC phải ở
        // absolute-form; một URI origin-form tới đây là ca "không phân giải
        // được target".
        let handler = HTTPProxyHandler(configuration: ProxyConfiguration(),
                                       sink: { recorder.record($0) }, fixedTarget: nil)
        let client = EmbeddedChannel(handler: handler, loop: loop)
        let stall = StallingWriteHandler()
        try client.pipeline.syncOperations.addHandler(stall, position: .first)
        client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        defer { stall.completeAll(); client.close(promise: nil) }

        // Kết nối keep-alive đã có sẵn upstream của một request TRƯỚC đó.
        let target = HTTPProxyHandler.Target(host: "127.0.0.1", port: 8080, scheme: .http)
        let previousUpstream = EmbeddedChannel(loop: loop)
        defer { previousUpstream.close(promise: nil) }
        previousUpstream.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
                                 promise: nil)
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: previousUpstream,
                                                              target: target)

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:8080")
        headers.add(name: "Content-Length", value: "5")
        try client.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(
            version: .http1_1, method: .POST, uri: "/khong-phai-absolute-form",
            headers: headers)))

        guard case .head(let response)? = try client.readOutbound(as: HTTPServerResponsePart.self)
        else {
            Issue.record("proxy phải trả 400 cho request không ở absolute-form"); return
        }
        #expect(response.status == .badRequest)

        try client.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "hello")))
        try client.writeInbound(HTTPServerRequestPart.end(nil))

        #expect(try previousUpstream.readOutbound(as: HTTPClientRequestPart.self) == nil,
                "body của một request không có head không được ghi vào upstream của request trước")
        #expect(recorder.startedCount == 0, "request hỏng không mở transaction nào")
    }

    /// Bản GHI và bản CHUYỂN TIẾP của cùng một response head phải KHÁC nhau,
    /// và khác đúng ở một chỗ: hop-by-hop chỉ được gỡ khỏi bản chuyển tiếp.
    ///
    /// Cả hai vế đều là lỗi thật nếu làm sai. Không gỡ khi forward thì
    /// `Proxy-Authenticate` của origin hiện ra với client như thể CHÍNH PROXY
    /// đang đòi xác thực. Gỡ luôn ở bản ghi thì công cụ hiện một response khác
    /// với thứ origin đã gửi — đúng lớp lỗi cả module này tồn tại để chặn.
    @Test("Response head: hop-by-hop bị gỡ khỏi bản CHUYỂN TIẾP, còn nguyên trong bản GHI")
    func responseHopByHopStrippedOnForwardedCopyOnly() throws {
        let loop = EmbeddedEventLoop()
        defer { loop.run() }
        let config = ProxyConfiguration()
        let target = HTTPProxyHandler.Target(host: "127.0.0.1", port: 8080, scheme: .http)
        let recorder = RecordingSink()
        let (handler, client) = try makeEmbeddedProxy(
            loop: loop, recorder: recorder, configuration: config, target: target)
        defer { client.close(promise: nil) }

        let upstream = EmbeddedChannel(
            handler: UpstreamHandler(clientChannel: client, configuration: config,
                                     sink: { recorder.record($0) }, state: handler.state),
            loop: loop)
        defer { upstream.close(promise: nil) }
        upstream.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: upstream, target: target)

        try client.writeInbound(HTTPServerRequestPart.head(requestHead(contentLength: nil)))

        var originHeaders = HTTPHeaders()
        originHeaders.add(name: "Content-Length", value: "0")
        originHeaders.add(name: "X-Test", value: "1")
        originHeaders.add(name: "Connection", value: "keep-alive")
        originHeaders.add(name: "Keep-Alive", value: "timeout=5")
        originHeaders.add(name: "Proxy-Authenticate", value: "Basic realm=\"origin\"")
        try upstream.writeInbound(HTTPClientResponsePart.head(
            HTTPResponseHead(version: .http1_1, status: .ok, headers: originHeaders)))
        // `.end` chỉ để XẢ: `UpstreamHandler` ghi head với `flush: false`, mà
        // `EmbeddedChannel.readOutbound` chỉ thấy phần đã flush.
        try upstream.writeInbound(HTTPClientResponsePart.end(nil))

        guard case .head(let forwarded)? = try client.readOutbound(as: HTTPServerResponsePart.self)
        else {
            Issue.record("client phải nhận được response head"); return
        }
        #expect(forwarded.headers.first(name: "Proxy-Authenticate") == nil)
        #expect(forwarded.headers.first(name: "Connection") == nil)
        #expect(forwarded.headers.first(name: "Keep-Alive") == nil)
        #expect(forwarded.headers.first(name: "X-Test") == "1",
                "header end-to-end phải qua nguyên vẹn")

        let recordedHeads = recorder.events.compactMap { event -> ResponseModel? in
            if case .responseHead(_, let model) = event { return model }
            return nil
        }
        let recorded = try #require(recordedHeads.first,
                                    "thiếu event .responseHead, events: \(recorder.events)")
        #expect(recorded.headers.contains { $0.name.lowercased() == "proxy-authenticate" },
                "bản GHI phải giữ header gốc của origin — đó chính là thứ người dùng đang soi")
        #expect(recorded.headers.contains { $0.name.lowercased() == "connection" })
        #expect(recorded.headers.contains { $0.name.lowercased() == "x-test" })
    }

    /// Gương của test trên, ở chiều request.
    ///
    /// `rewriteAcceptEncoding` tồn tại vì hệ thống không giải nén được brotli,
    /// nhưng nó THAY ĐỔI request đi trên dây. Nếu nó cũng sửa luôn bản ghi thì
    /// công cụ sẽ khai rằng client gửi `gzip, deflate` trong khi client thật sự
    /// gửi `gzip, deflate, br, zstd` — tức là nói dối về chính thứ người dùng
    /// mở nó ra để xem.
    @Test("Accept-Encoding bị viết lại ở bản CHUYỂN TIẾP, còn nguyên trong bản GHI")
    func acceptEncodingRewrittenOnForwardedCopyOnly() throws {
        let loop = EmbeddedEventLoop()
        defer { loop.run() }
        var config = ProxyConfiguration()
        config.rewriteAcceptEncoding = true
        let target = HTTPProxyHandler.Target(host: "127.0.0.1", port: 8080, scheme: .http)
        let recorder = RecordingSink()
        let (handler, client) = try makeEmbeddedProxy(
            loop: loop, recorder: recorder, configuration: config, target: target)
        defer { client.close(promise: nil) }

        let upstream = EmbeddedChannel(loop: loop)
        defer { upstream.close(promise: nil) }
        upstream.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        try upstream.pipeline.syncOperations.addHTTPClientHandlers()
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: upstream, target: target)

        let clientSent = "gzip, deflate, br, zstd"
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:8080")
        headers.add(name: "Accept-Encoding", value: clientSent)
        try client.writeInbound(HTTPServerRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .GET, uri: "/x", headers: headers)))
        upstream.flush()

        let wire = try upstream.readOutbound(as: ByteBuffer.self).map {
            String(buffer: $0)
        } ?? ""
        #expect(wire.lowercased().contains("accept-encoding: gzip, deflate"),
                "bản chuyển tiếp phải bị viết lại, wire: \(wire)")
        #expect(!wire.lowercased().contains("br, zstd"),
                "brotli/zstd phải biến mất khỏi bản chuyển tiếp")

        let started = recorder.events.compactMap { event -> Transaction? in
            if case .started(let transaction) = event { return transaction }
            return nil
        }
        let recorded = try #require(started.first, "thiếu event .started")
        #expect(recorded.request.headers.contains {
            $0.name.lowercased() == "accept-encoding" && $0.value == clientSent
        }, "bản GHI phải giữ đúng Accept-Encoding client gửi, không phải bản đã viết lại")
    }

    @Test("Tắt cờ thì Accept-Encoding đi qua nguyên vẹn")
    func acceptEncodingUntouchedWhenFlagOff() throws {
        let loop = EmbeddedEventLoop()
        defer { loop.run() }
        let config = ProxyConfiguration()   // mặc định: không viết lại
        let target = HTTPProxyHandler.Target(host: "127.0.0.1", port: 8080, scheme: .http)
        let (handler, client) = try makeEmbeddedProxy(
            loop: loop, recorder: RecordingSink(), configuration: config, target: target)
        defer { client.close(promise: nil) }

        let upstream = EmbeddedChannel(loop: loop)
        defer { upstream.close(promise: nil) }
        upstream.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: nil)
        try upstream.pipeline.syncOperations.addHTTPClientHandlers()
        handler.upstream = HTTPProxyHandler.UpstreamConnection(channel: upstream, target: target)

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:8080")
        headers.add(name: "Accept-Encoding", value: "gzip, deflate, br, zstd")
        try client.writeInbound(HTTPServerRequestPart.head(
            HTTPRequestHead(version: .http1_1, method: .GET, uri: "/x", headers: headers)))
        upstream.flush()

        let wire = try upstream.readOutbound(as: ByteBuffer.self).map { String(buffer: $0) } ?? ""
        #expect(wire.lowercased().contains("br, zstd"),
                "mặc định KHÔNG được đụng vào request của client, wire: \(wire)")
    }
}
