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

    /// Một cặp channel loopback THẬT. `near` là đầu ta bọc trong `GuardedPeer`
    /// (vai "peer của proxy"), `far` là đầu kia.
    ///
    /// Không dùng `EmbeddedChannel` cho bất cứ thứ gì liên quan tới nửa-đóng:
    /// `EmbeddedChannel.close0` bỏ qua `CloseMode` và luôn đóng HẲN, nên nó sẽ
    /// quan sát nhầm đúng thứ đang cần kiểm.
    struct LoopbackPair: Sendable {
        let near: Channel
        let far: Channel
        let listener: Channel
        let farBytes: RawByteCollector

        func closeAll() {
            near.close(promise: nil)
            far.close(promise: nil)
            listener.close(promise: nil)
        }
    }

    /// - Parameters:
    ///   - farEndReads: `false` tắt `autoRead` ở đầu kia và không ai gọi
    ///     `read()`, tức nó KHÔNG BAO GIỜ đọc — cách duy nhất làm
    ///     `bufferedWritableBytes` đứng im theo cấu tạo thay vì theo may rủi.
    ///   - farEndAllowsHalfClosure: bật thì đầu kia KHÔNG tự đóng khi nhận FIN
    ///     của ta (mặc định của NIO là đóng hẳn), nên "peer không đóng chiều của
    ///     nó" mới dựng được.
    private func makeLoopbackPair(
        on loop: EventLoop, farEndReads: Bool, farEndAllowsHalfClosure: Bool,
        farEndReceiveBufferBytes: Int? = nil, nearEndSendBufferBytes: Int? = nil
    ) async throws -> LoopbackPair {
        let farBytes = RawByteCollector()
        let accepted = loop.makePromise(of: Channel.self)
        var server = ServerBootstrap(group: loop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: farEndReads)
            .childChannelOption(.allowRemoteHalfClosure, value: farEndAllowsHalfClosure)
            .childChannelInitializer { channel in
                accepted.succeed(channel)
                return channel.pipeline.addHandler(farBytes)
            }
        if let farEndReceiveBufferBytes {
            server = server.childChannelOption(
                .socketOption(.so_rcvbuf), value: SocketOptionValue(farEndReceiveBufferBytes))
        }
        let listener = try await server.bind(host: "127.0.0.1", port: 0).get()

        var client = ClientBootstrap(group: loop)
        if let nearEndSendBufferBytes {
            client = client.channelOption(
                .socketOption(.so_sndbuf), value: SocketOptionValue(nearEndSendBufferBytes))
        }
        let near = try await client.connect(
            host: "127.0.0.1", port: listener.localAddress!.port!).get()
        return LoopbackPair(near: near, far: try await accepted.futureResult.get(),
                            listener: listener, farBytes: farBytes)
    }

    /// Chờ `channel` đóng HẲN, tối đa `timeout`; trả `false` nếu hết giờ. Có hạn
    /// tường minh để một hồi quy làm channel treo thì test ĐỎ chứ không treo
    /// theo. `succeed` lần thứ hai là no-op (`_setValue` chỉ nhận giá trị đầu).
    private func closes(_ channel: Channel, within timeout: TimeAmount) async throws -> Bool {
        let verdict = channel.eventLoop.makePromise(of: Bool.self)
        channel.closeFuture.whenComplete { _ in verdict.succeed(true) }
        channel.eventLoop.scheduleTask(in: timeout) { verdict.succeed(false) }
        return try await verdict.futureResult.get()
    }

    /// `isActive` KHÔNG bắt được một channel đã nửa-đóng chiều ra:
    /// `close0(mode: .output)` không đụng tới `lifecycleManager`, nên channel vẫn
    /// `isActive == true`, trong khi `BaseStreamSocketChannel.bufferPendingWrite`
    /// đã bắt đầu bằng `if outputShutdown { promise?.fail(...); return }`. Với
    /// `promise: nil` thì đó là một byte biến mất im lặng và một `write` trả
    /// `true` — đúng lớp bug `GuardedPeer` sinh ra để chặn, vào bằng cửa
    /// `close()` mà doc comment của chính file đó cảnh báo.
    ///
    /// Hai `GuardedPeer` RIÊNG BIỆT cùng bọc một channel là hình dạng THẬT trong
    /// production (`ConnectTunnelHandler.client` và `TunnelRelayHandler.client`),
    /// và là lý do cờ không thể là field của struct: bản sao nào đóng thì chỉ
    /// bản sao đó biết.
    @Test("Nửa-đóng chiều ra: mọi GuardedPeer bọc channel đó đều từ chối ghi, kể cả bản sao khác")
    func writesAreRefusedAfterOutputHalfClose() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        // (1) Nửa-đóng ĐI QUA `GuardedPeer`, còn lần ghi đi qua một giá trị
        //     struct KHÁC bọc cùng channel.
        let byGuard = try await makeLoopbackPair(
            on: loop, farEndReads: true, farEndAllowsHalfClosure: true)
        defer { byGuard.closeAll() }

        let afterGuardedClose = try await loop.submit { () -> (refused: Bool, active: Bool) in
            let closer = GuardedPeer<ByteBuffer>(channel: byGuard.near)
            let writer = GuardedPeer<ByteBuffer>(channel: byGuard.near)
            closer.closeAfterPendingWrites(
                stallTimeout: .seconds(30), lingerTimeout: .seconds(30),
                onDrainAbandoned: { _ in Issue.record("không có gì để xả, không được bỏ cuộc") })
            var payload = byGuard.near.allocator.buffer(capacity: 8)
            payload.writeString("sau-FIN")
            return (writer.write(payload, flush: true), byGuard.near.isActive)
        }.get()
        #expect(afterGuardedClose.refused == false,
                "write phải trả false, không được nuốt byte rồi báo là đã gửi")
        #expect(afterGuardedClose.active,
                "channel vẫn isActive — đây chính là chỗ phép kiểm chỉ-isActive nói 'ghi được'")

        // (2) Nửa-đóng KHÔNG qua `GuardedPeer`. Task 8 lắp `NIOSSLHandler`, và
        //     nó tự biến `close(mode: .output)` thành close_notify; chỉ
        //     `ChannelEvent.outputClosed` báo được đường này.
        let byChannel = try await makeLoopbackPair(
            on: loop, farEndReads: true, farEndAllowsHalfClosure: true)
        defer { byChannel.closeAll() }

        let afterChannelClose = try await loop.submit { () -> (refused: Bool, active: Bool) in
            let peer = GuardedPeer<ByteBuffer>(channel: byChannel.near)
            // Hàng đợi ghi rỗng nên `pendingWrites.closeOutbound` trả
            // `.readyForClose` ngay: `shutdown(how: .WR)` VÀ `outputClosed` chạy
            // đồng bộ trong đúng lệnh này, không có lượt loop nào xen giữa.
            byChannel.near.close(mode: .output, promise: nil)
            var payload = byChannel.near.allocator.buffer(capacity: 8)
            payload.writeString("sau-FIN")
            return (peer.write(payload, flush: true), byChannel.near.isActive)
        }.get()
        #expect(afterChannelClose.refused == false)
        #expect(afterChannelClose.active)
    }

    /// Watchdog xả: peer đứng im trọn một chu kỳ thì bị cắt — VÀ việc cắt phải
    /// để lại một `.failed`.
    ///
    /// Trước vòng này KHÔNG một dòng nào trong thân watchdog được test nào chạy
    /// qua: mọi test đều xong dưới ~1 s, tức nằm gọn trong hạn 15 s mặc định.
    /// Nếu `getOption(.bufferedWritableBytes)` trả nil ở mọi tick thì `guard let`
    /// đầu thân hàm rút watchdog và trần chống treo biến mất — mà 59/59 vẫn
    /// xanh. Test này ghim cả hai nửa: watchdog CÓ chạy, và khi nó cắt thì nó
    /// nói ra.
    ///
    /// TẤT ĐỊNH chứ không canh giờ: đầu kia KHÔNG BAO GIỜ đọc, nên khi buffer
    /// nhận của nó và send buffer của ta đã đầy thì `bufferedWritableBytes` đứng
    /// nguyên theo CẤU TẠO. Không có cuộc đua nào để thua.
    @Test("Peer đứng im khi đang xả: watchdog cắt và phát .failed, không cắt cụt im lặng")
    func stalledDrainIsCutAndReported() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        let pair = try await makeLoopbackPair(
            on: loop, farEndReads: false, farEndAllowsHalfClosure: true,
            farEndReceiveBufferBytes: 16 * 1024, nearEndSendBufferBytes: 64 * 1024)
        defer { pair.closeAll() }

        let recorder = RecordingSink()
        let transactionID = UUID()
        // Nhiều hơn hẳn tổng hai buffer socket, nên phần tồn không bao giờ về 0.
        let stuck = Data(repeating: 0x6B, count: 4 * 1024 * 1024)

        try await loop.submit {
            let reporter = TunnelReporter(transactionID: transactionID,
                                          sink: { recorder.record($0) })
            let peer = GuardedPeer<ByteBuffer>(channel: pair.near)
            var buffer = pair.near.allocator.buffer(capacity: stuck.count)
            buffer.writeBytes(stuck)
            #expect(peer.write(buffer, flush: true), "channel còn sống, lần ghi này phải được nhận")
            peer.closeAfterPendingWrites(
                stallTimeout: .milliseconds(50), lingerTimeout: .seconds(30),
                onDrainAbandoned: { discarded in
                    reporter.reportFailure("bỏ cuộc khi đang xả, vứt \(discarded) byte")
                })
        }.get()

        // Hạn nán để 30 s và peer không bao giờ đóng chiều của nó, nên đường
        // DUY NHẤT đóng được channel này là watchdog xả.
        #expect(try await closes(pair.near, within: .seconds(5)),
                "watchdog xả phải cắt một peer đứng im")

        let failures = try await loop.submit { () -> [(UUID, String)] in
            recorder.events.compactMap {
                if case .failed(let id, let message, _) = $0 { return (id, message) }
                return nil
            }
        }.get()
        #expect(failures.count == 1, "một lần cắt cụt phải để lại đúng một .failed")
        #expect(failures.first?.0 == transactionID)
        #expect(failures.first?.1.contains("bỏ cuộc khi đang xả") == true,
                "message: \(failures.first?.1 ?? "-")")
    }

    /// Hạn NÁN là hạn riêng, không phải phần đuôi của hạn xả: nó phải nổ ngay cả
    /// khi giai đoạn xả kết thúc hoàn hảo.
    ///
    /// Peer ở đây đọc HẾT (nên watchdog xả không có gì để cắt, và hạn xả 30 s
    /// không bao giờ tới) nhưng KHÔNG BAO GIỜ đóng chiều của nó —
    /// `allowRemoteHalfClosure` bật nên nó không tự đóng khi thấy FIN của ta.
    /// Không có hạn nán thì channel này treo vĩnh viễn, im lặng, trên đường
    /// THÀNH CÔNG.
    @Test("Peer xả hết nhưng không đóng chiều của nó: hạn nán vẫn đóng channel")
    func lingerClosesChannelAfterDrainCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        let pair = try await makeLoopbackPair(
            on: loop, farEndReads: true, farEndAllowsHalfClosure: true)
        defer { pair.closeAll() }

        let payload = Data("nan-cho-FIN-cua-peer".utf8)
        let delivered = expect(payload.count, from: pair.farBytes, on: pair.far)

        try await loop.submit {
            let peer = GuardedPeer<ByteBuffer>(channel: pair.near)
            var buffer = pair.near.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            #expect(peer.write(buffer, flush: true))
            peer.closeAfterPendingWrites(
                stallTimeout: .seconds(30), lingerTimeout: .milliseconds(50),
                onDrainAbandoned: { _ in
                    Issue.record("peer đọc hết, không được coi là đứng im")
                })
        }.get()

        #expect(try await delivered.get() == payload, "giai đoạn xả phải hoàn tất trọn vẹn")
        #expect(try await closes(pair.near, within: .seconds(5)),
                "hạn nán phải đóng channel dù hạn xả còn 30 s và peer không gửi FIN")
    }

    /// `bytesRelayedToClient` là con số DUY NHẤT mà `.failed` của một tunnel mù
    /// trích dẫn được, nên nó không được phép nói quá. Cộng dồn TRƯỚC khi ghi
    /// thì mỗi buffer bị `client.write` từ chối vẫn được tính — bản ghi khai
    /// khống đúng phần KHÔNG tới nơi, mà đó là lớp bug cả task này xoay quanh.
    @Test("Byte bị client từ chối không được tính vào con số mà .failed trích dẫn")
    func rejectedBytesAreNotCountedAsRelayed() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        let clientSide = try await makeLoopbackPair(
            on: loop, farEndReads: true, farEndAllowsHalfClosure: true)
        defer { clientSide.closeAll() }
        let upstreamSide = try await makeLoopbackPair(
            on: loop, farEndReads: true, farEndAllowsHalfClosure: true)
        defer { upstreamSide.closeAll() }

        let recorder = RecordingSink()
        let transactionID = UUID()
        let accepted = Data("byte-nay-toi-noi".utf8)
        let rejected = Data(repeating: 0x33, count: 4096)

        try await loop.submit {
            let reporter = TunnelReporter(transactionID: transactionID,
                                          sink: { recorder.record($0) })
            try upstreamSide.near.pipeline.syncOperations.addHandler(
                TunnelRelayHandler(client: GuardedPeer(channel: clientSide.near),
                                   reporter: reporter))

            // Đi qua ĐÚNG đường relay thật, không ghi thẳng vào peer.
            var first = upstreamSide.near.allocator.buffer(capacity: accepted.count)
            first.writeBytes(accepted)
            upstreamSide.near.pipeline.fireChannelRead(first)

            // Client biến mất đúng như `ConnectTunnelHandler.upstreamVanished`
            // làm: nửa-đóng CÓ XẢ. Từ đây `client.write` phải trả `false`.
            GuardedPeer<ByteBuffer>(channel: clientSide.near).closeAfterPendingWrites(
                stallTimeout: .seconds(30), lingerTimeout: .seconds(30),
                onDrainAbandoned: { _ in Issue.record("peer đọc hết, không được bỏ cuộc") })

            var second = upstreamSide.near.allocator.buffer(capacity: rejected.count)
            second.writeBytes(rejected)
            upstreamSide.near.pipeline.fireChannelRead(second)

            upstreamSide.near.pipeline.fireErrorCaught(
                IOError(errnoCode: ECONNRESET, reason: "injected"))
        }.get()

        let failures = try await loop.submit { () -> [String] in
            recorder.events.compactMap {
                if case .failed(_, let message, _) = $0 { return message }
                return nil
            }
        }.get()
        #expect(failures.count == 1)
        let inflated = accepted.count + rejected.count
        #expect(failures.first?.contains("\(accepted.count) byte") == true,
                "phải nêu \(accepted.count) byte đã chuyển được, không phải \(inflated): \(failures.first ?? "-")")
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

    /// Lỗi trên chân upstream: phần đã nhận vẫn phải tới client ĐỦ, và phải có
    /// một `.failed` ghi lại.
    ///
    /// Test này TIÊM lỗi thay vì khiêu khích ra lỗi thật, và đó là điểm mấu
    /// chốt. Ở vòng trước tôi kết luận đường này "không kiểm tất định được", vì
    /// muốn có `ECONNRESET` thật thì origin phải đóng hẳn — mà chính cái RST đó
    /// làm kernel vứt phần dữ liệu proxy chưa kịp đọc, nên test đỏ ngẫu nhiên vì
    /// lý do nằm dưới code của mình. Kết luận đó SAI ở chỗ nó chỉ đúng cho hình
    /// dạng end-to-end: `fireErrorCaught` là API công khai, còn
    /// `TunnelRelayHandler`/`GuardedPeer`/`TunnelReporter` đều dựng thẳng được
    /// từ test `@testable`. Tiêm lỗi thì không còn cuộc đua nào với kernel.
    ///
    /// Không dùng `EmbeddedChannel`: `EmbeddedChannel.close0` bỏ qua `CloseMode`
    /// và luôn đóng hẳn, nên nó sẽ quan sát nhầm đúng thứ đang cần kiểm.
    @Test("Lỗi chân upstream: byte đã xếp hàng vẫn tới client đủ, và có .failed ghi lại")
    func upstreamErrorDeliversQueuedBytesAndRecordsFailure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        // Ghim mọi thứ vào MỘT event loop, đúng như production ghim upstream vào
        // event loop của client channel.
        let loop = group.next()

        // Chân "client" của proxy: đầu kia (browser) đọc rất chậm.
        let proxySide = loop.makePromise(of: Channel.self)
        let clientFacingServer = try await ServerBootstrap(group: loop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                proxySide.succeed(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { clientFacingServer.close(promise: nil) }

        let collector = RawByteCollector()
        let browser = try await ClientBootstrap(group: loop)
            .channelOption(.autoRead, value: false)
            .channelOption(.socketOption(.so_rcvbuf), value: SocketOptionValue(16 * 1024))
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: clientFacingServer.localAddress!.port!).get()
        defer { browser.close(promise: nil) }
        let clientChannel = try await proxySide.futureResult.get()

        // Channel "upstream" thật để mang `TunnelRelayHandler` — nối tới một
        // server chỉ nhận rồi im.
        let blackHole = try await ServerBootstrap(group: loop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { blackHole.close(promise: nil) }
        let upstream = try await ClientBootstrap(group: loop)
            .connect(host: "127.0.0.1", port: blackHole.localAddress!.port!).get()

        let recorder = RecordingSink()
        let transactionID = UUID()
        try await upstream.eventLoop.submit {
            let reporter = TunnelReporter(transactionID: transactionID,
                                          sink: { recorder.record($0) })
            try upstream.pipeline.syncOperations.addHandler(
                TunnelRelayHandler(client: GuardedPeer(channel: clientChannel),
                                   reporter: reporter))
        }.get()

        // Nhồi cho `pendingWrites` phía client đầy: browser không đọc và chỉ có
        // 16 KiB buffer nhận, nên gần như trọn 8 MiB nằm lại trong hàng đợi ghi.
        //
        // Bơm vào bằng `fireChannelRead` trên chân upstream chứ không ghi thẳng
        // vào peer: như vậy byte đi qua ĐÚNG đường relay thật
        // (`TunnelRelayHandler.channelRead`), nên bộ đếm mà báo cáo lỗi trích
        // dẫn cũng là con số thật chứ không phải số 0 vô nghĩa.
        let payload = Data((0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        try await loop.submit {
            var buffer = upstream.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            upstream.pipeline.fireChannelRead(NIOAny(buffer))
        }.get()

        // TIÊM lỗi vào chân upstream. Tuần tự sau lần ghi ở trên vì cả hai đều
        // đi qua cùng một event loop và test await từng cái.
        upstream.pipeline.fireErrorCaught(IOError(errnoCode: ECONNRESET, reason: "injected"))

        // Giờ mới cho browser đọc. Nếu chân client bị đóng cứng, phần lớn 8 MiB
        // đã bị `cancelWritesOnClose` vứt và chỗ này sẽ hỏng.
        let downloadFuture = expect(payload.count, from: collector, on: browser,
                                    timeout: .seconds(30))
        try await browser.setOption(.autoRead, value: true).get()
        browser.read()

        let received = try await downloadFuture.get()
        #expect(received.count == payload.count,
                "nhận \(received.count)/\(payload.count) byte")
        #expect(received == payload, "nội dung không khớp nguyên văn")

        // ...và lỗi phải được GHI LẠI: giao đủ byte mà bản ghi hiện một tunnel
        // sạch sẽ thì công cụ vẫn đang nói dối.
        let failures = try await loop.submit { () -> [(UUID, String)] in
            recorder.events.compactMap {
                if case .failed(let id, let message, _) = $0 { return (id, message) }
                return nil
            }
        }.get()
        #expect(failures.count == 1, "đúng một .failed cho tunnel này")
        #expect(failures.first?.0 == transactionID)
        #expect(failures.first?.1.contains("\(payload.count) byte") == true,
                "message phải nêu số byte đã chuyển được: \(failures.first?.1 ?? "-")")
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
