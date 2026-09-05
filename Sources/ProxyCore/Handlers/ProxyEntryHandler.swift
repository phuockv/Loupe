import Foundation
import NIOCore
import NIOHTTP1
import CertKit

/// Nằm trước `HTTPProxyHandler`. Chỉ chặn CONNECT; mọi thứ khác cho đi tiếp.
final class ProxyEntryHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let configuration: ProxyConfiguration
    let leafCache: LeafCertificateCache
    let sink: TrafficEventSink
    /// Handler HTTP phải gỡ khi chuyển sang tunnel. Do ta tự lắp nên có tham chiếu.
    var httpHandlers: [RemovableChannelHandler] = []

    private var pendingConnect: (host: String, port: Int)?

    init(configuration: ProxyConfiguration, leafCache: LeafCertificateCache,
         sink: @escaping TrafficEventSink) {
        self.configuration = configuration
        self.leafCache = leafCache
        self.sink = sink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if case .head(let head) = part, head.method == .CONNECT {
            guard let target = HeaderSanitizer.parseConnectTarget(head.uri) else {
                respond(channel: context.channel, status: .badRequest,
                        message: "CONNECT target không hợp lệ: \(head.uri)")
                return
            }
            pendingConnect = target
            return
        }
        if pendingConnect != nil {
            if case .end = part {
                let target = pendingConnect!
                pendingConnect = nil
                establishTunnel(context: context, host: target.host, port: target.port)
            }
            return   // nuốt body rác nếu client gửi kèm CONNECT
        }
        context.fireChannelRead(data)
    }

    /// Task 7 và Task 8 thay thân hàm này.
    func establishTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        respond(channel: context.channel, status: .notImplemented,
                message: "CONNECT chưa được hỗ trợ")
    }

    func respond(channel: Channel, status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
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
