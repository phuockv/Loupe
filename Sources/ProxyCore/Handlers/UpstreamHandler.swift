import Foundation
import NIOCore
import NIOHTTP1
import TrafficModel

/// Nhận response từ origin, chuyển tiếp về client, và ghi lại transaction.
final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let configuration: ProxyConfiguration
    private let sink: TrafficEventSink
    private let state: SessionState

    private var head: HTTPResponseHead?
    private var collector: BodyCollector?

    init(clientChannel: Channel, configuration: ProxyConfiguration,
         sink: @escaping TrafficEventSink, state: SessionState) {
        self.clientChannel = clientChannel
        self.configuration = configuration
        self.sink = sink
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.collector = BodyCollector(
                limit: configuration.maxInMemoryBodyBytes,
                spillDirectory: configuration.bodySpillDirectory
            )
            if let id = state.pendingIDs.first {
                sink(.responseHead(id: id, Self.model(from: head, body: .none)))
            }
            clientChannel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)

        case .body(let buffer):
            collector?.append(Data(buffer.readableBytesView))
            clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)

        case .end(let trailers):
            clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(trailers)), promise: nil)
            finish()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(reason: "lỗi upstream: \(error)")
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Upstream đóng giữa chừng: mọi transaction còn chờ đều hỏng.
        while let pending = state.dequeue() {
            sink(.failed(id: pending.id, message: "upstream đóng kết nối giữa chừng",
                         endedAt: Date()))
        }
        context.fireChannelInactive()
    }

    private func finish() {
        guard let head, let transaction = state.dequeue() else { return }
        let body = collector?.finish() ?? .none
        self.head = nil
        self.collector = nil
        sink(.completed(id: transaction.id, Self.model(from: head, body: body), endedAt: Date()))
    }

    private func fail(reason: String) {
        while let pending = state.dequeue() {
            sink(.failed(id: pending.id, message: reason, endedAt: Date()))
        }
    }

    private static func model(from head: HTTPResponseHead, body: BodyPayload) -> ResponseModel {
        ResponseModel(
            statusCode: Int(head.status.code),
            reasonPhrase: head.status.reasonPhrase,
            headers: head.headers.map { (name: $0.name, value: $0.value) },
            body: body
        )
    }
}
