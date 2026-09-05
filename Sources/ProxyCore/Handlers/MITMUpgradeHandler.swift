import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import CertKit
import TrafficModel

/// Đứng ở channel client vừa được tháo hết tầng HTTP (xem
/// `ProxyEntryHandler.switchToTunnel`), chờ leaf cert của host rồi lắp
/// `NIOSSLServerHandler` và dựng lại một stack HTTP MỚI bên trên nó.
///
/// Sau khi handler này tự gỡ, pipeline client trông như sau — thứ tự này là
/// hợp đồng, không phải tuỳ chọn:
///
/// ```
/// head → OutputLiveness? → NIOSSLServerHandler → MITMSessionReporter
///      → HTTPResponseEncoder → HTTPRequestDecoder → HTTPProxyHandler → tail
/// ```
///
/// Việc lấy leaf là async (actor `LeafCertificateCache`) nên byte client gửi
/// tới trong lúc chờ PHẢI được đệm lại. Không đệm thì ClientHello mất và
/// handshake treo tới khi client timeout — trong đó có cả ClientHello đi CHUNG
/// một gói với dòng `CONNECT`, thứ mà `HTTPRequestDecoder(leftOverBytesStrategy:
/// .forwardBytes)` cố tình đẩy xuống đây thay vì vứt.
///
/// Buffer có TRẦN (`maxBufferedBytes`), cùng lý do với `ConnectTunnelHandler`:
/// dữ liệu do bên kia gửi, không trần là một cần gạt RAM.
final class MITMUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let port: Int
    private let transactionID: UUID
    private let maxBufferedBytes: Int
    private let configuration: ProxyConfiguration
    private let leafCache: LeafCertificateCache
    private let sink: TrafficEventSink

    private var buffered: [ByteBuffer] = []
    private var bufferedBytes = 0
    /// `install` (hoặc một nhánh bỏ cuộc) đã chạy. Handler chỉ dùng được MỘT
    /// lần: sau đó nó đã rời pipeline.
    private var isFinished = false

    init(host: String, port: Int, transactionID: UUID, maxBufferedBytes: Int,
         configuration: ProxyConfiguration, leafCache: LeafCertificateCache,
         sink: @escaping TrafficEventSink) {
        self.host = host
        self.port = port
        self.transactionID = transactionID
        self.maxBufferedBytes = maxBufferedBytes
        self.configuration = configuration
        self.leafCache = leafCache
        self.sink = sink
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let host = self.host
        let leafCache = self.leafCache
        // `NIOLoopBoundBox` chứ không phải `[weak self]`: closure truyền cho
        // `Task`/`execute` phải @Sendable, mà handler thì không Sendable. Giữ
        // tham chiếu MẠNH là chủ ý (cùng lập luận với `HTTPProxyHandler`) —
        // handler này phải sống tới lúc mint xong dù pipeline đã buông nó, nếu
        // không thì transaction biến mất không dấu vết. Box được thả ngay khi
        // Task kết thúc, nên không có vòng giữ vĩnh viễn.
        let boundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)
        Task {
            do {
                let identity = try await leafCache.identity(forHost: host)
                channel.eventLoop.execute {
                    boundSelf.value.install(identity: identity, on: channel)
                }
            } catch {
                channel.eventLoop.execute {
                    boundSelf.value.abort(
                        on: channel,
                        message: "không mint được certificate cho \(host): \(error)"
                    )
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Chỉ đệm khi TLS chưa lắp xong; sau đó handler này đã rời pipeline nên
        // byte đi thẳng vào `NIOSSLServerHandler`.
        let buffer = unwrapInboundIn(data)
        guard bufferedBytes + buffer.readableBytes <= maxBufferedBytes else {
            abort(on: context.channel,
                  message: "client gửi quá \(maxBufferedBytes) byte trước khi "
                         + "dựng xong tầng TLS cho \(host)")
            return
        }
        bufferedBytes += buffer.readableBytes
        buffered.append(buffer)
    }

    private func install(identity: TLSIdentity, on channel: Channel) {
        guard !isFinished else { return }
        guard channel.isActive else {
            abort(on: channel,
                  message: "client ngắt kết nối trước khi dựng xong tầng TLS cho \(host)")
            return
        }
        isFinished = true
        // Dựng NGOÀI `do`: nếu một lệnh bên trong ném sau khi handler này đã
        // vào pipeline thì `catch` phải BÁO QUA CHÍNH NÓ. Báo thẳng bằng `sink`
        // rồi `channel.close` sẽ kích hoạt `channelInactive` của nó — lúc đó
        // chốt vẫn chưa đặt, nên nó phát thêm một `.completed` ĐẾN SAU và che
        // mất `.failed` vừa phát. Đây là chỗ DUY NHẤT quy tắc "đúng một event
        // kết thúc" có thể sinh ra hai, với cái SAI đứng cuối.
        let sessionReporter = MITMSessionReporter(
            host: host, transactionID: transactionID, sink: sink
        )
        do {
            var tls = TLSConfiguration.makeServerConfiguration(
                certificateChain: identity.certificateChain.map { .certificate($0) },
                privateKey: .privateKey(identity.privateKey)
            )
            // CHỈ http/1.1: ép client xuống HTTP/1.1 thay vì phải cài HTTP/2
            // framing. Một trình duyệt chào "h2, http/1.1" sẽ nhận lại
            // "http/1.1" và tự hạ cấp.
            tls.applicationProtocols = ["http/1.1"]
            let sslContext = try NIOSSLContext(configuration: tls)

            let sync = channel.pipeline.syncOperations
            // Lắp NGƯỜI BÁO CÁO TRƯỚC, rồi mới tới tầng TLS: `NIOSSLHandler`
            // bắt đầu handshake ngay trong `handlerAdded` nếu channel đang
            // active, nên nếu lắp ngược thì một lỗi phát sinh ở đúng lệnh gọi
            // đó sẽ không có ai ở dưới để nghe.
            try sync.addHandler(sessionReporter, position: .before(self))
            try sync.addHandler(NIOSSLServerHandler(context: sslContext),
                                position: .before(sessionReporter))
            try sync.addHandlers([
                HTTPResponseEncoder(),
                ByteToMessageHandler(HTTPRequestDecoder()),
                HTTPProxyHandler(
                    configuration: configuration,
                    sink: sink,
                    // Request bên trong tunnel ở origin-form; host/port lấy từ
                    // dòng CONNECT, không phải từ URI.
                    fixedTarget: .init(host: host, port: port, scheme: .https)
                ),
            ], position: .after(self))
            try sync.removeHandler(self)

            // Phát lại byte đã đệm từ ĐẦU pipeline để chúng đi qua tầng TLS vừa
            // lắp. Bắn từ `context` của chính handler này thì sai hướng: nó đi
            // xuống dưới, tức BỎ QUA `NIOSSLServerHandler`.
            //
            // Phải gỡ `self` TRƯỚC lần phát lại, nếu không plaintext do TLS
            // giải mã ra sẽ rơi ngược vào `channelRead` ở trên và bị đệm lần
            // hai thay vì đi tiếp tới stack HTTP.
            let pending = buffered
            buffered = []
            bufferedBytes = 0
            for buffer in pending {
                channel.pipeline.fireChannelRead(buffer)
            }
            // Kết thúc lượt đọc giả lập này đúng như một lượt đọc thật:
            // `NIOSSLHandler.channelReadComplete` mới là chỗ đẩy phần plaintext
            // vừa giải mã xuống dưới và xả byte handshake ra socket.
            if !pending.isEmpty {
                channel.pipeline.fireChannelReadComplete()
            }
        } catch {
            // Qua `sessionReporter`, KHÔNG qua `sink` thẳng: nó vừa phát
            // `.failed` vừa ĐẶT CHỐT, nên `channel.close` ngay dưới — thứ chạy
            // `channelInactive` của chính nó nếu nó đã kịp vào pipeline —
            // không phát thêm một `.completed` đè lên nguyên nhân thật.
            sessionReporter.reportFailure(
                "không lắp được tầng TLS cho \(host): \(error)")
            channel.close(promise: nil)
        }
    }

    /// Bỏ cuộc TRƯỚC khi tầng TLS tồn tại: channel còn là byte thô, chưa có
    /// tầng nào để nói chuyện với client, nên tất cả những gì làm được là ghi
    /// lại nguyên nhân rồi đóng.
    ///
    /// Đây là channel CHƯA có TLS, nên `close` ở đây không dính vào cửa sổ
    /// "NIOSSLHandler vứt write im lặng" — xem `GuardedPeer.closeAfterPendingWrites`.
    private func abort(on channel: Channel, message: String) {
        guard !isFinished else { return }
        isFinished = true
        sink(.failed(id: transactionID, message: message, endedAt: Date()))
        channel.close(promise: nil)
    }
}

/// Người báo cáo DUY NHẤT cho transaction CONNECT của một phiên MitM, ngồi ngay
/// dưới `NIOSSLServerHandler`. Nó phát đúng MỘT event kết thúc, và chốt
/// `hasReportedTerminal` là thứ bảo đảm điều đó.
///
/// Hai kết cục:
///
/// - **Bắt tay hỏng** → `.failed` kèm hướng xử lý. Đây là kết cục hay gặp nhất
///   khi bắt app thật.
/// - **Kết nối đóng mà chưa ai báo gì** → `.completed` với CHÍNH response
///   `200 Connection Established` mà proxy đã gửi. Thiếu nhánh này thì MỌI kết
///   nối HTTPS để lại một dòng `.pending` treo vĩnh viễn, kể cả khi các request
///   bên trong nó đều hoàn tất đẹp — công cụ hiển thị một trạng thái không đúng
///   sự thật, đúng lớp lỗi cả module này tồn tại để chặn.
///
/// CHỈ báo `.failed` cho `NIOSSLError.handshakeFailed`, và đây là phần quan
/// trọng nhất: `NIOSSLHandler.channelInactive` bắn `NIOSSLError.uncleanShutdown`
/// mỗi khi peer đóng TCP mà không gửi close_notify — chuyện hoàn toàn bình
/// thường ở cuối một phiên curl hay browser. Báo lỗi cho TẤT CẢ `NIOSSLError`
/// sẽ dán nhãn hỏng lên mọi phiên MitM THÀNH CÔNG.
///
/// KHÔNG tự đóng channel: mọi đường `NIOSSLHandler` bắn `handshakeFailed` đều
/// gọi `channelClose` ngay sau đó (`doHandshakeStep` nhánh `.failed`), còn
/// đường `channelInactive` thì channel đã chết rồi. Đóng thêm một lần nữa chỉ
/// là chen ngang một thủ tục shutdown đang chạy.
final class MITMSessionReporter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let transactionID: UUID
    private let sink: TrafficEventSink
    private var hasReportedTerminal = false

    init(host: String, transactionID: UUID, sink: @escaping TrafficEventSink) {
        self.host = host
        self.transactionID = transactionID
        self.sink = sink
    }

    /// Phát `.failed` và ĐẶT CHỐT. Dùng cho người dựng pipeline khi việc lắp
    /// hỏng giữa chừng: chốt là thứ ngăn `channelInactive` ngay sau đó phát
    /// thêm một `.completed` đè lên nguyên nhân thật.
    func reportFailure(_ message: String) {
        guard !hasReportedTerminal else { return }
        hasReportedTerminal = true
        sink(.failed(id: transactionID, message: message, endedAt: Date()))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !hasReportedTerminal, let message = Self.handshakeFailureMessage(for: error, host: host) {
            hasReportedTerminal = true
            sink(.failed(id: transactionID, message: message, endedAt: Date()))
        }
        // Vẫn cho lỗi đi tiếp: nuốt nó ở đây sẽ giấu mất thông tin của các
        // handler dưới (và của log lỗi chưa xử lý ở tail).
        context.fireErrorCaught(error)
    }

    /// Chạy SAU `errorCaught` trong mọi đường lỗi của `NIOSSLHandler`
    /// (`channelInactive` của nó `fireErrorCaught` rồi mới `fireChannelInactive`),
    /// nên chốt đã được đặt và nhánh này không ghi đè một `.failed` có thật.
    func channelInactive(context: ChannelHandlerContext) {
        if !hasReportedTerminal {
            hasReportedTerminal = true
            sink(.completed(id: transactionID, ConnectEstablished.responseModel,
                            endedAt: Date()))
        }
        context.fireChannelInactive()
    }

    /// `nil` nghĩa là "không phải lỗi bắt tay phía client" — xem chú thích trên
    /// kiểu này để biết vì sao im lặng ở đó là bắt buộc.
    ///
    /// Message nêu HIỆN TƯỢNG trước, rồi mới đưa nguyên nhân KHẢ DĨ. Đây không
    /// phải chuyện văn phong: hàm này bắn cho MỌI `handshakeFailed` phía server,
    /// trong đó có "client không nói TLS chút nào", "không có phiên bản TLS
    /// chung", "không có cipher chung", và "client mở CONNECT rồi bỏ đi"
    /// (`eofDuringHandshake`). Mở đầu bằng "client từ chối certificate" là
    /// khẳng định một chẩn đoán mà chỗ này không có dữ kiện để đưa ra — cùng
    /// nguyên tắc đã áp dụng cho message của `handlerRemoved` bên
    /// `HTTPProxyHandler`: nêu thứ mình BIẾT, đừng đoán nguyên nhân.
    static func handshakeFailureMessage(for error: Error, host: String) -> String? {
        guard let sslError = error as? NIOSSLError,
              case .handshakeFailed = sslError
        else { return nil }
        return "bắt tay TLS với client hỏng cho \(host), nên không MitM được kết "
             + "nối này. Nguyên nhân hay gặp nhất là cert pinning: app từ chối "
             + "leaf do proxy mint. Cũng có thể máy chưa trust CA của proxy, "
             + "client không nói TLS, hoặc hai bên không có phiên bản/cipher "
             + "chung. Cách đi tiếp: thêm \(host) vào bypass list để tunnel thẳng "
             + "không giải mã, hoặc trust CA của proxy rồi thử lại. "
             + "Lỗi gốc: \(error)"
    }
}
