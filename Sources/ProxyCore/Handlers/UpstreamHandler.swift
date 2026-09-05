import Foundation
import NIOCore
import NIOHTTP1
import TrafficModel

/// Nhận response từ origin, chuyển tiếp về client, và ghi lại transaction.
final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

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
        failAllPending(reason: "lỗi upstream: \(error)")
        context.close(promise: nil)
    }

    /// Upstream đóng giữa chừng — origin crash, RST, idle timeout, hay bất
    /// cứ khi nào NIO tự phát hiện channel này chết, kể cả ngay giữa lúc
    /// `HTTPProxyHandler` còn đang forward request body/end tới nó.
    ///
    /// Đây là nơi DUY NHẤT phát `.failed` cho các trường hợp này (không phải
    /// `HTTPProxyHandler.forwardOrBuffer`, dù đó là nơi phát hiện ra channel
    /// đã chết khi cố ghi vào nó): `isActive` chuyển `false` và
    /// `channelInactive` được bắn CÙNG một lệnh gọi đồng bộ `close0` của NIO
    /// (đọc source NIOPosix/BaseSocketChannel xác nhận: `lifecycleManager`
    /// chuyển trạng thái trước, rồi mới gọi callouts — tức fireChannelInactive
    /// — tất cả không nhường control cho việc khác xen giữa). Nên bất cứ khi
    /// nào `forwardOrBuffer` nhìn thấy `upstream.isActive == false`, hàm này
    /// chắc chắn đã chạy xong — nó không cần (và không được) phát `.failed`
    /// hay trả lời client lần nữa.
    func channelInactive(context: ChannelHandlerContext) {
        failAllPending(reason: "upstream đóng kết nối giữa chừng")
        context.fireChannelInactive()
    }

    /// Rút hết id đang chờ khỏi `state`, phát `.failed` cho từng cái, rồi —
    /// CHỈ nếu có ít nhất một cái thật sự đang chờ (`errorCaught` gọi hàm
    /// này trước khi tự đóng, nên `channelInactive` chạy sau đó luôn thấy
    /// hàng đợi đã rỗng và không lặp lại) — trả lời client đúng MỘT lần:
    /// 502 nếu chưa gửi response head nào, hoặc đóng thẳng nếu đã gửi dở
    /// (không thể rút lại một response đã bắt đầu stream).
    private func failAllPending(reason: String) {
        var hadPending = false
        while let pending = state.dequeue() {
            hadPending = true
            sink(.failed(id: pending.id, message: reason, endedAt: Date()))
        }
        guard hadPending else { return }
        if head == nil {
            respond(channel: clientChannel, status: .badGateway, message: reason)
        } else {
            clientChannel.close(promise: nil)
        }
    }

    private func finish() {
        guard let head, let transaction = state.dequeue() else { return }
        let body = collector?.finish() ?? .none
        self.head = nil
        self.collector = nil
        sink(.completed(id: transaction.id, Self.model(from: head, body: body), endedAt: Date()))
    }

    private func respond(channel: Channel, status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        channel.write(NIOAny(HTTPServerResponsePart.head(
            HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        )), promise: nil)
        var buffer = channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
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
