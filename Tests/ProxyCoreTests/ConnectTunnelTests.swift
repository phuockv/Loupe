import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
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

    @Test("Host trong bypass list được relay byte thô hai chiều và ghi transaction isTunnelled")
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
        #expect(transaction.isTunnelled, "host trong bypass list phải được đánh isTunnelled")

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
        #expect(connectTransaction.isTunnelled, "CONNECT trong bypass list phải isTunnelled")
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
    /// sang `beginMITM`, nơi Task 8 lắp tầng TLS. Bài này ghim ĐẦU KIA của
    /// nhánh đó: client mở tunnel rồi gửi thứ KHÔNG PHẢI TLS, tức mô phỏng đúng
    /// một app từ chối leaf của proxy (nó bắn alert thay vì tiếp tục bắt tay).
    ///
    /// Vẫn dùng socket thô chứ không phải curl: ở đây cần khẳng định NGUYÊN VĂN
    /// từng byte của response CONNECT, và cần một thất bại bắt tay TẤT ĐỊNH —
    /// byte đầu tiên `G` (không phải `0x16` của record handshake) làm BoringSSL
    /// hỏng ngay, không phụ thuộc phiên bản TLS nào được chọn.
    ///
    /// Trước Task 8 bài này tên là `nonBypassedHostReachesMITMStubWithoutCrashing`
    /// và khẳng định stub `beginMITM` đóng kết nối. Stub đó không còn, nên
    /// khẳng định cũ đã hết nghĩa; thứ được giữ lại là bất biến thật sự của
    /// nhánh này: client luôn nhận một câu trả lời dứt khoát và proxy không sập.
    @Test("Host ngoài bypass list: nhận 200, rồi client không nói TLS thì có .failed nêu bắt tay hỏng")
    func nonBypassedHostFailsHandshakeAndReportsIt() async throws {
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
        // Tên miền chứ không phải IP trần: CONNECT tới IP trần bị chặn bằng 502
        // TRƯỚC khi tới được nhánh MitM (leaf cần SAN dNSName).
        try await write(Data("""
        CONNECT localhost:\(originPort) HTTP/1.1\r
        Host: localhost:\(originPort)\r
        \r

        """.utf8), to: client)
        let response = try await responseFuture.get()
        #expect(String(decoding: response, as: UTF8.self) == expectedResponse)

        // Không phải ClientHello: BoringSSL phía server hỏng bắt tay ngay.
        try await write(Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), to: client)

        #expect(try await closes(client, within: .seconds(5)),
                "bắt tay hỏng thì proxy phải đóng, không để client treo")

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
        let failures = collected.compactMap { event -> (UUID, String)? in
            if case .failed(let id, let message, _) = event { return (id, message) }
            return nil
        }
        #expect(failures.map(\.0) == [transaction.id])
        // Khẳng định HIỆN TƯỢNG + lối đi tiếp, KHÔNG khẳng định "pinning": bài
        // này gửi một request HTTP thô, tức client ở đây không hề có certificate
        // để mà từ chối. Chốt một chẩn đoán sai vào test là chứng nhận cho nó.
        let message = try #require(failures.first?.1)
        #expect(message.contains("bắt tay TLS với client hỏng"), "nhận: \(message)")
        #expect(message.contains("bypass list"), "nhận: \(message)")
    }

    /// Ảnh gương của bài cùng tên bên `MITMProxyTests`, cho nhánh tunnel mù.
    /// Cùng một lỗ hổng, cùng một cơ chế vá: transaction CONNECT được mở ở
    /// `establishTunnel` và trước Task 8 fix round 1 thì mọi đường phát event
    /// kết thúc cho nó đều là đường LỖI — một tunnel chạy tốt rồi đóng sạch
    /// không phát gì cả, và dòng đó kẹt vĩnh viễn.
    ///
    /// Bài này cũng ghim luôn chỗ dễ sai của bản vá: `.completed` chỉ được phát
    /// khi chân CUỐI đóng. Phát ở chân đầu thì chốt at-most-once của
    /// `TunnelReporter` sẽ nuốt mất báo cáo của một lượt xả bỏ cuộc sau đó.
    @Test("Tunnel mù đóng sạch: transaction CONNECT được đánh .completed")
    func recordsTerminalEventWhenTunnelClosesCleanly() async throws {
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
                if case .completed = event { return collected }
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
        _ = try await responseFuture.get()

        // Một vòng relay thật để tunnel chắc chắn đã chạy, rồi client đóng sạch.
        let payload = Data("xin chao".utf8)
        let echo = expect(payload.count, from: collector, on: client)
        try await write(payload, to: client)
        #expect(try await echo.get() == payload)
        try await client.close()

        let collected = try #require(await awaitWithTimeout(events, seconds: 10))
        let started = collected.compactMap { event -> Transaction? in
            if case .started(let transaction) = event { return transaction }
            return nil
        }
        let transaction = try #require(started.first)
        // ĐÂY là điều mà việc tách `.tunnelled` ra khỏi `TransactionState` mua
        // được: transaction vừa `isTunnelled` (chưa từng bị giải mã) vừa
        // `.completed` (tunnel đã chạy xong và đóng sạch). Với enum cũ thì
        // `.completed` xoá mất vế đầu.
        #expect(transaction.isTunnelled, "host trong bypass list phải isTunnelled")
        guard case .completed(let id, let response, _)? = collected.last else {
            Issue.record("tunnel đóng sạch phải phát .completed, nhận: \(collected)")
            return
        }
        #expect(id == transaction.id)
        #expect(response.statusCode == 200)
        #expect(response.reasonPhrase == "Connection Established")
    }

    /// `closeAfterPendingWrites` chặn channel TLS bằng một `precondition`, mà
    /// `precondition` thì không test được (nó làm sập tiến trình). Thứ TEST
    /// ĐƯỢC — và cũng là thứ dễ sai — là phép so kiểu bên trong nó:
    /// `NIOSSLServerHandler` là LỚP CON của `NIOSSLHandler`, nên phép kiểm chỉ
    /// hoạt động nếu `handler(type:)` so bằng dynamic cast. Nếu nó so kiểu chính
    /// xác thì `precondition` sẽ luôn đúng, hazard mở toang, và không có gì đỏ.
    ///
    /// `EmbeddedChannel` hợp lệ ở đây: bài này chỉ soi PIPELINE, không đụng tới
    /// `CloseMode` (thứ mà `EmbeddedChannel.close0` bỏ qua).
    @Test("Phép kiểm tầng TLS bắt được cả hai lớp con của NIOSSLHandler")
    func detectsTLSLayerIncludingSubclasses() async throws {
        let plain = EmbeddedChannel()
        defer { _ = try? plain.finish() }
        #expect(!channelHasTLSLayer(plain))

        // Chân upstream của MitM: `NIOSSLClientHandler`. Cấu hình mặc định —
        // KHÔNG đụng tới `certificateVerification`, kể cả trong test.
        let clientSide = EmbeddedChannel()
        defer { _ = try? clientSide.finish() }
        let clientContext = try NIOSSLContext(
            configuration: .makeClientConfiguration())
        try clientSide.pipeline.syncOperations.addHandler(
            NIOSSLClientHandler(context: clientContext, serverHostname: "example.com"))
        #expect(channelHasTLSLayer(clientSide))

        // Chân client của MitM: `NIOSSLServerHandler`. Đây mới là lớp con mà
        // hazard 1 thật sự nói tới.
        let identity = try await makeLeafCache().identity(forHost: "localhost")
        let serverContext = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: identity.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(identity.privateKey)))
        let serverSide = EmbeddedChannel()
        defer { _ = try? serverSide.finish() }
        try serverSide.pipeline.syncOperations.addHandler(
            NIOSSLServerHandler(context: serverContext))
        #expect(channelHasTLSLayer(serverSide))
    }

    /// Ghim ĐÚNG quy tắc thứ tự của `TunnelReporter`, thứ mà không bài
    /// end-to-end nào chạm tới được một cách tất định (muốn tới đó phải để một
    /// lượt xả đứng im hết hạn 15 s thật).
    ///
    /// Quy tắc: "kết thúc sạch" chỉ được phát khi chân CUỐI đóng. Phát ở chân
    /// đầu thì chốt at-most-once nuốt mất một `.failed` do watchdog xả phát ra
    /// SAU đó — tức tunnel bị cắt cụt mà bảng vẫn hiện `.completed` sạch sẽ.
    @Test("TunnelReporter: chân đầu đóng chưa kết thúc, và một lỗi tới sau vẫn được báo")
    func tunnelReporterWaitsForTheLastLegAndPrefersFailure() {
        let id = UUID()
        let events = RecordingSink()
        let reporter = TunnelReporter(transactionID: id, sink: { events.record($0) })

        reporter.legOpened()          // client
        reporter.legOpened()          // upstream
        reporter.legClosed()          // client đóng trước
        #expect(events.events.isEmpty, "chân đầu đóng chưa phải là kết thúc")

        reporter.reportFailure("lượt xả bị cắt")
        reporter.legClosed()          // upstream đóng sau
        #expect(events.failedCount == 1)
        #expect(events.completedCount == 0, "một lỗi có thật không được thay bằng .completed")
    }

    @Test("TunnelReporter: cả hai chân đóng mà chưa ai báo gì thì tunnel kết thúc sạch")
    func tunnelReporterReportsCleanEndOnce() {
        let id = UUID()
        let events = RecordingSink()
        let reporter = TunnelReporter(transactionID: id, sink: { events.record($0) })

        reporter.legOpened()
        reporter.legOpened()
        reporter.legClosed()
        reporter.legClosed()
        #expect(events.completedCount == 1)

        // Một lỗi tới SAU khi đã kết thúc sạch không được sinh event thứ hai cho
        // cùng một transaction.
        reporter.reportFailure("tới muộn")
        #expect(events.failedCount == 0)
        #expect(events.completedCount == 1)
    }

    /// Hai unit test ở trên ghim QUY TẮC của `TunnelReporter`, còn bài
    /// end-to-end ghim ĐƯỜNG DÂY. Chỗ chưa ai giữ là ĐÚNG SỐ lời gọi: xoá một
    /// `legOpened` thì `.completed` bắn ngay ở chân đầu — chính con bug tôi tự
    /// bắt được bằng tay trong lúc viết bản vá — mà cả ba bài kia vẫn xanh.
    ///
    /// Bài này lái một `TunnelRelayHandler` THẬT trên loopback (cùng khuôn với
    /// `rejectedBytesAreNotCountedAsRelayed`) với một `TunnelReporter` dựng tay,
    /// nên đếm được chính xác: hai chân mở, handler đóng ĐÚNG một chân.
    @Test("Chân upstream đóng khi chân client còn sống: chưa phải kết thúc sạch")
    func relayHandlerClosesExactlyOneLeg() async throws {
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
        let reporter = try await loop.submit { () -> TunnelReporter in
            let reporter = TunnelReporter(transactionID: UUID(),
                                          sink: { recorder.record($0) })
            reporter.legOpened()   // chân client, do ConnectTunnelHandler mở
            reporter.legOpened()   // chân upstream
            try upstreamSide.near.pipeline.syncOperations.addHandler(
                TunnelRelayHandler(client: GuardedPeer(channel: clientSide.near),
                                   reporter: reporter))
            return reporter
        }.get()

        // Chân upstream đóng hẳn; chân client vẫn sống.
        try await upstreamSide.near.close()

        let afterUpstreamClosed = try await loop.submit { recorder.completedCount }.get()
        #expect(afterUpstreamClosed == 0,
                "chân client còn sống thì chưa được coi là tunnel kết thúc sạch")

        // Chân cuối đóng: BÂY GIỜ mới sạch. Cũng chứng minh handler vừa gọi
        // `legClosed` đúng MỘT lần — hai lần thì bộ đếm đã về 0 ở trên rồi.
        try await loop.submit { reporter.legClosed() }.get()
        let afterBothClosed = try await loop.submit { recorder.completedCount }.get()
        #expect(afterBothClosed == 1)
    }

    /// Client bỏ đi TRƯỚC khi upstream connect xong. Không có bản vá thì
    /// `openLegs` về 0 (chân upstream chưa từng mở) và một tunnel chưa chở được
    /// byte nào được ghi là `.completed` — một dòng nói phiên đã chạy xong, cho
    /// một phiên chưa từng bắt đầu.
    ///
    /// Tất định theo CẤU TẠO chứ không theo tốc độ: `channelInactive` được bắn
    /// trong CÙNG một lượt event loop với `handlerAdded`, nên future của
    /// `connect` — dù thành công hay hỏng — không thể hoàn tất xen vào giữa.
    @Test("Client bỏ đi giữa lúc còn đang connect: ghi .failed, không phải .completed")
    func abandonedConnectIsRecordedAsFailure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        let clientSide = try await makeLoopbackPair(
            on: loop, farEndReads: true, farEndAllowsHalfClosure: true)
        defer { clientSide.closeAll() }

        // Một port vừa được cấp rồi trả lại: connect tới nó không thành công,
        // và nó nằm trên loopback nên không đụng mạng ngoài.
        let placeholder = try await ServerBootstrap(group: loop)
            .bind(host: "127.0.0.1", port: 0).get()
        let deadPort = placeholder.localAddress!.port!
        try await placeholder.close()

        let recorder = RecordingSink()
        try await loop.submit {
            let handler = ConnectTunnelHandler(
                host: "127.0.0.1", port: deadPort, transactionID: UUID(),
                maxBufferedBytes: 64 * 1024, sink: { recorder.record($0) })
            try clientSide.near.pipeline.syncOperations.addHandler(handler)
            clientSide.near.pipeline.fireChannelInactive()
        }.get()

        let events = try await loop.submit { recorder.events }.get()
        #expect(recorder.completedCount == 0,
                "tunnel chưa từng thông không được ghi .completed: \(events)")
        let failures = events.compactMap { event -> String? in
            if case .failed(_, let message, _) = event { return message }
            return nil
        }
        #expect(failures.count == 1)
        #expect(failures.first?.contains("trước khi tunnel") == true,
                "message phải nêu tunnel chưa sẵn sàng: \(failures.first ?? "-")")
    }

    /// Ảnh gương cho chân CLIENT: `TunnelRelayHandler` được ghim ở bài trên,
    /// còn `ConnectTunnelHandler` mở HAI chân (chân mình trong `handlerAdded`,
    /// chân upstream khi connect xong) và không đường công khai nào đếm được.
    ///
    /// Mẹo để không phải thêm accessor: sau khi cả hai chân đã mở, test tự gọi
    /// `legClosed()` đúng MỘT lần. Nếu handler mở đủ hai chân thì `openLegs`
    /// còn 1 và chưa có gì được phát; nếu ai xoá một `legOpened` thì nó về 0 và
    /// `.completed` bắn ngay — đúng con bug N3.
    @Test("ConnectTunnelHandler mở đúng hai chân: một lần đóng chưa phải kết thúc")
    func connectTunnelHandlerOpensBothLegs() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        let origin = try await startByteEchoServer(group: loop)
        defer { origin.close(promise: nil) }
        let originPort = origin.localAddress!.port!

        let clientSide = try await makeLoopbackPair(
            on: loop, farEndReads: true, farEndAllowsHalfClosure: true)
        defer { clientSide.closeAll() }

        let recorder = RecordingSink()
        let payload = Data("hai-chan".utf8)

        let handler = try await loop.submit { () -> ConnectTunnelHandler in
            let handler = ConnectTunnelHandler(
                host: "127.0.0.1", port: originPort, transactionID: UUID(),
                maxBufferedBytes: 64 * 1024, sink: { recorder.record($0) })
            try clientSide.near.pipeline.syncOperations.addHandler(handler)
            var buffer = clientSide.near.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            clientSide.near.pipeline.fireChannelRead(buffer)
            return handler
        }.get()

        // Byte dội về tới đầu kia của loopback = upstream đã connect VÀ đã được
        // nhận nuôi, tức chân thứ hai chắc chắn đã mở. Đây là mốc quan sát
        // được, không phải một khoảng chờ.
        let echoed = try await loop.submit {
            clientSide.farBytes.expect(payload.count, on: loop, timeout: .seconds(5))
        }.get().get()
        #expect(echoed == payload)

        try await loop.submit { handler.reporter.legClosed() }.get()
        let completed = try await loop.submit { recorder.completedCount }.get()
        #expect(completed == 0,
                "mới một chân đóng: handler phải đã mở đủ hai chân")
    }
}
