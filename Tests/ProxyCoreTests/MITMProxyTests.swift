import Testing
import Foundation
import NIOCore
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
    /// BoringSSL, và một `.failed` gợi ý pinning chỉ phát ra được từ
    /// `ClientTLSErrorHandler` — tức là chúng đã tới nơi.
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
        #expect(message.contains("pinning"),
                "byte đi chung gói phải tới được BoringSSL, nhận: \(message)")
    }
}
