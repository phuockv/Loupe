import Foundation
import NIOCore
import NIOHTTP1
import CertKit
import TrafficModel

/// Nằm trước `HTTPProxyHandler`. Chỉ chặn CONNECT; mọi thứ khác cho đi tiếp.
final class ProxyEntryHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let configuration: ProxyConfiguration
    let leafCache: LeafCertificateCache
    let sink: TrafficEventSink
    /// Handler tiêu thụ/sinh ra `HTTPServerRequestPart`/`HTTPServerResponsePart`
    /// (encoder + `HTTPProxyHandler`), phải gỡ khi chuyển sang tunnel. Do ta tự
    /// lắp nên có tham chiếu.
    ///
    /// KHÔNG chứa decoder — xem `requestDecoder`.
    var httpHandlers: [RemovableChannelHandler] = []
    /// Decoder request, tách riêng vì nó phải rời pipeline SAU CÙNG: lúc bị gỡ
    /// nó đẩy phần byte chưa tiêu thụ xuống dưới dạng `ByteBuffer`, nên bên
    /// dưới nó lúc đó phải là handler nhận byte thô chứ không phải một handler
    /// HTTP. Xem `switchToTunnel`.
    var requestDecoder: RemovableChannelHandler?

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

    func establishTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        let bypassed = configuration.isBypassed(host: host)
        // KHÔNG force unwrap: `parseConnectTarget` không kiểm bộ ký tự của
        // host, nên "CONNECT a b:443" vẫn tới được đây và `URL(string:)` trả
        // nil — force unwrap biến một dòng request rác thành crash cả proxy.
        let url = URL(string: "https://\(host):\(port)")
            ?? URL(string: "https://invalid.invalid/")!
        let transaction = Transaction(
            scheme: .https, host: host, port: port,
            request: RequestModel(method: "CONNECT", url: url),
            state: bypassed ? .tunnelled : .pending
        )
        sink(.started(transaction))

        // Content-Length: 0 để encoder không tự chèn chunked framing vào một
        // response CONNECT — chunk marker lọt vào tunnel là hỏng TLS ngay.
        // Cần thiết vì encoder ở đây KHÔNG được ghép cặp với decoder qua
        // `HTTPRequestDecoder(responseEncoder:)`, nên nó không biết request là
        // CONNECT và sẽ tự thêm `transfer-encoding: chunked` cho một 200
        // không có transport header nào.
        //
        // ĐỪNG XOÁ DÒNG NÀY CHO "ĐÚNG RFC": RFC 9110 §9.3.6 nói response 2xx
        // cho CONNECT không được mang Content-Length, nên nó trông thừa. Bỏ nó
        // ra thì encoder thay bằng `transfer-encoding: chunked` — vi phạm CÙNG
        // điều khoản đó VÀ nhét `0\r\n\r\n` vào byte đầu tiên của tunnel.
        // Cách sửa đúng là ghép cặp encoder/decoder khi dựng pipeline; tới lúc
        // đó thì mới bỏ được dòng này.
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(
            version: .http1_1,
            status: .custom(code: 200, reasonPhrase: "Connection Established"),
            headers: headers
        ))), promise: nil)

        let channel = context.channel
        let boundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { result in
            switch result {
            case .success:
                boundSelf.value.switchToTunnel(channel: channel, host: host, port: port,
                                               transaction: transaction, bypassed: bypassed)
            case .failure(let error):
                // Client ngắt trước khi nhận xong "200 Connection Established":
                // không còn tunnel nào để dựng. Vẫn phải phát event kết thúc —
                // `.started` đã đi rồi, im lặng ở đây để lại một transaction
                // treo vĩnh viễn trong UI.
                boundSelf.value.sink(.failed(
                    id: transaction.id,
                    message: "client ngắt trước khi nhận xong response CONNECT — \(error)",
                    endedAt: Date()))
                channel.close(promise: nil)
            }
        }
    }

    /// Bàn giao channel client từ tầng HTTP sang byte thô.
    ///
    /// THỨ TỰ Ở ĐÂY KHÔNG TUỲ TIỆN — mỗi ràng buộc dưới đây là một crash hoặc
    /// một lần mất dữ liệu nếu làm sai:
    ///
    /// 1. `httpHandlers` (encoder + `HTTPProxyHandler`) và chính handler này
    ///    phải rời pipeline TRƯỚC decoder. Gỡ decoder làm nó bắn phần byte
    ///    chưa tiêu thụ xuống dưới dạng `ByteBuffer`
    ///    (`leftOverBytesStrategy: .forwardBytes`); handler nào còn nằm dưới mà
    ///    `InboundIn` là `HTTPServerRequestPart` sẽ `fatalError` khi unwrap.
    ///    Encoder cũng phải đi trước byte tunnel đầu tiên đi ngược ra client vì
    ///    `OutboundIn` của nó là `HTTPServerResponsePart`.
    /// 2. Handler nhận byte thô phải CÓ MẶT trước khi gỡ decoder, nếu không
    ///    phần byte đó (với HTTPS thật là ClientHello) rơi xuống cuối pipeline
    ///    và bị vứt. Task 8: `beginMITM` được gọi ở đúng chỗ đó — lắp
    ///    `NIOSSLServerHandler` ngay trong nó thì cũng nhận được phần byte này.
    /// 3. Tất cả phải xong trong CÙNG một lượt event loop. Đúng vậy ở đây: mọi
    ///    thao tác đều đồng bộ, kể cả `removeHandler` của decoder (nó hoãn phần
    ///    bắn byte sang một task kế tiếp, tức là sau khi ta lắp xong handler
    ///    tunnel), nên không có lượt đọc mới nào xen vào giữa hai bước.
    private func switchToTunnel(channel: Channel, host: String, port: Int,
                                transaction: Transaction, bypassed: Bool) {
        let pipeline = channel.pipeline.syncOperations
        // Gỡ `proxy` ở vòng này chạy `HTTPProxyHandler.handlerRemoved`, và hàm
        // đó bật lại `autoRead` rồi gọi `channel.read()` — TRƯỚC khi handler
        // tunnel được lắp vài dòng dưới. An toàn vì `read()` của NIOPosix chỉ
        // đăng ký quan tâm readable rồi trả về (`readPending = true` +
        // `registerForReadable`); byte thật chỉ được giao ở vòng selector kế
        // tiếp, mà cả khối này chạy đồng bộ trong MỘT task. Nếu ai đó tách khối
        // này ra thành nhiều lượt event loop thì ràng buộc đó mất, và byte
        // client sẽ tới lúc pipeline không còn ai nhận.
        for handler in httpHandlers {
            pipeline.removeHandler(handler, promise: nil)
        }
        pipeline.removeHandler(self, promise: nil)

        if bypassed {
            do {
                try pipeline.addHandler(ConnectTunnelHandler(
                    host: host, port: port, transactionID: transaction.id,
                    maxBufferedBytes: configuration.maxInMemoryBodyBytes,
                    sink: sink
                ))
            } catch {
                sink(.failed(id: transaction.id,
                             message: "không lắp được tunnel handler: \(error)",
                             endedAt: Date()))
                channel.close(promise: nil)
                return
            }
        } else {
            beginMITM(channel: channel, host: host, port: port,
                      transactionID: transaction.id)
        }

        if let requestDecoder {
            pipeline.removeHandler(requestDecoder, promise: nil)
        }
    }

    /// Task 8 thay thân hàm này.
    func beginMITM(channel: Channel, host: String, port: Int, transactionID: UUID) {
        sink(.failed(id: transactionID, message: "MitM chưa được hỗ trợ", endedAt: Date()))
        channel.close(promise: nil)
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
