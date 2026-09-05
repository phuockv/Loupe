import Foundation
import NIOCore
import NIOPosix
import TrafficModel

/// Relay byte thô hai chiều, không giải mã. Dùng cho host trong bypass list —
/// chủ yếu là các domain pin cert, MitM vào là hỏng ngay.
///
/// Handler này ngồi ở channel CLIENT sau khi cả tầng HTTP đã bị gỡ, nên mọi
/// thứ nó thấy là `ByteBuffer` thô. Chiều ngược lại (upstream -> client) do
/// `TunnelRelayHandler` ở channel upstream lo.
///
/// Upstream KHÔNG được giữ dưới dạng `Channel` trần: xem `GuardedPeer`.
final class ConnectTunnelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let port: Int
    private let transactionID: UUID
    private let maxBufferedBytes: Int
    private let sink: TrafficEventSink

    private var upstream: GuardedPeer<ByteBuffer>?
    /// Channel client mà handler này đang ngồi trên, bọc CÙNG kiểu peer để dùng
    /// được `closeAfterPendingWrites`. Ràng buộc `Part == ByteBuffer` của hàm
    /// đó là có lý do (một `ByteBuffer` rỗng đi qua pipeline còn encoder HTTP
    /// là crash), và ràng buộc ấy chỉ còn giá trị nếu mọi channel đều đi qua
    /// `GuardedPeer` — kể cả channel của chính mình.
    private var client: GuardedPeer<ByteBuffer>?
    /// Byte client gửi trước khi upstream sẵn sàng — gồm cả phần byte mà
    /// decoder HTTP đẩy xuống lúc bị gỡ (`leftOverBytesStrategy: .forwardBytes`),
    /// vốn tới NGAY sau khi handler này được lắp. Có trần vì đây là dữ liệu
    /// từ xa: giữ vô hạn là để client bơm RAM của proxy tuỳ thích.
    private var buffered: [ByteBuffer] = []
    private var bufferedBytes = 0
    /// Tunnel đã kết thúc (client ngắt, connect hỏng, hoặc một chiều chết).
    /// Chặn cả việc dựng tiếp lẫn việc phát `.failed` hai lần.
    private var isFinished = false

    init(host: String, port: Int, transactionID: UUID,
         maxBufferedBytes: Int, sink: @escaping TrafficEventSink) {
        self.host = host
        self.port = port
        self.transactionID = transactionID
        self.maxBufferedBytes = maxBufferedBytes
        self.sink = sink
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        client = GuardedPeer(channel: clientChannel)
        // Ghim upstream vào ĐÚNG event loop của client channel: hai đầu tunnel
        // không bao giờ chạy song song, nên `buffered`/`upstream` không cần khoá.
        let boundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        TunnelRelayHandler(client: GuardedPeer(channel: clientChannel))
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                boundSelf.value.upstreamConnected(result, clientChannel: clientChannel)
            }
    }

    private func upstreamConnected(_ result: Result<Channel, Error>, clientChannel: Channel) {
        switch result {
        case .success(let channel):
            let peer = GuardedPeer<ByteBuffer>(channel: channel)
            guard !isFinished else {
                // Client đã ngắt trong lúc connect còn đang bay: không còn ai
                // dùng kết nối này — đóng luôn kẻo rò rỉ một socket không chủ.
                // Chưa ghi gì vào nó nên không có phần chưa flush để mất.
                peer.closeDiscardingPendingWrites()
                return
            }
            upstream = peer
            let replay = buffered
            buffered = []
            bufferedBytes = 0
            for (index, buffer) in replay.enumerated() {
                guard peer.write(buffer, flush: index == replay.count - 1) else {
                    upstreamVanished()
                    return
                }
            }

        case .failure(let error):
            guard !isFinished else { return }
            // Tunnel là đường DUY NHẤT ta báo cáo cho transaction này (nó
            // không đi qua `UpstreamHandler`), nên `.failed` phát ở đây.
            sink(.failed(id: transactionID,
                         message: "tunnel không nối được \(host):\(port) — \(error)",
                         endedAt: Date()))
            abandon()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isFinished else { return }
        let buffer = unwrapInboundIn(data)

        guard let upstream else {
            guard bufferedBytes + buffer.readableBytes <= maxBufferedBytes else {
                sink(.failed(id: transactionID,
                             message: "client gửi quá \(maxBufferedBytes) byte trước khi tunnel tới \(host):\(port) sẵn sàng",
                             endedAt: Date()))
                abandon()
                return
            }
            bufferedBytes += buffer.readableBytes
            buffered.append(buffer)
            return
        }

        // Ghi bị từ chối = upstream đã chết. Tunnel mù không có gì để thử lại
        // và không có cách nào báo lỗi trong băng (client đang nói TLS), nên
        // đóng nốt phía client để nó BIẾT — thay vì im lặng nuốt byte.
        if !upstream.write(buffer, flush: true) {
            upstreamVanished()
        }
    }

    /// Client đóng kết nối. `closeAfterPendingWrites` chứ không phải đóng
    /// thẳng: phần byte ta ĐÃ nhận từ client và đã chuyển cho upstream có thể
    /// còn kẹt trong `pendingWrites` của upstream (origin đọc chậm hơn client
    /// gửi). Đóng thẳng là vứt chúng — origin nhận một request TLS cụt trong
    /// khi transaction `.tunnelled` không hiện gì bất thường.
    func channelInactive(context: ChannelHandlerContext) {
        isFinished = true
        upstream?.closeAfterPendingWrites()
        upstream = nil
        buffered = []
        bufferedBytes = 0
        context.fireChannelInactive()
    }

    /// Lỗi trên channel CLIENT. Báo cáo GIỐNG HỆT nhánh connect hỏng: với người
    /// dùng thì cả hai đều là "tunnel này chết", nên cả hai phải phát `.failed`.
    ///
    /// Nhưng đóng thì KHÁC: lỗi ở chân client không nói gì về những byte ta đã
    /// nhận HỢP LỆ từ client và đã chuyển cho upstream. Vứt chúng là đúng lớp
    /// bug "proxy nói dối về thứ nó đã gửi" — nên phía upstream đóng có drain,
    /// còn phía client (chân đang lỗi) đóng thẳng.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !isFinished else { return }
        sink(.failed(id: transactionID,
                     message: "lỗi trên tunnel tới \(host):\(port) — \(error)",
                     endedAt: Date()))
        isFinished = true
        buffered = []
        bufferedBytes = 0
        upstream?.closeAfterPendingWrites()
        upstream = nil
        client?.closeDiscardingPendingWrites()
    }

    /// Upstream đã chết trong khi client VẪN CÒN GỬI. Đóng phía client bằng
    /// `closeAfterPendingWrites`, không phải đóng thẳng.
    ///
    /// Vì sao khác biệt này quan trọng: khi origin kết thúc một lần tải rồi
    /// đóng, `TunnelRelayHandler.channelInactive` bên kia vừa XẾP HÀNG một
    /// graceful close để phần đuôi kịp chảy về client. Handler này không được
    /// ai báo là upstream đã chết, nên nó chỉ phát hiện ra khi client gửi thêm
    /// byte và `write` trả `false`. Đóng thẳng ngay lúc đó là `close0` gọi
    /// `cancelWritesOnClose` và vứt đúng cái đuôi vừa được xếp hàng — im lặng,
    /// trên ĐƯỜNG THÀNH CÔNG, với transaction `.tunnelled` không hiện gì bất
    /// thường. Client vừa chậm đọc vừa còn gửi không phải ca hiếm: HTTP/2 rải
    /// WINDOW_UPDATE và PING suốt một lần tải.
    ///
    /// Byte client gửi từ đây trở đi không còn chỗ nào để tới — upstream đã
    /// chết — nên chúng bị bỏ; `isFinished` chặn ở đầu `channelRead`.
    private func upstreamVanished() {
        guard !isFinished else { return }
        isFinished = true
        upstream = nil
        buffered = []
        bufferedBytes = 0
        client?.closeAfterPendingWrites()
    }

    /// Kết thúc tunnel từ phía ta: đóng cả hai đầu và bỏ phần còn đệm.
    /// KHÔNG phát `.failed` — người gọi tự quyết định có báo cáo hay không,
    /// vì "tunnel kết thúc" là chuyện bình thường khi hai đầu nói xong.
    ///
    /// Đây là đường HUỶ (connect hỏng, vượt trần buffer, lỗi, một chiều chết
    /// giữa chừng), nên vứt phần chưa flush là đúng ý: tunnel đã hỏng rồi, đẩy
    /// nốt một mẩu byte lẻ sang chỉ làm peer thấy dữ liệu cụt mà tưởng đủ.
    private func abandon() {
        guard !isFinished else { return }
        isFinished = true
        upstream?.closeDiscardingPendingWrites()
        upstream = nil
        buffered = []
        bufferedBytes = 0
        client?.closeDiscardingPendingWrites()
    }
}

