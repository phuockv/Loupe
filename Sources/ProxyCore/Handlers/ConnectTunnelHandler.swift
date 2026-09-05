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
                    abandon(clientChannel: clientChannel)
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
            abandon(clientChannel: clientChannel)
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
                abandon(clientChannel: context.channel)
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
            abandon(clientChannel: context.channel)
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

    /// Lỗi trên channel client. Báo cáo GIỐNG HỆT nhánh connect hỏng: với người
    /// dùng thì cả hai đều là "tunnel này chết", nên cả hai phải phát `.failed`.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !isFinished else { return }
        sink(.failed(id: transactionID,
                     message: "lỗi trên tunnel tới \(host):\(port) — \(error)",
                     endedAt: Date()))
        abandon(clientChannel: context.channel)
    }

    /// Kết thúc tunnel từ phía ta: đóng cả hai đầu và bỏ phần còn đệm.
    /// KHÔNG phát `.failed` — người gọi tự quyết định có báo cáo hay không,
    /// vì "tunnel kết thúc" là chuyện bình thường khi hai đầu nói xong.
    ///
    /// Đây là đường HUỶ (connect hỏng, vượt trần buffer, lỗi, một chiều chết
    /// giữa chừng), nên vứt phần chưa flush là đúng ý: tunnel đã hỏng rồi, đẩy
    /// nốt một mẩu byte lẻ sang chỉ làm peer thấy dữ liệu cụt mà tưởng đủ.
    private func abandon(clientChannel: Channel) {
        guard !isFinished else { return }
        isFinished = true
        upstream?.closeDiscardingPendingWrites()
        upstream = nil
        buffered = []
        bufferedBytes = 0
        clientChannel.close(promise: nil)
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

    init(client: GuardedPeer<ByteBuffer>) {
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !client.write(unwrapInboundIn(data), flush: true) {
            // Client đã biến mất: nửa kia của tunnel không còn chỗ để đi.
            context.close(promise: nil)
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

    /// Lỗi thì ngược lại: dòng byte đã hỏng, đừng cố giao nốt phần đuôi của một
    /// thứ không còn đúng — đóng thẳng để client THẤY nó đứt.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client.closeDiscardingPendingWrites()
        context.close(promise: nil)
    }
}
