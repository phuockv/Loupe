import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import TrafficModel
import CertKit

public typealias TrafficEventSink = @Sendable (TrafficEvent) -> Void

public enum ProxyServerError: Error, Sendable {
    case alreadyRunning
    case notRunning
}

public actor ProxyServer {
    /// Kênh một chiều engine -> UI.
    public nonisolated let events: AsyncStream<TrafficEvent>

    private nonisolated let sink: TrafficEventSink
    private let configuration: ProxyConfiguration
    private let leafCache: LeafCertificateCache
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(configuration: ProxyConfiguration, leafCache: LeafCertificateCache) {
        self.configuration = configuration
        self.leafCache = leafCache
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let (stream, continuation) = AsyncStream<TrafficEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(10_000)
        )
        self.events = stream
        self.sink = { continuation.yield($0) }
    }

    /// Trả về port thực tế đang nghe (hữu ích khi cấu hình port 0 trong test).
    @discardableResult
    public func start() async throws -> Int {
        guard channel == nil else { throw ProxyServerError.alreadyRunning }

        let configuration = self.configuration
        let leafCache = self.leafCache
        let sink = self.sink

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let encoder = HTTPResponseEncoder()
                // .forwardBytes: khi gỡ decoder lúc chuyển sang tunnel, byte
                // chưa tiêu thụ (ClientHello của TLS) phải được đẩy tiếp
                // xuống dưới thay vì bị vứt.
                let decoder = ByteToMessageHandler(
                    HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
                )
                let entry = ProxyEntryHandler(configuration: configuration,
                                              leafCache: leafCache, sink: sink)
                let proxy = HTTPProxyHandler(configuration: configuration,
                                             sink: sink, fixedTarget: nil)
                // Task 7 gỡ toàn bộ stack HTTP để bàn giao tunnel thô; proxy
                // (HTTPProxyHandler) phải có mặt ở đây cùng encoder/decoder,
                // không chỉ hai cái đó — thiếu nó Task 7 không có gì để gỡ.
                entry.httpHandlers = [encoder, decoder, proxy]
                // syncOperations thay vì addHandlers(_:) thường: entry/proxy
                // không Sendable (là ChannelHandler, chỉ ghim event loop),
                // và addHandlers(_:) thường đòi hỏi Sendable vì có thể nhảy
                // thread nội bộ. syncOperations hợp lệ vì childChannelInitializer
                // luôn chạy đúng trên event loop của channel mới.
                do {
                    try channel.pipeline.syncOperations.addHandlers([encoder, decoder, entry, proxy])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try await bootstrap
            .bind(host: configuration.listenHost, port: configuration.listenPort)
            .get()
        self.channel = channel
        return channel.localAddress?.port ?? configuration.listenPort
    }

    public func stop() async throws {
        guard let channel else { throw ProxyServerError.notRunning }
        self.channel = nil
        try await channel.close().get()
    }

    public func shutdown() async throws {
        if channel != nil { try? await stop() }
        try await group.shutdownGracefully()
    }
}