/// Nửa còn lại của tunnel: đẩy byte từ upstream về client.
///
/// Channel client cũng chỉ lộ ra qua `GuardedPeer`, không phải `Channel` trần:
/// chiều này đánh rơi byte thì người dùng thấy một response cụt mà proxy vẫn
/// tưởng mình đã chuyển đủ.
final class TunnelRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let client: GuardedPeer<ByteBuffer>
    /// Channel upstream mà handler này đang ngồi trên — cùng lý do như
    /// `ConnectTunnelHandler.client`: `closeAfterPendingWrites` chỉ tồn tại
    /// trên `GuardedPeer<ByteBuffer>`, và đó là ràng buộc muốn giữ.
    private var upstream: GuardedPeer<ByteBuffer>?

    init(client: GuardedPeer<ByteBuffer>) {
        self.client = client
    }

    func handlerAdded(context: ChannelHandlerContext) {
        upstream = GuardedPeer(channel: context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !client.write(unwrapInboundIn(data), flush: true) {
            // Client đã biến mất. Đóng phía upstream có drain, không đóng
            // thẳng: nó có thể đang giữ byte client đã gửi mà origin chưa đọc
            // hết — kể cả phần `ConnectTunnelHandler.channelInactive` vừa xếp
            // hàng để drain khi client ngắt. Đây là ảnh gương của
            // `upstreamVanished()`, và đóng thẳng ở đây là cắt cụt đúng cái
            // request TLS mà chú thích bên kia sinh ra để bảo vệ.
            upstream?.closeAfterPendingWrites()
        }
    }

    /// Upstream đóng — với HTTP qua tunnel thì đây là kết thúc BÌNH THƯỜNG của
    /// mọi lần tải xong. `closeAfterPendingWrites` chứ không phải đóng thẳng:
    /// origin ghi nhanh hơn client đọc là chuyện mặc định ở mọi file lớn, nên
    /// lúc này `pendingWrites` phía client thường vẫn còn đuôi của lần tải.
    /// Đóng thẳng ở đây là cắt cụt file, im lặng, trên đường thành công.
    func channelInactive(context: ChannelHandlerContext) {
        client.closeAfterPendingWrites()
        context.fireChannelInactive()
    }

    /// Lỗi trên channel UPSTREAM. Phía client vẫn đóng CÓ DRAIN, không đóng
    /// thẳng — và đây không phải chi tiết vụn:
    ///
    /// ca tới được là ca THÀNH CÔNG thường gặp nhất. Client vừa tải vừa gửi
    /// (HTTP/2 rải WINDOW_UPDATE suốt lần tải), origin tải xong rồi đóng HẲN,
    /// proxy đẩy nốt phần upload còn trên đường vào một socket đã đóng, origin
    /// đáp RST, và channel upstream nổ `ECONNRESET` NGAY SAU KHI toàn bộ nội
    /// dung tải về đã nằm yên trong `pendingWrites` phía client. Đóng thẳng ở
    /// đây là vứt trọn cái đuôi đó — đo được: 701 KB tới nơi trên 8 MiB.
    ///
    /// Lỗi ở chân upstream không nói gì về tính toàn vẹn của những byte ta ĐÃ
    /// nhận từ upstream và đã xếp hàng cho client. Chân đang lỗi thì đóng
    /// thẳng; chân còn lại vẫn được trả nốt thứ nó được nợ.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client.closeAfterPendingWrites()
        context.close(promise: nil)
    }
}
