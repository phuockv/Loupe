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
    private let reporter: TunnelReporter

    private var upstream: GuardedPeer<ByteBuffer>?
    /// Channel client mà handler này đang ngồi trên, bọc CÙNG kiểu peer để dùng
    /// được `closeAfterPendingWrites`. Ràng buộc `Part == ByteBuffer` của hàm
    /// đó là có lý do — nửa-đóng chiều ra là ngữ nghĩa TUNNEL, với channel HTTP
    /// thì sai (xem `GuardedPeer.closeAfterPendingWrites`) — và ràng buộc ấy chỉ
    /// còn giá trị nếu mọi channel đều đi qua `GuardedPeer`, kể cả channel của
    /// chính mình.
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
        self.reporter = TunnelReporter(transactionID: transactionID, sink: sink)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        client = GuardedPeer(channel: clientChannel)
        // Chân client. Chân upstream được đăng ký ở `upstreamConnected` khi (và
        // chỉ khi) nó thật sự được nhận nuôi — xem `TunnelReporter.legClosed`.
        reporter.legOpened()
        // `TunnelReporter` cố ý KHÔNG Sendable (cùng lý do như `SessionState`:
        // hai channel ghim chung một event loop nên không cần khoá), mà
        // `channelInitializer` đòi closure @Sendable — bọc NIOLoopBoundBox, hợp
        // lệ vì bootstrap dùng `group: context.eventLoop`.
        let boundReporter = NIOLoopBoundBox(reporter, eventLoop: context.eventLoop)
        // Ghim upstream vào ĐÚNG event loop của client channel: hai đầu tunnel
        // không bao giờ chạy song song, nên `buffered`/`upstream` không cần khoá.
        let boundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        TunnelRelayHandler(client: GuardedPeer(channel: clientChannel),
                                           reporter: boundReporter.value)
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
            reporter.legOpened()
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
            reporter.reportFailure("tunnel không nối được \(host):\(port) — \(error)")
            abandon()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isFinished else { return }
        let buffer = unwrapInboundIn(data)

        guard let upstream else {
            guard bufferedBytes + buffer.readableBytes <= maxBufferedBytes else {
                reporter.reportFailure(
                    "client gửi quá \(maxBufferedBytes) byte trước khi tunnel tới \(host):\(port) sẵn sàng")
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
        drainUpstream()
        upstream = nil
        buffered = []
        bufferedBytes = 0
        reporter.legClosed()
        context.fireChannelInactive()
    }

    /// Nửa-đóng chiều ra của upstream sau khi xả nốt. Watchdog xả có thể BỎ CUỘC
    /// và đóng cứng giữa chừng — khi đó nó cắt cụt đúng cái request TLS mà lần
    /// xả này sinh ra để bảo vệ, nên nó phải phát `.failed` chứ không được im
    /// lặng. Đó là lý do `onDrainAbandoned` không có giá trị mặc định.
    private func drainUpstream() {
        upstream?.closeAfterPendingWrites(
            onDrainAbandoned: { [reporter = self.reporter, host = self.host, port = self.port] discarded in
                reporter.reportFailure(
                    "tunnel tới \(host):\(port) bị cắt trong lúc dọn: upstream ngừng nhận trọn "
                    + "một chu kỳ, ít nhất \(discarded) byte client đã gửi không tới được origin")
            })
    }

    /// Ảnh gương của `drainUpstream` cho chân client.
    private func drainClient() {
        client?.closeAfterPendingWrites(
            onDrainAbandoned: { [reporter = self.reporter, host = self.host, port = self.port] discarded in
                reporter.reportFailure(
                    "tunnel tới \(host):\(port) bị cắt trong lúc dọn: client ngừng nhận trọn "
                    + "một chu kỳ, ít nhất \(discarded) byte đã nhận từ origin không tới được client")
            })
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
        reporter.reportFailure("lỗi ở chân client của tunnel tới \(host):\(port) — \(error)")
        isFinished = true
        buffered = []
        bufferedBytes = 0
        drainUpstream()
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
        drainClient()
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
    private let reporter: TunnelReporter
    /// Channel upstream mà handler này đang ngồi trên — cùng lý do như
    /// `ConnectTunnelHandler.client`: `closeAfterPendingWrites` chỉ tồn tại
    /// trên `GuardedPeer<ByteBuffer>`, và đó là ràng buộc muốn giữ.
    private var upstream: GuardedPeer<ByteBuffer>?
    /// Chỉ để BÁO CÁO, và chỉ đếm phần channel client ĐÃ NHẬN — cộng dồn trước
    /// khi ghi thì mỗi buffer bị `client.write` từ chối vẫn được tính, và con
    /// số ta trích dẫn trong `.failed` thành ra to hơn thứ thật sự đã chuyển.
    /// Với một tunnel mù thì đây là con số duy nhất ta biết chắc, nên nó không
    /// được phép nói quá.
    private var bytesRelayedToClient = 0
    /// Tunnel đã kết thúc ở chân này. Ảnh gương của
    /// `ConnectTunnelHandler.isFinished`: chặn đếm tiếp sau khi client đã biến
    /// mất, và chặn xếp hàng hai lượt nửa-đóng cho cùng một channel.
    private var isFinished = false

    init(client: GuardedPeer<ByteBuffer>, reporter: TunnelReporter) {
        self.client = client
        self.reporter = reporter
    }

    func handlerAdded(context: ChannelHandlerContext) {
        upstream = GuardedPeer(channel: context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isFinished else { return }
        let buffer = unwrapInboundIn(data)
        guard client.write(buffer, flush: true) else {
            // Client đã biến mất. Đóng phía upstream có drain, không đóng
            // thẳng: nó có thể đang giữ byte client đã gửi mà origin chưa đọc
            // hết — kể cả phần `ConnectTunnelHandler.channelInactive` vừa xếp
            // hàng để drain khi client ngắt. Đây là ảnh gương của
            // `upstreamVanished()`, và đóng thẳng ở đây là cắt cụt đúng cái
            // request TLS mà chú thích bên kia sinh ra để bảo vệ.
            isFinished = true
            drainUpstream()
            return
        }
        bytesRelayedToClient += buffer.readableBytes
    }

    /// Upstream đóng — với HTTP qua tunnel thì đây là kết thúc BÌNH THƯỜNG của
    /// mọi lần tải xong. `closeAfterPendingWrites` chứ không phải đóng thẳng:
    /// origin ghi nhanh hơn client đọc là chuyện mặc định ở mọi file lớn, nên
    /// lúc này `pendingWrites` phía client thường vẫn còn đuôi của lần tải.
    /// Đóng thẳng ở đây là cắt cụt file, im lặng, trên đường thành công.
    func channelInactive(context: ChannelHandlerContext) {
        if !isFinished {
            isFinished = true
            drainClient()
        }
        reporter.legClosed()
        context.fireChannelInactive()
    }

    /// Nửa-đóng chiều ra của client sau khi xả nốt, và BÁO nếu watchdog xả bỏ
    /// cuộc. Cắt cụt ở đây là cắt cụt đuôi một lần tải, trên đường thành công —
    /// đúng thứ không được phép xảy ra trong im lặng.
    private func drainClient() {
        client.closeAfterPendingWrites(
            onDrainAbandoned: { [reporter = self.reporter] discarded in
                reporter.reportFailure(
                    "tunnel bị cắt trong lúc dọn: client ngừng nhận trọn một chu kỳ, "
                    + "ít nhất \(discarded) byte đã nhận từ origin không tới được client")
            })
    }

    private func drainUpstream() {
        upstream?.closeAfterPendingWrites(
            onDrainAbandoned: { [reporter = self.reporter] discarded in
                reporter.reportFailure(
                    "tunnel bị cắt trong lúc dọn: upstream ngừng nhận trọn một chu kỳ, "
                    + "ít nhất \(discarded) byte client đã gửi không tới được origin")
            })
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
    ///
    /// Nói cho chặt: ở đây ta thậm chí KHÔNG có lựa chọn nào về chân đang lỗi.
    /// `BaseSocketChannel.readable0` gọi `fireErrorCaught(err)` rồi ngay sau đó
    /// `if shouldCloseOnReadError(err) { close0(mode: .all) }`, mà
    /// `SocketChannel.shouldCloseOnReadError` chỉ trả `false` cho đúng một loại
    /// (`NIOFcntlFailedError`) — nên chân lỗi bị NIO đóng hẳn dù handler có xin
    /// hay không. Quyết định DUY NHẤT `errorCaught` thực sự đưa ra là làm gì với
    /// peer CÒN SỐNG, và ở đó đóng cứng phá tới trọn một response đã xếp hàng mà
    /// không mua lại được tín hiệu nào.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Ghi nhận, chứ KHÔNG quay lại đóng cứng. Không ghi nhận thì client nhận
        // một FIN đàng hoàng CÒN bản ghi hiện một tunnel sạch sẽ — tức công cụ
        // nói dối, đúng thứ cả file này sinh ra để chặn.
        //
        // Message chỉ nói thứ ta BIẾT, và mọi thứ nó không biết thì nói ra là
        // không biết. Tunnel mù không nhìn được vào trong dòng TLS nên handler
        // này không phân biệt được "reset vô hại sau khi origin đã gửi xong" với
        // "origin chết giữa chừng" — vì thế tiêu đề KHÔNG được nói "giữa tunnel",
        // đó là khẳng định đúng cái điều hai dòng dưới thừa nhận là không biết.
        //
        // Con số byte cũng chỉ được nêu ở đúng mức nó đúng: nó là phần channel
        // client ĐÃ NHẬN vào hàng đợi ghi. Nói thêm rằng "số byte đó vẫn được
        // giao nốt" là bịa: `closeAfterPendingWrites` ngay dưới có thể bị
        // watchdog xả cắt ngang, và khi đó phần còn tồn bị vứt.
        reporter.reportFailure(
            "lỗi ở chân upstream của tunnel — \(error); đã chuyển được "
            + "\(bytesRelayedToClient) byte sang channel client (chưa chắc đã ra hết tới "
            + "client: phần còn tồn đang được xả và có thể bị cắt nếu client ngừng nhận). "
            + "Tunnel mù không đọc được nội dung nên không phân biệt được origin đã gửi "
            + "xong hay bị cắt giữa chừng."
        )
        // Báo thì vẫn báo (chốt at-most-once nằm trong `TunnelReporter`), nhưng
        // DỌN thì không làm lại. Lượt dọn trước — chân client biến mất ở
        // `channelRead` — đã xếp một lần nửa-đóng CÓ XẢ cho upstream, và
        // `context.close` dưới đây sẽ cắt ngang đúng lượt xả đó.
        guard !isFinished else { return }
        isFinished = true
        drainClient()
        context.close(promise: nil)
    }
}

/// Phát `.failed` cho một transaction tunnel, ĐÚNG MỘT LẦN, dùng chung giữa hai
/// đầu.
///
/// Cần dùng chung vì hai handler ở hai channel khác nhau đều có thể là nơi đầu
/// tiên phát hiện tunnel hỏng (`ConnectTunnelHandler` ở chân client,
/// `TunnelRelayHandler` ở chân upstream), và một lỗi thường làm CẢ HAI chân
/// hỏng theo. Không có chốt chung thì cùng một sự cố sinh hai `.failed` cho
/// cùng một id.
///
/// Không khoá, không actor: hai channel được ghim vào CÙNG event loop (xem
/// `ConnectTunnelHandler.handlerAdded` dùng `ClientBootstrap(group:)` với event
/// loop của client channel), nên chúng không bao giờ chạy song song — cùng lập
/// luận với `SessionState`.
final class TunnelReporter {
    private let transactionID: UUID
    private let sink: TrafficEventSink
    private var hasReported = false
    /// Số chân tunnel đã dựng mà chưa đóng hẳn. Xem `legClosed`.
    private var openLegs = 0

    init(transactionID: UUID, sink: @escaping TrafficEventSink) {
        self.transactionID = transactionID
        self.sink = sink
    }

    func reportFailure(_ message: String) {
        guard !hasReported else { return }
        hasReported = true
        sink(.failed(id: transactionID, message: message, endedAt: Date()))
    }

    /// Một chân tunnel vừa được dựng. Phải gọi TRƯỚC khi chân đó có thể đóng.
    func legOpened() {
        openLegs += 1
    }

    /// Một chân tunnel vừa đóng hẳn. Chân CUỐI CÙNG đóng là lúc tunnel kết
    /// thúc; nếu tới lúc đó chưa ai báo gì thì nó đã kết thúc SẠCH.
    ///
    /// Vì sao phải là chân CUỐI chứ không phải chân đầu — chỗ này dễ sai:
    /// `ConnectTunnelHandler.channelInactive` chạy khi client đóng, rồi nó gọi
    /// `closeAfterPendingWrites` lên upstream, và lượt xả đó có thể BỎ CUỘC vài
    /// giây sau rồi gọi `reportFailure`. Báo "kết thúc sạch" ngay ở chân đầu sẽ
    /// khoá chốt at-most-once và NUỐT MẤT báo cáo cắt cụt đó — đúng lớp bug
    /// "công cụ nói dối" mà `TunnelReporter` sinh ra để chặn. Đợi tới chân cuối
    /// thì mọi lượt xả hoặc đã xong, hoặc đã kịp báo.
    func legClosed() {
        openLegs -= 1
        guard openLegs <= 0, !hasReported else { return }
        hasReported = true
        // Response THẬT mà proxy đã gửi cho CONNECT này, không phải một giá trị
        // tổng hợp cho đẹp bảng. Thiếu event này thì MỌI kết nối HTTPS để lại
        // một dòng treo vĩnh viễn trong UI — công cụ hiển thị một trạng thái
        // không đúng sự thật.
        sink(.completed(id: transactionID, ConnectEstablished.responseModel,
                        endedAt: Date()))
    }
}
