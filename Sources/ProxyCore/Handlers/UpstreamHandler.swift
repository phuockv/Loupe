import Foundation
import NIOCore
import NIOHTTP1
import TrafficModel

/// Nhận response từ origin, chuyển tiếp về client, và ghi lại transaction.
final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    /// Channel client bọc trong `GuardedPeer`, KHÔNG phải `Channel` trần.
    ///
    /// Chiều này (response về client) có cùng lớp bug với chiều request mà
    /// `GuardedPeer` sinh ra để chặn — ghi vào một client đã biến mất thì byte
    /// tan biến im lặng trong khi transaction vẫn ghi `.completed`. Nó còn có
    /// một chế độ hỏng nặng hơn kể từ Task 7: sau khi một `CONNECT` bàn giao
    /// channel này cho tunnel byte thô, encoder HTTP đã bị gỡ, nên một
    /// `HTTPServerResponsePart` ghi vào đây là `fatalError` ở đáy pipeline chứ
    /// không phải lỗi nhẹ. Hôm nay không đường nào tới được đó (xem
    /// `HTTPProxyHandler.handlerRemoved`), nhưng thứ giữ nó đóng chỉ là một lập
    /// luận về thứ tự — đúng kiểu lập luận đã hỏng bốn lần ở file bên cạnh.
    private let client: GuardedPeer<HTTPServerResponsePart>
    private let configuration: ProxyConfiguration
    private let sink: TrafficEventSink
    private let state: SessionState

    private var head: HTTPResponseHead?
    private var collector: BodyCollector?

    init(clientChannel: Channel, configuration: ProxyConfiguration,
         sink: @escaping TrafficEventSink, state: SessionState) {
        self.client = GuardedPeer(channel: clientChannel)
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
            // BẢN GHI giữ header GỐC của origin, chỉ BẢN CHUYỂN TIẾP mới bị gỡ
            // hop-by-hop — cùng hình dạng với chiều request
            // (`HTTPProxyHandler.makeTransaction` ghi `head.headers` trong khi
            // chỗ forward dùng `sanitize(head.headers)`). Đảo lại là công cụ
            // hiện một response KHÁC với thứ origin đã gửi, đúng lớp lỗi cả
            // module này tồn tại để chặn.
            if let id = state.pendingIDs.first {
                sink(.responseHead(id: id, Self.model(from: head, body: .none)))
            }
            // Không gỡ thì `Connection`, `Keep-Alive`, `Trailer`, `Upgrade` và
            // `Proxy-Authenticate` của origin đi thẳng tới client — cái cuối
            // hiện ra như thể CHÍNH PROXY đang đòi xác thực.
            //
            // An toàn với framing của response HTTP/1.1: `HTTPResponseEncoder`
            // (mặc định `automaticallySetFramingHeaders`) tự dựng lại
            // `Transfer-Encoding: chunked` hoặc giữ `Content-Length` theo
            // response thật trước khi ghi head ra dây, nên gỡ `Transfer-Encoding`
            // gốc ở đây không để lại response 1.1 nào mất khung.
            //
            // GIỚI HẠN đã biết, và KHÔNG phải do thay đổi này sinh ra: một
            // response HTTP/1.0 không có `Content-Length` được đóng khung bằng
            // chính việc đóng kết nối, mà encoder không dựng khung cho phiên
            // bản 1.0. Trước hay sau thay đổi này, client cũng đều chờ một EOF
            // mà proxy không gửi (proxy giữ kết nối client sống sau `.end`).
            // Ghi lại như việc cần làm tiếp, không phải một bất biến hàm này giữ.
            var forwarded = head
            forwarded.headers = HeaderSanitizer.sanitize(head.headers)
            guard client.write(.head(forwarded), flush: false) else {
                clientVanished(context: context)
                return
            }

        case .body(let buffer):
            collector?.append(Data(buffer.readableBytesView))
            guard client.write(.body(.byteBuffer(buffer)), flush: false) else {
                clientVanished(context: context)
                return
            }

        case .end(let trailers):
            guard client.write(.end(trailers), flush: true) else {
                clientVanished(context: context)
                return
            }
            finish()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAllPending(reason: "lỗi upstream: \(error)")
        context.close(promise: nil)
    }

    /// Client đã biến mất giữa lúc ta còn đang chuyển response về cho nó.
    /// Không báo cáo gì ở đây: đóng upstream làm `channelInactive` chạy ngay
    /// trong cùng lệnh gọi đồng bộ đó, và nó là nơi DUY NHẤT phát `.failed` cho
    /// các transaction còn chờ.
    private func clientVanished(context: ChannelHandlerContext) {
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
            respond(status: .badGateway, message: reason)
        } else {
            // Response đã bắt đầu stream và giờ bị cắt giữa chừng: vứt phần
            // chưa flush là ĐÚNG Ý — client phải THẤY kết nối đứt, chứ không
            // phải nhận một body cụt trông như đã xong.
            client.closeDiscardingPendingWrites()
        }
    }

    private func finish() {
        guard let head, let transaction = state.dequeue() else { return }
        let body = collector?.finish() ?? .none
        self.head = nil
        self.collector = nil
        sink(.completed(id: transaction.id, Self.model(from: head, body: body), endedAt: Date()))
    }

    private func respond(status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        // `write` chỉ trả false khi channel đã chết — lúc đó không có gì để
        // đóng và cũng chưa có nửa response nào lọt ra ngoài, chỉ dừng lại.
        guard client.write(.head(
            HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        ), flush: false) else { return }
        var buffer = client.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        guard client.write(.body(.byteBuffer(buffer)), flush: false) else { return }
        // `writeThenClose`, không phải write + close: đóng ngay sau khi ghi sẽ
        // vứt chính cái 502 vừa ghi nếu send buffer đang đầy.
        client.writeThenClose(.end(nil))
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
