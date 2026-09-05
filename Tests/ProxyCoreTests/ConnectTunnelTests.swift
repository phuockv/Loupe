import Testing
import Foundation
import NIOCore
import NIOPosix
import CertKit
import TrafficModel
@testable import ProxyCore

/// Server TCP dội ngược mọi byte nhận được. Không nói HTTP — đúng thứ một
/// tunnel mù phải chở được.
final class ByteEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

struct TunnelWaitTimeout: Error, CustomStringConvertible {
    let waitingFor: Int
    var description: String {
        "hết giờ chờ \(waitingFor) byte tiếp theo từ proxy"
    }
}

struct TunnelPeerClosed: Error, CustomStringConvertible {
    var description: String { "proxy đóng kết nối trong lúc test còn đang chờ byte" }
}

/// Gom byte THÔ mà client nhận được từ proxy và cho test chờ đúng số byte kế
/// tiếp. Đây là thứ chứng minh tunnel thật sự relay: một test chỉ nhìn
/// `socket.isActive` và bản ghi transaction sẽ xanh y hệt nếu handler tunnel
/// nuốt sạch mọi byte.
///
/// `@unchecked Sendable` giống các handler test khác: mọi truy cập đều nằm
/// trên event loop của channel (test đăng ký chờ qua `submit`).
final class RawByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var received = Data()
    private var consumed = 0
    private var waiting: (count: Int, promise: EventLoopPromise<Data>)?

    /// Chờ `count` byte TIẾP THEO (sau những byte các lần `expect` trước đã
    /// lấy ra). Phải gọi trên event loop của channel.
    ///
    /// Có timeout tường minh: nếu tunnel không relay, test phải ĐỎ chứ không
    /// được treo vĩnh viễn.
    func expect(_ count: Int, on eventLoop: EventLoop,
                timeout: TimeAmount = .seconds(5)) -> EventLoopFuture<Data> {
        precondition(waiting == nil, "chỉ chờ một mốc tại một thời điểm")
        let promise = eventLoop.makePromise(of: Data.self)
        waiting = (count, promise)
        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            guard self.waiting != nil else { return }
            self.waiting = nil
            promise.fail(TunnelWaitTimeout(waitingFor: count))
        }
        promise.futureResult.whenComplete { _ in timeoutTask.cancel() }
        deliver()
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(Data(unwrapInboundIn(data).readableBytesView))
        deliver()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let pending = waiting {
            waiting = nil
            pending.promise.fail(TunnelPeerClosed())
        }
        context.fireChannelInactive()
    }

    private func deliver() {
        guard let pending = waiting, received.count - consumed >= pending.count else { return }
        let chunk = received.subdata(in: consumed..<(consumed + pending.count))
        consumed += pending.count
        waiting = nil
        pending.promise.succeed(chunk)
    }
}

@Suite("CONNECT tunnel mù")
struct ConnectTunnelTests {

    /// Byte chính xác mà client phải nhận cho response CONNECT. So khớp
    /// nguyên văn (không chỉ "có 200") là cách duy nhất chứng minh encoder
    /// không chèn `transfer-encoding: chunked` — một chunk marker `0\r\n\r\n`
    /// lọt vào đây là hỏng TLS ngay ở byte đầu tiên của tunnel.
    private static let expectedConnectResponse =
        "HTTP/1.1 200 Connection Established\r\nContent-Length: 0\r\n\r\n"

