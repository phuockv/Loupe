import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOHTTP1
import NIOSSL
import CertKit
import TrafficModel
@testable import ProxyCore

/// Dựng một origin HTTPS thật (TLS + HTTP/1.1 + echo) trên 127.0.0.1:0, ký bằng
/// `authority`. Trả về channel để test tự đóng.
///
/// Dùng chung giữa `MITMProxyTests` và `ProxyErrorHandlingTests`: hai suite cần
/// đúng cùng một thứ, khác nhau chỉ ở CA nào ký cho origin.
func startTLSOriginServer(
    group: EventLoopGroup, authority: CertificateAuthority, host: String
) async throws -> Channel {
    let identity = try await LeafCertificateCache(authority: authority).identity(forHost: host)
    var tls = TLSConfiguration.makeServerConfiguration(
        certificateChain: identity.certificateChain.map { .certificate($0) },
        privateKey: .privateKey(identity.privateKey)
    )
    tls.applicationProtocols = ["http/1.1"]
    let context = try NIOSSLContext(configuration: tls)
    return try await ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(NIOSSLServerHandler(context: context))
                .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                .flatMap { channel.pipeline.addHandler(EchoServerHandler()) }
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
}

/// Chạy `/usr/bin/curl` và trả về (stdout, exit code).
///
/// `-m` là lưới an toàn chống TREO cả bộ test, KHÔNG phải cách đồng bộ hoá:
/// mọi khẳng định dưới đây chờ tín hiệu quan sát được (curl kết thúc, event
/// tới), không chờ đồng hồ.
func runCurl(_ arguments: [String]) throws -> (output: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = arguments + ["-m", "20"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
}

/// Đợi `task` tối đa `seconds` giây rồi huỷ và trả `nil`. Không có nó, một hồi
/// quy khiến event mong đợi không bao giờ tới sẽ làm cả bộ test TREO thay vì đỏ.
func awaitEventsWithTimeout<T: Sendable>(
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

@Suite("MitM HTTPS")
struct MITMProxyTests {

    @Test("Request HTTPS đi xuyên proxy, được giải mã và ghi lại")
    func decryptsAndRecordsHTTPSTraffic() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer { Task { try? await group.shutdownGracefully() } }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MITMTests-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        let cache = try LeafCertificateCache(authority: authority)

        // Origin HTTPS dùng leaf "localhost" ký bởi CHÍNH CA này, nên proxy
        // verify được sau khi ta thêm CA vào additionalTrustRoots.
        let origin = try await startTLSOriginServer(
            group: group, authority: authority, host: "localhost"
        )
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        let caCert = try NIOSSLCertificate(bytes: authority.certificateDER(), format: .der)
        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []
        config.additionalTrustRoots = [caCert]

        let server = ProxyServer(configuration: config, leafCache: cache)
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let collected = Task {
            var events: [TrafficEvent] = []
            for await event in server.events {
                events.append(event)
                if case .completed = event { break }
                if case .failed = event { break }
            }
            return events
        }

        // curl tin CA của ta nên chấp nhận leaf do proxy mint ra.
        let caPath = dir.appendingPathComponent("ca.pem").path
        let curl = try runCurl([
            "-sS", "--cacert", caPath,
            "-x", "http://127.0.0.1:\(proxyPort)",
            "https://localhost:\(originPort)/secret?token=abc",
        ])
        #expect(curl.status == 0, "curl thất bại")
        #expect(curl.output == "xin chao tu upstream")

        guard let events = await awaitEventsWithTimeout(collected, seconds: 10) else {
            Issue.record("hết giờ chờ event kết thúc từ proxy"); return
        }
        let started = events.compactMap { event -> Transaction? in
            if case .started(let transaction) = event, transaction.request.method == "GET" {
                return transaction
            }
            return nil
        }
        let request = try #require(started.first, "không thấy request GET đã giải mã")
        #expect(request.scheme == .https)
        #expect(request.host == "localhost")
        #expect(request.port == originPort)
        #expect(request.request.url.path == "/secret")
        #expect(request.request.queryItems.first?.value == "abc")

        guard case .completed(let id, let response, _)? = events.last else {
            Issue.record("thiếu .completed, events: \(events)"); return
        }
        #expect(id == request.id)
        #expect(response.statusCode == 200)
    }

    /// Byte gửi CHUNG MỘT GÓI với dòng CONNECT đã nằm trong buffer của
    /// `HTTPRequestDecoder` lúc decoder bị gỡ. Chúng chỉ tới được tầng TLS nhờ
    /// hai thứ ghép lại: `leftOverBytesStrategy: .forwardBytes` (Task 7) và
    /// việc `MITMUpgradeHandler` ĐỆM chúng trong lúc chờ mint leaf rồi PHÁT LẠI
    /// từ đầu pipeline sau khi lắp `NIOSSLServerHandler`. Thiếu bất kỳ mảnh nào
    /// thì với HTTPS thật đó chính là ClientHello bị đánh rơi, và triệu chứng
    /// là bắt tay TREO tới khi client timeout chứ không phải một lỗi rõ ràng.
    ///
    /// Với curl thì đường này KHÔNG chạy (curl chờ "200 Connection Established"
    /// rồi mới gửi ClientHello), nên nó cần một bài riêng dựng socket thô.
    /// Payload không phải TLS thật: thứ cần chứng minh là byte ĐẾN ĐƯỢC
    /// BoringSSL, và một `.failed` nêu bắt tay hỏng chỉ phát ra được từ
    /// `MITMSessionReporter` — tức là chúng đã tới nơi.
    @Test("Byte đi chung gói với CONNECT vẫn tới được tầng TLS của MitM")
    func bytesArrivingWithConnectReachTheTLSLayer() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MITMCoalesced-\(UUID().uuidString)")
        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []
        let server = ProxyServer(
            configuration: config,
            leafCache: try LeafCertificateCache(authority: .loadOrCreate(in: dir))
        )
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let failure = Task { () -> String? in
            for await event in server.events {
                if case .failed(_, let message, _) = event { return message }
            }
            return nil
        }

        let promise = group.next().makePromise(of: Data.self)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ResponseUntilCloseHandler(promise: promise))
            }
            .connect(host: "127.0.0.1", port: proxyPort)
            .get()
        client.eventLoop.scheduleTask(in: .seconds(10)) {
            promise.fail(ProxyErrorHandlingTests.TimedOutWaitingForProxy())
        }

        // MỘT lần ghi duy nhất: dòng CONNECT dính liền payload. Port 443 không
        // bao giờ được kết nối tới (bắt tay hỏng trước), nên không cần origin.
        let request = "CONNECT localhost:443 HTTP/1.1\r\nHost: localhost:443\r\n\r\n"
            + "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        var buffer = client.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await client.writeAndFlush(buffer)

        let received = String(decoding: try await promise.futureResult.get(), as: UTF8.self)
        #expect(received.hasPrefix("HTTP/1.1 200 Connection Established\r\n"),
                "nhận: \(received)")

        let message = try #require((await awaitEventsWithTimeout(failure, seconds: 10)) ?? nil)
        // Không khẳng định "pinning": payload ở đây là HTTP thô, client không
        // có certificate nào để từ chối. Thứ cần chứng minh là byte tới được
        // BoringSSL, và "bắt tay TLS hỏng" là dấu vết duy nhất của việc đó.
        #expect(message.contains("bắt tay TLS với client hỏng"),
                "byte đi chung gói phải tới được BoringSSL, nhận: \(message)")
    }

    /// Hình dạng PHỔ BIẾN NHẤT với một client thật: một `CONNECT`, một lần bắt
    /// tay, rồi NHIỀU request nối nhau trên cùng kết nối. Bài e2e ở trên chỉ
    /// chạy request đầu tiên, nên nó không nói gì về request thứ hai — mà đó
    /// mới là chỗ dễ hỏng: `HTTPProxyHandler` phải tái dùng đúng kết nối
    /// upstream (`fixedTarget` là hằng số nên `isUpstreamReusable` luôn khớp),
    /// và mỗi request phải ra một transaction RIÊNG.
    @Test("Nhiều request keep-alive trên cùng một tunnel MitM, mỗi cái một transaction")
    func recordsEveryRequestOnAKeepAliveConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer { Task { try? await group.shutdownGracefully() } }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MITMKeepAlive-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        let cache = try LeafCertificateCache(authority: authority)

        let origin = try await startTLSOriginServer(
            group: group, authority: authority, host: "localhost"
        )
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []
        config.additionalTrustRoots = [
            try NIOSSLCertificate(bytes: authority.certificateDER(), format: .der)
        ]
        let server = ProxyServer(configuration: config, leafCache: cache)
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let collected = Task { () -> [TrafficEvent] in
            var events: [TrafficEvent] = []
            var completed = 0
            for await event in server.events {
                events.append(event)
                if case .completed = event {
                    completed += 1
                    if completed == 2 { break }
                }
                if case .failed = event { break }
            }
            return events
        }

        // Hai URL trong MỘT lần gọi curl: curl tái dùng tunnel, chỉ gửi một
        // CONNECT và bắt tay đúng một lần.
        let curl = try runCurl([
            "-sS", "--cacert", dir.appendingPathComponent("ca.pem").path,
            "-x", "http://127.0.0.1:\(proxyPort)",
            "https://localhost:\(originPort)/one",
            "https://localhost:\(originPort)/two",
        ])
        #expect(curl.status == 0)
        #expect(curl.output == "xin chao tu upstreamxin chao tu upstream")

        guard let events = await awaitEventsWithTimeout(collected, seconds: 15) else {
            Issue.record("hết giờ chờ hai .completed"); return
        }
        let gets = events.compactMap { event -> Transaction? in
            if case .started(let transaction) = event, transaction.request.method == "GET" {
                return transaction
            }
            return nil
        }
        #expect(gets.map(\.request.url.path) == ["/one", "/two"])
        // Đúng MỘT `.started` cho CONNECT: bắt tay chỉ xảy ra một lần, tunnel
        // không bị dựng lại giữa chừng.
        let connects = events.filter { event in
            if case .started(let transaction) = event { return transaction.request.method == "CONNECT" }
            return false
        }
        #expect(connects.count == 1)

        let completedIDs = events.compactMap { event -> UUID? in
            if case .completed(let id, let response, _) = event, response.statusCode == 200 {
                return id
            }
            return nil
        }
        #expect(completedIDs == gets.map(\.id))
    }

    /// Không có bài này thì MỌI kết nối HTTPS để lại một dòng `.pending` treo
    /// vĩnh viễn: transaction CONNECT được mở ở `establishTunnel`, còn mọi chỗ
    /// phát event kết thúc cho nó trên nhánh MitM đều là đường LỖI. Các GET bên
    /// trong hoàn tất đẹp chỉ làm nó tệ hơn — người dùng thấy N dòng sạch cộng
    /// đúng một dòng kẹt cho mỗi kết nối.
    ///
    /// Response được ghi lại là response proxy THẬT SỰ đã gửi
    /// (`200 Connection Established`), không phải một giá trị tổng hợp.
    @Test("Kết nối MitM đóng sạch: transaction CONNECT được đánh .completed")
    func recordsTerminalEventWhenMITMConnectionClosesCleanly() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer { Task { try? await group.shutdownGracefully() } }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MITMTerminal-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        let cache = try LeafCertificateCache(authority: authority)

        let origin = try await startTLSOriginServer(
            group: group, authority: authority, host: "localhost"
        )
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []
        config.additionalTrustRoots = [
            try NIOSSLCertificate(bytes: authority.certificateDER(), format: .der)
        ]
        let server = ProxyServer(configuration: config, leafCache: cache)
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        // Thu tới khi CHÍNH transaction CONNECT có event kết thúc — không dừng ở
        // `.completed` đầu tiên, vì cái đó là của GET bên trong.
        let collected = Task { () -> (connect: Transaction?, terminal: TrafficEvent?) in
            var connect: Transaction?
            for await event in server.events {
                switch event {
                case .started(let transaction) where transaction.request.method == "CONNECT":
                    connect = transaction
                case .completed(let id, _, _) where id == connect?.id:
                    return (connect, event)
                case .failed(let id, _, _) where id == connect?.id:
                    return (connect, event)
                default:
                    break
                }
            }
            return (connect, nil)
        }

        let curl = try runCurl([
            "-sS", "--cacert", dir.appendingPathComponent("ca.pem").path,
            "-x", "http://127.0.0.1:\(proxyPort)",
            "https://localhost:\(originPort)/one",
        ])
        #expect(curl.status == 0)

        guard let outcome = await awaitEventsWithTimeout(collected, seconds: 15) else {
            Issue.record("hết giờ chờ event kết thúc cho transaction CONNECT"); return
        }
        let connect = try #require(outcome.connect)
        if case .pending = connect.state {} else {
            Issue.record("CONNECT ngoài bypass list phải mở ở .pending")
        }
        guard case .completed(let id, let response, _)? = outcome.terminal else {
            Issue.record("CONNECT phải kết thúc bằng .completed, nhận: \(String(describing: outcome.terminal))")
            return
        }
        #expect(id == connect.id)
        #expect(response.statusCode == 200)
        #expect(response.reasonPhrase == "Connection Established")
    }

    /// `MITMUpgradeHandler.install` lắp người báo cáo TRƯỚC ba lệnh có thể ném
    /// (cố ý: `NIOSSLHandler` bắt tay ngay trong `handlerAdded`, nên người nghe
    /// phải có mặt trước). Hệ quả: nếu một lệnh ném, `catch` báo `.failed` rồi
    /// `channel.close` — và lần đóng đó chạy `channelInactive` của chính người
    /// báo cáo. Chốt chưa đặt thì nó phát thêm một `.completed` ĐẾN SAU, che
    /// mất nguyên nhân thật.
    ///
    /// Đường tới đó gần như không xảy ra (context TLS đã dựng xong, pipeline
    /// đang sống), nên bài này ghim QUY TẮC ở mức đơn vị thay vì cố dựng lại
    /// tình huống: báo lỗi rồi đóng phải cho đúng MỘT event, và nó phải là
    /// `.failed`.
    @Test("Báo lỗi rồi đóng chỉ cho đúng một event kết thúc, và đó là .failed")
    func reportFailureLatchesAgainstLaterCleanEnd() throws {
        let recorder = RecordingSink()
        let id = UUID()
        let reporter = MITMSessionReporter(host: "example.com", transactionID: id,
                                           sink: { recorder.record($0) })

        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        try channel.pipeline.syncOperations.addHandler(reporter)

        reporter.reportFailure("không lắp được tầng TLS")
        // Chính là thứ `channel.close(promise: nil)` trong `catch` gây ra.
        channel.pipeline.fireChannelInactive()

        #expect(recorder.failedCount == 1)
        #expect(recorder.completedCount == 0,
                "một `.completed` đến sau sẽ che mất nguyên nhân thật")
    }
}
