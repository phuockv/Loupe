import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import TrafficModel

/// Nhận request từ client, mở upstream, forward, và mở transaction.
///
/// `fixedTarget` nil nghĩa là plaintext: request tới ở absolute-form và ta
/// tự parse host từ URI. Khác nil nghĩa là đã đi qua MitM (Task 8): request
/// ở origin-form và host lấy từ dòng CONNECT.
final class HTTPProxyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct Target: Sendable {
        var host: String
        var port: Int
        var scheme: Scheme
    }

    private let configuration: ProxyConfiguration
    private let sink: TrafficEventSink
    private let fixedTarget: Target?
    private let state = SessionState()

    private var upstream: Channel?
    private var upstreamTarget: Target?
    private var collector: BodyCollector?

    init(configuration: ProxyConfiguration, sink: @escaping TrafficEventSink,
         fixedTarget: Target?) {
        self.configuration = configuration
        self.sink = sink
        self.fixedTarget = fixedTarget
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): handle(head: head, context: context)
        case .body(let buffer):
            collector?.append(Data(buffer.readableBytesView))
            upstream?.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
        case .end(let trailers):
            finishRequestBody()
            upstream?.writeAndFlush(NIOAny(HTTPClientRequestPart.end(trailers)), promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        upstream = nil
        context.fireChannelInactive()
    }

    private func handle(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let target = resolveTarget(head: head) else {
            respond(channel: context.channel, status: .badRequest,
                    message: "proxy cần absolute-form URI, nhận được: \(head.uri)")
            return
        }
        let originForm = fixedTarget == nil
            ? (HeaderSanitizer.parseAbsoluteForm(head.uri)?.originForm ?? head.uri)
            : head.uri

        let transaction = makeTransaction(head: head, target: target, originForm: originForm)
        state.enqueue(transaction)
        sink(.started(transaction))

        collector = BodyCollector(
            limit: configuration.maxInMemoryBodyBytes,
            spillDirectory: configuration.bodySpillDirectory
        )

        var forwarded = HTTPRequestHead(
            version: .http1_1, method: head.method, uri: originForm,
            headers: HeaderSanitizer.sanitize(head.headers)
        )
        if forwarded.headers.first(name: "Host") == nil {
            forwarded.headers.add(name: "Host", value: hostHeader(for: target))
        }
        // Fixée thành `let` trước khi vào closure @Sendable bên dưới: capture
        // một `var` bị coi là tham chiếu có thể đổi đồng thời, dù thực tế nó
        // không còn bị sửa sau điểm này.
        let forwardedHead = forwarded

        // `context` (ChannelHandlerContext) không phải Sendable và không được
        // capture qua ranh giới closure @Sendable của `whenComplete`; dùng
        // `clientChannel` (Sendable) cho mọi thao tác ghi/đáp xảy ra sau khi
        // upstream connect xong. `self` được bọc trong NIOLoopBoundBox vì
        // NIO yêu cầu closure truyền cho `whenComplete` phải @Sendable —
        // an toàn ở đây vì future này luôn hoàn tất trên cùng event loop
        // (xem `connectUpstream`).
        let clientChannel = context.channel
        let loopBoundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)

        connectUpstream(to: target, context: context).whenComplete { result in
            let this = loopBoundSelf.value
            switch result {
            case .success(let channel):
                channel.writeAndFlush(NIOAny(HTTPClientRequestPart.head(forwardedHead)), promise: nil)
            case .failure(let error):
                this.sink(.failed(id: transaction.id,
                                  message: "không nối được \(target.host):\(target.port) — \(error)",
                                  endedAt: Date()))
                _ = this.state.dequeue()
                this.respond(channel: clientChannel, status: .badGateway,
                             message: "không nối được upstream: \(error)")
            }
        }
    }

    private func resolveTarget(head: HTTPRequestHead) -> Target? {
        if let fixedTarget { return fixedTarget }
        guard let parsed = HeaderSanitizer.parseAbsoluteForm(head.uri) else { return nil }
        return Target(host: parsed.host, port: parsed.port, scheme: parsed.scheme)
    }

    private func makeTransaction(head: HTTPRequestHead, target: Target,
                                 originForm: String) -> Transaction {
        let absolute = "\(target.scheme.rawValue)://\(hostHeader(for: target))\(originForm)"
        let url = URL(string: absolute) ?? URL(string: "\(target.scheme.rawValue)://\(target.host)/")!
        let request = RequestModel(
            method: head.method.rawValue,
            url: url,
            httpVersion: "HTTP/\(head.version.major).\(head.version.minor)",
            headers: head.headers.map { (name: $0.name, value: $0.value) }
        )
        return Transaction(scheme: target.scheme, host: target.host,
                           port: target.port, request: request)
    }

    private func hostHeader(for target: Target) -> String {
        let isDefaultPort = (target.scheme == .http && target.port == 80)
            || (target.scheme == .https && target.port == 443)
        return isDefaultPort ? target.host : "\(target.host):\(target.port)"
    }

    private func finishRequestBody() {
        guard let collector, let id = state.pendingIDs.first else { return }
        let body = collector.finish()
        state.transactions[id]?.request.body = body
        self.collector = nil
        sink(.requestBody(id: id, body))
    }

    private func connectUpstream(to target: Target,
                                 context: ChannelHandlerContext) -> EventLoopFuture<Channel> {
        if let upstream, let upstreamTarget,
           upstreamTarget.host == target.host, upstreamTarget.port == target.port,
           upstream.isActive {
            return context.eventLoop.makeSucceededFuture(upstream)
        }
        upstream?.close(promise: nil)

        let clientChannel = context.channel
        let configuration = self.configuration
        let sink = self.sink
        // `state` (SessionState) chủ ý không Sendable (xem chú thích trong
        // SessionState.swift), nhưng `channelInitializer` của NIO yêu cầu
        // closure @Sendable. Bọc bằng NIOLoopBoundBox: an toàn vì bootstrap
        // dùng `group: context.eventLoop` nên closure này chạy đúng trên
        // event loop mà `state` đang sống.
        let loopBoundState = NIOLoopBoundBox(state, eventLoop: context.eventLoop)

        // Ghim upstream vào ĐÚNG event loop của client channel. Đây là điều
        // kiện để SessionState không cần khoá — xem chú thích trong SessionState.
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    if target.scheme == .https {
                        var tls = TLSConfiguration.makeClientConfiguration()
                        tls.applicationProtocols = ["http/1.1"]
                        // KHÔNG BAO GIỜ tắt verify ở đây: tắt là biến app
                        // thành lỗ hổng thật cho mọi traffic đi qua nó.
                        let sslContext = try NIOSSLContext(configuration: tls)
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: sslContext, serverHostname: target.host)
                        )
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(
                        UpstreamHandler(clientChannel: clientChannel,
                                        configuration: configuration,
                                        sink: sink, state: loopBoundState.value)
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let loopBoundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)
        return bootstrap.connect(host: target.host, port: target.port)
            .map { channel in
                let this = loopBoundSelf.value
                this.upstream = channel
                this.upstreamTarget = target
                return channel
            }
    }

    private func respond(channel: Channel, status: HTTPResponseStatus,
                         message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        channel.write(wrapOutboundOut(.head(
            HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        )), promise: nil)
        var buffer = channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        channel.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        channel.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