    private func makeLeafCache() throws -> LeafCertificateCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelTests-\(UUID().uuidString)")
        return try LeafCertificateCache(authority: .loadOrCreate(in: dir))
    }

    private func startByteEchoServer(group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(ByteEchoHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    /// Đợi `task` tối đa `seconds` giây rồi trả `nil`. Không có nó, một hồi
    /// quy khiến event mong đợi không bao giờ tới sẽ làm cả bộ test TREO thay
    /// vì đỏ.
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

    private func connectRawClient(
        group: EventLoopGroup, proxyPort: Int
    ) async throws -> (channel: Channel, collector: RawByteCollector) {
        let collector = RawByteCollector()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: proxyPort)
            .get()
        return (channel, collector)
    }

    private func expect(
        _ count: Int, from collector: RawByteCollector, on channel: Channel
    ) -> EventLoopFuture<Data> {
        channel.eventLoop.submit { collector.expect(count, on: channel.eventLoop) }
            .flatMap { $0 }
    }

    private func write(_ payload: Data, to channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        try await channel.writeAndFlush(buffer)
    }

    @Test("Host trong bypass list được relay byte thô hai chiều và ghi transaction .tunnelled")
    func relaysBytesForBypassedHost() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let origin = try await startByteEchoServer(group: group)
        defer { origin.close(promise: nil) }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        // 127.0.0.1 chứ không phải "localhost": không phụ thuộc DNS và không
        // rơi vào happy-eyeballs thử ::1 trước (origin chỉ bind IPv4).
        config.bypassedHosts = ["127.0.0.1"]

        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let started = Task { () -> Transaction? in
            for await event in server.events {
                if case .started(let transaction) = event { return transaction }
            }
            return nil
        }

        let (client, collector) = try await connectRawClient(group: group, proxyPort: proxyPort)

        let expectedResponse = Self.expectedConnectResponse
        let responseFuture = expect(expectedResponse.utf8.count, from: collector, on: client)
        try await write(Data("""
        CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r
        Host: 127.0.0.1:\(originPort)\r
        \r

        """.utf8), to: client)
        let response = try await responseFuture.get()
        #expect(String(decoding: response, as: UTF8.self) == expectedResponse)

        // Byte thô: không phải HTTP, không phải TLS — nếu proxy cố hiểu chúng
        // thì chúng sẽ không quay về nguyên vẹn.
        let payload = Data("\u{0}\u{1}xin chao tunnel \u{FF}\u{FE} \(UUID().uuidString)".utf8)
        let echoFuture = expect(payload.count, from: collector, on: client)
        try await write(payload, to: client)
        #expect(try await echoFuture.get() == payload)

        // `awaitWithTimeout` trả `Transaction??` (timeout lồng với "stream hết"); `?? nil`
        // dồn hai tầng đó lại trước khi #require.
        let transaction = try #require(await awaitWithTimeout(started, seconds: 5) ?? nil)
        #expect(transaction.request.method == "CONNECT")
        #expect(transaction.host == "127.0.0.1")
        #expect(transaction.port == originPort)
        #expect(transaction.response == nil, "tunnel mù không có response để hiện")
        if case .tunnelled = transaction.state {} else {
            Issue.record("state phải là .tunnelled, nhận: \(transaction.state)")
        }

        try await client.close()
    }

    @Test("CONNECT ngay sau một request plaintext trên cùng kết nối: tunnel vẫn relay, request dở được báo .failed")
    func tunnelRelaysAfterPipelinedPlaintextRequest() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let origin = try await startByteEchoServer(group: group)
        defer { origin.close(promise: nil) }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = ["127.0.0.1"]

        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let events = Task { () -> [TrafficEvent] in
            var collected: [TrafficEvent] = []
            for await event in server.events {
                collected.append(event)
                if case .failed = event { return collected }
            }
            return collected
        }

        let (client, collector) = try await connectRawClient(group: group, proxyPort: proxyPort)

        // GỘP trong MỘT lần ghi: proxy đọc cả hai request trong cùng một lượt,
        // nên `HTTPProxyHandler` bị gỡ khỏi pipeline ĐÚNG lúc nó vừa tạm dừng
        // đọc từ client và còn một connect upstream đang bay — trường hợp mà
        // `handlerRemoved` sinh ra để xử lý.
        let expectedResponse = Self.expectedConnectResponse
        let responseFuture = expect(expectedResponse.utf8.count, from: collector, on: client)
        try await write(Data("""
        GET http://127.0.0.1:\(originPort)/ HTTP/1.1\r
        Host: 127.0.0.1:\(originPort)\r
        \r
        CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r
        Host: 127.0.0.1:\(originPort)\r
        \r

        """.utf8), to: client)

        // Client chỉ được nhận ĐÚNG response CONNECT: không có 502 nào của
        // request plaintext bỏ dở lọt vào dòng byte đã thành tunnel.
        let response = try await responseFuture.get()
        #expect(String(decoding: response, as: UTF8.self) == expectedResponse)

        let payload = Data("tunnel van song sau request plaintext do dang".utf8)
        let echoFuture = expect(payload.count, from: collector, on: client)
        try await write(payload, to: client)
        #expect(try await echoFuture.get() == payload)

        let collected = try #require(await awaitWithTimeout(events, seconds: 5))
        let starts = collected.compactMap { event -> Transaction? in
            if case .started(let transaction) = event { return transaction }
            return nil
        }
        #expect(starts.count == 2, "một .started cho GET, một cho CONNECT")
        let connectTransaction = try #require(starts.last)
        if case .tunnelled = connectTransaction.state {} else {
            Issue.record("CONNECT phải .tunnelled, nhận: \(connectTransaction.state)")
        }
        let plaintextTransaction = try #require(starts.first)
        let failures = collected.compactMap { event -> UUID? in
            if case .failed(let id, _, _) = event { return id }
            return nil
        }
        #expect(failures == [plaintextTransaction.id],
                "request plaintext bỏ dở phải được báo .failed đúng một lần")

        try await client.close()
    }

    /// Nhánh KHÔNG bypass đi qua đúng cùng một đoạn gỡ pipeline rồi mới rẽ
    /// sang `beginMITM`. Task 8 sẽ thay thân hàm đó, nhưng tới lúc ấy thì mọi
    /// host HTTPS không nằm trong bypass list đều chạy qua đây — nên đường này
    /// ít nhất phải đóng kết nối gọn gàng thay vì làm sập proxy.
    @Test("Host ngoài bypass list: vẫn nhận 200 rồi bị đóng, báo .failed, không làm sập proxy")
    func nonBypassedHostReachesMITMStubWithoutCrashing() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let origin = try await startByteEchoServer(group: group)
        defer { origin.close(promise: nil) }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []

        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let events = Task { () -> [TrafficEvent] in
            var collected: [TrafficEvent] = []
            for await event in server.events {
                collected.append(event)
                if case .failed = event { return collected }
            }
            return collected
        }

        let (client, collector) = try await connectRawClient(group: group, proxyPort: proxyPort)

        let expectedResponse = Self.expectedConnectResponse
        let responseFuture = expect(expectedResponse.utf8.count, from: collector, on: client)
        try await write(Data("""
        CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r
        Host: 127.0.0.1:\(originPort)\r
        \r

        """.utf8), to: client)
        let response = try await responseFuture.get()
        #expect(String(decoding: response, as: UTF8.self) == expectedResponse)

        let closed = Task { (try? await client.closeFuture.get()) != nil }
        #expect(await awaitWithTimeout(closed, seconds: 5) == true,
                "stub beginMITM phải đóng kết nối, không để client treo")

        let collected = try #require(await awaitWithTimeout(events, seconds: 5))
        let starts = collected.compactMap { event -> Transaction? in
            if case .started(let transaction) = event { return transaction }
            return nil
        }
        #expect(starts.count == 1)
        let transaction = try #require(starts.first)
        if case .pending = transaction.state {} else {
            Issue.record("host ngoài bypass list phải .pending, nhận: \(transaction.state)")
        }
        let failures = collected.compactMap { event -> UUID? in
            if case .failed(let id, _, _) = event { return id }
            return nil
        }
        #expect(failures == [transaction.id])
    }
}
