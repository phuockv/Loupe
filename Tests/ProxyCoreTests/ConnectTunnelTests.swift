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

/// Origin: im lặng cho tới khi đã NHẬN đủ `triggerAfterBytes` byte, rồi ghi
/// nguyên `payload` và nửa-đóng (chỉ FIN chiều ra). Không dội ngược gì — dòng
/// byte về client phải là đúng `payload`, nên đếm được chính xác bao nhiêu byte
/// tới nơi.
///
/// Nửa-đóng chứ không đóng hẳn là để test TẤT ĐỊNH: nếu đóng hẳn, phần upload
/// còn trên đường của client sẽ đập vào một socket đã biến mất và origin đáp
/// RST — mà RST làm kernel VỨT phần dữ liệu proxy chưa kịp đọc, tức có những
/// lần test đỏ vì mất byte ở tầng OS, không phải vì lỗi trong proxy. Chiều vào
/// vẫn mở nên proxy vẫn thấy EOF và vẫn đi đúng đường cần kiểm.
final class BulkDownloadThenCloseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let payload: Data
    private let triggerAfterBytes: Int
    private let closed: EventLoopPromise<Void>
    private var receivedBytes = 0
    private var fired = false

    init(payload: Data, triggerAfterBytes: Int, closed: EventLoopPromise<Void>) {
        self.payload = payload
        self.triggerAfterBytes = triggerAfterBytes
        self.closed = closed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        receivedBytes += unwrapInboundIn(data).readableBytes
        guard !fired, receivedBytes >= triggerAfterBytes else { return }
        fired = true
        let channel = context.channel
        let closed = self.closed
        var out = channel.allocator.buffer(capacity: payload.count)
        out.writeBytes(payload)
        // Đóng trong completion của chính lần ghi: đóng thẳng ở đây thì origin
        // tự cắt cụt phần mình vừa gửi và test sẽ đo nhầm bên bị lỗi.
        channel.writeAndFlush(out).whenComplete { _ in
            channel.close(mode: .output).whenComplete { _ in closed.succeed(()) }
        }
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
        group: EventLoopGroup, proxyPort: Int, receiveBufferBytes: Int? = nil
    ) async throws -> (channel: Channel, collector: RawByteCollector) {
        let collector = RawByteCollector()
        var bootstrap = ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(collector) }
        if let receiveBufferBytes {
            // Buffer nhận nhỏ để phần đuôi của lần tải chắc chắn còn nằm trong
            // `pendingWrites` phía proxy khi client ngừng đọc — không phải đoán
            // xem kernel tự nới buffer tới đâu.
            bootstrap = bootstrap.channelOption(
                .socketOption(.so_rcvbuf), value: SocketOptionValue(receiveBufferBytes))
        }
        let channel = try await bootstrap.connect(host: "127.0.0.1", port: proxyPort).get()
        return (channel, collector)
    }

    private func expect(
        _ count: Int, from collector: RawByteCollector, on channel: Channel,
        timeout: TimeAmount = .seconds(5)
    ) -> EventLoopFuture<Data> {
        channel.eventLoop.submit { collector.expect(count, on: channel.eventLoop, timeout: timeout) }
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

    /// Byte đi CHUNG một gói với CONNECT là trường hợp mà cả đoạn gỡ pipeline
    /// sinh ra để phục vụ, và là trường hợp DUY NHẤT chạy qua nhánh forwarding
    /// của `leftOverBytesStrategy: .forwardBytes`.
    ///
    /// Ba test kia đều kết thúc lần ghi đúng ở `\r\n\r\n` rồi chờ response,
    /// nên lúc decoder bị gỡ thì `readableBytes == 0` và nhánh đó không hề chạy.
    /// Với HTTPS thật thì đây không phải ca hiếm: nó chính là ClientHello đi
    /// cùng gói với CONNECT — thứ Task 8 sẽ phụ thuộc vào.
    @Test("Byte gửi chung một gói với CONNECT vẫn được relay, và relay trước byte gửi sau")
    func relaysBytesArrivingInTheSameWriteAsConnect() async throws {
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

        let (client, collector) = try await connectRawClient(group: group, proxyPort: proxyPort)

        // MỘT lần writeAndFlush duy nhất: CONNECT dính liền payload. Proxy đọc
        // cả hai trong cùng một lượt, decoder dừng parse sau CONNECT (llhttp
        // đánh dấu CONNECT là upgrade) và giữ phần đuôi lại, nên phần đuôi chỉ
        // ra khỏi decoder qua đúng nhánh `.forwardBytes` lúc nó bị gỡ.
        let inSameWrite = Data("leftover-di-cung-goi-voi-CONNECT".utf8)
        var packet = Data("""
        CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r
        Host: 127.0.0.1:\(originPort)\r
        \r

        """.utf8)
        packet.append(inSameWrite)

        let expectedResponse = Self.expectedConnectResponse
        let responseFuture = expect(expectedResponse.utf8.count, from: collector, on: client)
        try await write(packet, to: client)
        #expect(String(decoding: try await responseFuture.get(), as: UTF8.self) == expectedResponse)

        let leftoverEcho = expect(inSameWrite.count, from: collector, on: client)
        #expect(try await leftoverEcho.get() == inSameWrite)

        // Gửi tiếp sau khi tunnel đã dựng xong: phải về SAU phần leftover, tức
        // thứ tự byte qua tunnel không bị đảo bởi bước replay buffer.
        let afterHandover = Data("gui-sau-khi-tunnel-da-dung".utf8)
        let afterEcho = expect(afterHandover.count, from: collector, on: client)
        try await write(afterHandover, to: client)
        #expect(try await afterEcho.get() == afterHandover)

        try await client.close()
    }

    /// Client chậm đọc mà VẪN CÒN GỬI, đúng lúc origin tải xong rồi đóng.
    ///
    /// Đây là lỗ hổng của chính cơ chế graceful close: `TunnelRelayHandler`
    /// thấy upstream chết và XẾP HÀNG một close có drain cho phía client, nhưng
    /// `ConnectTunnelHandler` không được ai báo — nó chỉ phát hiện khi client
    /// gửi thêm byte và `upstream.write` trả `false`. Nếu lúc đó nó đóng THẲNG
    /// channel client, `cancelWritesOnClose` vứt đúng cái đuôi vừa được xếp
    /// hàng. Im lặng, trên đường THÀNH CÔNG.
    ///
    /// Bốn test kia không chạm tới được: cả bốn đều để client đọc liên tục, nên
    /// `pendingWrites` phía client không bao giờ có gì để mất.
    ///
    /// Cửa sổ ở đây tới bằng NHÂN QUẢ chứ không bằng canh giờ: client bơm LIÊN
    /// TỤC suốt cả bài test (mỗi lần ghi tự nhịp theo socket, không có sleep
    /// nào), nên chắc chắn có byte client tới proxy SAU khi proxy xử lý xong
    /// EOF của upstream — đó chính là byte làm `upstream.write` trả `false`.
    /// Bơm một lượng cố định rồi dừng thì không đủ: đo thử thấy có lần cả
    /// lượng bơm đó tới nơi trước EOF và nhánh cần kiểm không hề chạy.
    @Test("Origin đóng sau khi tải xong trong lúc client chậm đọc mà còn gửi: không mất byte nào")
    func doesNotTruncateDownloadWhenClientStillWritingAsOriginCloses() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer { Task { try? await group.shutdownGracefully() } }

        let download = Data((0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let uploadChunk = Data(repeating: 0x5A, count: 64 * 1024)

        let originClosed = group.next().makePromise(of: Void.self)
        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(BulkDownloadThenCloseHandler(
                    payload: download,
                    triggerAfterBytes: uploadChunk.count,
                    closed: originClosed
                ))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { origin.close(promise: nil) }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = ["127.0.0.1"]

        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let (client, collector) = try await connectRawClient(
            group: group, proxyPort: proxyPort, receiveBufferBytes: 16 * 1024)

        let expectedResponse = Self.expectedConnectResponse
        let responseFuture = expect(expectedResponse.utf8.count, from: collector, on: client)
        try await write(Data("""
        CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r
        Host: 127.0.0.1:\(originPort)\r
        \r

        """.utf8), to: client)
        #expect(String(decoding: try await responseFuture.get(), as: UTF8.self) == expectedResponse)

        // Client ngừng đọc: từ đây mọi byte proxy gửi về đọng lại ở
        // `pendingWrites` phía proxy.
        try await client.setOption(.autoRead, value: false).get()

        // Bơm liên tục cho tới khi channel đóng. Không sleep: mỗi `await` chỉ
        // trả về khi lần ghi trước đã ra socket, nên vòng lặp tự nhịp.
        let uploader = Task {
            while !Task.isCancelled {
                var buffer = client.allocator.buffer(capacity: uploadChunk.count)
                buffer.writeBytes(uploadChunk)
                do { try await client.writeAndFlush(buffer) } catch { return }
            }
        }
        defer { uploader.cancel() }

        try await originClosed.futureResult.get()

        // Giờ mới đọc. Nếu phía client bị đóng thẳng, phần lớn 8 MiB đã bị
        // `cancelWritesOnClose` vứt và chờ ở đây sẽ hỏng.
        let downloadFuture = expect(download.count, from: collector, on: client,
                                    timeout: .seconds(30))
        try await client.setOption(.autoRead, value: true).get()
        client.read()

        let received = try await downloadFuture.get()
        #expect(received.count == download.count,
                "nhận \(received.count)/\(download.count) byte")
        #expect(received == download, "nội dung tải về không khớp nguyên văn")
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
