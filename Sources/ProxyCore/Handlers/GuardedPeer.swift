import NIOCore
import NIOSSL

/// Cờ "chiều RA của channel này đã đóng chưa", sống trên ĐÚNG một channel.
///
/// Vì sao nó phải là một handler trong pipeline chứ không phải một field của
/// `GuardedPeer`: `GuardedPeer` là struct, và CÙNG một channel bị bọc bởi
/// NHIỀU giá trị struct khác nhau ở các handler khác nhau —
/// `ConnectTunnelHandler.client` và `TunnelRelayHandler.client` là hai giá trị
/// riêng biệt cùng trỏ vào channel client. Một cờ cục bộ chỉ đúng cho đúng bản
/// sao đã đặt nó; bản sao kia vẫn tưởng ghi được. Trạng thái vì thế phải suy ra
/// từ CHANNEL, và pipeline là chỗ duy nhất gắn được trạng thái vào một channel.
///
/// Cờ được đặt bằng HAI đường, thừa một cách cố ý:
///
/// 1. `GuardedPeer.closeAfterPendingWrites` đặt NGAY lúc quyết định nửa-đóng,
///    tức từ chối ghi mới trong CẢ giai đoạn xả. Đúng ý chứ không phải bảo thủ
///    quá mức: đã quyết kết thúc chiều ra thì byte mới không còn chỗ để đi, và
///    mọi đường tới đây đều là "chân đối diện đã chết".
/// 2. `ChannelEvent.outputClosed` — sự kiện NIO bắn khi `shutdown(how: .WR)`
///    thật sự xảy ra (`BaseStreamSocketChannel.close0` bắn nó ở cả nhánh đóng
///    ngay lẫn nhánh đóng sau khi xả xong). Đường này bắt cả trường hợp ai đó
///    nửa-đóng channel KHÔNG qua `GuardedPeer`.
///
/// GIỚI HẠN mà đường (2) KHÔNG phủ, và Task 8 phải biết: trên một channel có
/// `NIOSSLHandler`, `closeOutput` đặt state `.outputClosed` của CHÍNH nó ngay ở
/// ĐẦU thủ tục và từ giây đó mọi write bị `promise?.fail(ChannelError.outputClosed)`
/// — với `promise: nil` là một byte biến mất im lặng. Nhưng `OutputLiveness` ngồi
/// ở `.first`, tức DƯỚI tầng TLS, nên nó chỉ thấy `outputClosed` khi SOCKET
/// nửa-đóng ở cuối thủ tục shutdown TLS. Cửa sổ giữa hai mốc đó nằm ngoài tầm
/// nhìn của cờ này. Kết luận đang được giữ: KHÔNG nửa-đóng chiều ra của một
/// channel có TLS — và nó được ÉP bằng một `precondition` ở đầu
/// `closeAfterPendingWrites` (tìm `NIOSSLHandler` trong pipeline), không phải
/// bằng ràng buộc `Part == ByteBuffer`, vốn là phantom và không kiểm được gì.
///
/// `@unchecked Sendable` có cơ sở chứ không phải để làm ngơ: mọi lần đọc/ghi cờ
/// đều nằm trên event loop của channel — `userInboundEventTriggered` theo định
/// nghĩa, còn hai lối kia đi qua `GuardedPeer`, mà `GuardedPeer.init` và
/// `GuardedPeer.write` đều `preconditionInEventLoop()` (KHÔNG phải `assert` —
/// xem chú thích ở `GuardedPeer.init`), nên ràng buộc còn hiệu lực trong cả
/// release build.
final class OutputLiveness: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny

    private(set) var isOutputClosed = false

    /// Lấy bản theo dõi của channel này, lắp mới nếu chưa có.
    ///
    /// Dùng lại bản đã có là BẮT BUỘC chứ không phải tối ưu: một channel client
    /// HTTP keep-alive dựng một `GuardedPeer` mới cho MỖI kết nối upstream, nên
    /// lắp mới mỗi lần là rò handler vào pipeline theo số transaction.
    static func attached(to channel: Channel) -> OutputLiveness {
        let pipeline = channel.pipeline.syncOperations
        if let existing = try? pipeline.handler(type: OutputLiveness.self) {
            return existing
        }
        let fresh = OutputLiveness()
        do {
            // `.first`: sự kiện inbound đi từ head xuống, nên đứng ngay sau head
            // là chỗ không handler nào chen lên trước để nuốt `outputClosed`.
            try pipeline.addHandler(fresh, position: .first)
        } catch {
            // Pipeline không nhận handler nghĩa là channel đã đóng hẳn. Ngả về
            // phía AN TOÀN: coi như không ghi được nữa. Ngả về phía kia là đúng
            // lớp bug mà cả file này sinh ra để chặn.
            fresh.isOutputClosed = true
        }
        return fresh
    }

    func markOutputClosed() {
        isOutputClosed = true
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.outputClosed:
            isOutputClosed = true
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// Pipeline của `channel` có tầng TLS không.
///
/// Tách ra khỏi `precondition` gọi nó vì phần dễ sai nằm ở phép so KIỂU, không
/// ở chỗ gọi: `NIOSSLServerHandler` và `NIOSSLClientHandler` là LỚP CON của
/// `NIOSSLHandler`, nên hàm này chỉ đúng nếu `handler(type:)` so bằng
/// `is`/dynamic cast chứ không phải so kiểu chính xác. Nó có: NIO cài
/// `_contextSync(handlerType:)` bằng `{ $0.handler is Handler }`. Một
/// `precondition` không test được (nó làm sập tiến trình), còn hàm này thì
/// được — xem `ConnectTunnelTests`.
///
/// PHẠM VI, và nó hẹp hơn cái tên gợi ra — quan trọng với Task 10–12 (app
/// macOS). Hàm này chỉ thấy tầng TLS nếu nó là một `NIOSSLHandler` NẰM TRONG
/// pipeline này. Nó KHÔNG thấy:
///
/// - một handler tự viết ôm `SSLConnection` mà không kế thừa `NIOSSLHandler`;
/// - TLS được kết thúc DƯỚI pipeline — `NIOTransportServices` /
///   Network.framework làm đúng như vậy, và đó là thứ người viết app macOS rất
///   dễ với tay lấy.
///
/// Ở cả hai trường hợp đó, `precondition` sẽ im lặng cho qua và hazard 1 mở lại
/// nguyên vẹn. Nếu ProxyCore có ngày chạy trên một transport như thế thì phép
/// kiểm này phải được thay, không phải bổ sung.
func channelHasTLSLayer(_ channel: Channel) -> Bool {
    channel.eventLoop.preconditionInEventLoop()
    return (try? channel.pipeline.syncOperations.handler(type: NIOSSLHandler.self)) != nil
}

/// Một channel "phía bên kia" mà handler này ghi vào, với `Channel` bị giấu kín.
///
/// Đây là bản cài đặt DUY NHẤT của phép kiểm liveness trước khi ghi: `channel`
/// để `private` nên không có cách nào lấy nó ra để ghi thẳng, và
/// `write(_:flush:)` — chỗ duy nhất ghi được — vừa giữ phép kiểm liveness vừa
/// trả về một `Bool` KHÔNG `@discardableResult`.
///
/// Phép kiểm đó là HAI vế, không phải một. `isActive` KHÔNG đủ: một channel vừa
/// bị `closeAfterPendingWrites` nửa-đóng chiều ra vẫn `isActive == true` —
/// `close0(mode: .output)` không đụng tới `lifecycleManager` — trong khi
/// `BaseStreamSocketChannel.bufferPendingWrite` đã bắt đầu bằng
/// `if self.outputShutdown { promise?.fail(...); return }`. Với `promise: nil`
/// thì đó là một byte biến mất im lặng và một `write` trả `true`. Vế thứ hai
/// (`OutputLiveness`) đóng đúng cái cửa đó.
///
/// PHẠM VI nó thật sự khoá được, nói cho đúng: các peer ĐƯỢC LƯU trong
/// `HTTPProxyHandler` (qua `UpstreamConnection`), `UpstreamHandler`,
/// `ConnectTunnelHandler` và `TunnelRelayHandler`. Nó KHÔNG phải một bất biến
/// toàn ProxyCore: ai viết handler mới vẫn có thể nhận `Channel` trần qua init
/// và ghi vào đó, compiler không phản đối. Còn đúng HAI chỗ ghi thẳng:
/// `HTTPProxyHandler.respond(channel:)` và `ProxyEntryHandler.respond(channel:)`
/// (bản thứ ba, `UpstreamHandler.respond`, đã chuyển sang đây). Cả hai ghi vào
/// channel của CHÍNH pipeline mình đang nằm trong chứ không phải một peer, và
/// cả hai đã đóng bên trong promise của lần `writeAndFlush` cuối — tức không
/// cắt cụt được. Thứ chúng thiếu chỉ là phép kiểm `isActive` trước khi ghi.
///
/// Vì sao phải cứng tới mức đó: bug "ghi vào một channel không nhận được, byte
/// biến mất im lặng, trong khi transaction ta ghi lại vẫn hiện đầy đủ" đã tái
/// xuất BỐN lần ở bốn đường khác nhau của đường HTTP plaintext. Ba lần đầu vá
/// đúng đường vừa tìm ra, và lần sau lại lòi ra đường kế tiếp, vì thứ giữ cho
/// các chỗ ghi CÒN LẠI an toàn chỉ là một lập luận về thứ tự. Lần thứ tư mới
/// làm nó thành cấu trúc.
///
/// Với một proxy gỡ rối thì lớp bug này là tệ nhất có thể: công cụ nói dối về
/// thứ nó đã gửi.
///
/// Generic trên `Part` vì các đường dùng kiểu message khác nhau —
/// `HTTPClientRequestPart` ra upstream, `HTTPServerResponsePart` về client,
/// `ByteBuffer` cho tunnel mù — nhưng cái guard thì chỉ có MỘT bản, ở đây.
/// `Part: Sendable` để dùng được overload `write`/`writeAndFlush` nhận giá trị
/// trực tiếp thay vì bọc `NIOAny` (bản NIOAny đã deprecated vì không Sendable).
/// Cả ba kiểu đang dùng đều thoả.
struct GuardedPeer<Part: Sendable> {
    private let channel: Channel
    private let output: OutputLiveness

    /// PHẢI chạy trên event loop của `channel`, và `preconditionInEventLoop()`
    /// ở dòng đầu là thứ ép điều đó — vi phạm là crash ngay tại chỗ dựng chứ
    /// không phải một cuộc đua âm thầm sau này.
    ///
    /// Vì sao KHÔNG dựa vào `pipeline.syncOperations` (bản trước của chú thích
    /// này khẳng định như vậy, và khẳng định đó SAI): mọi lối vào của
    /// `SynchronousOperations` chỉ gọi `assertInEventLoop`, mà `assertInEventLoop`
    /// bọc trong `debugOnly` — trong release nó không kiểm gì cả. Dựng
    /// `GuardedPeer` ngoài loop trong một bản release vì thế sẽ sửa danh sách
    /// liên kết của pipeline từ thread khác và đua trên một `Bool` không đồng
    /// bộ, im lặng. Cả cơ sở của `@unchecked Sendable` trên `OutputLiveness`
    /// lẫn việc bỏ khoá đều đứng trên ràng buộc này, nên nó phải là
    /// `precondition` chứ không phải `assert`.
    ///
    /// Đó không phải phiền toái thêm vào: mọi chỗ dựng `GuardedPeer` trong
    /// ProxyCore đều nằm trong callback của một handler hoặc trong
    /// `channelInitializer` của một bootstrap ghim vào đúng loop ấy (upstream
    /// luôn `ClientBootstrap(group: context.eventLoop)`). Đáng chú ý:
    /// `UpstreamHandler.init` dựng peer cho channel CLIENT từ bên trong
    /// `channelInitializer` của channel UPSTREAM — hợp lệ chỉ vì hai channel
    /// dùng chung một event loop, và giờ điều đó được kiểm thật thay vì được
    /// lập luận.
    init(channel: Channel) {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        self.output = OutputLiveness.attached(to: channel)
    }

    var isActive: Bool { channel.isActive }

    /// Dùng để dựng `ByteBuffer` cho peer này. Không phải lối thoát: allocator
    /// không ghi được gì.
    var allocator: ByteBufferAllocator { channel.allocator }

    /// Ghi một part ra peer; trả `false` — và KHÔNG ghi gì — nếu channel đã
    /// chết HOẶC chiều ra của nó đã đóng. Cố ý KHÔNG `@discardableResult`: bỏ
    /// qua giá trị trả về chính là bỏ qua tín hiệu mà cả lớp bug này xoay quanh.
    ///
    /// `promise: nil` là chủ ý cho đường nóng (một promise cho mỗi gói tin
    /// relay là một cấp phát cho mỗi gói tin), nhưng nó có hai hệ quả PHẢI biết:
    ///
    /// - `flush` chỉ là yêu cầu, byte có thể còn nằm trong `pendingWrites` nếu
    ///   send buffer của socket đã đầy. Vì thế "ghi xong rồi đóng" phải dùng
    ///   `writeThenClose` hoặc `closeAfterPendingWrites`, KHÔNG phải
    ///   `closeDiscardingPendingWrites`.
    /// - Không có promise thì mọi thất bại NIO báo qua promise đều không đi đâu
    ///   cả. `true` ở đây vì thế chỉ có nghĩa "NIO đã NHẬN part vào hàng đợi
    ///   ghi", không phải "byte đã tới nơi". Phần bị vứt SAU khi đã nhận là
    ///   trách nhiệm của bên đóng: `closeDiscardingPendingWrites` mang cái tên
    ///   dài đó vì lý do này, và watchdog xả trong `closeAfterPendingWrites`
    ///   bắt buộc phải báo cáo phần nó vứt.
    ///
    /// `preconditionInEventLoop()` chứ không phải `assertInEventLoop()`: cái sau
    /// là `debugOnly`, tức trong release một lần ghi ngoài loop sẽ chạy thẳng
    /// vào `OutputLiveness.isOutputClosed` (một `Bool` không đồng bộ) và vào
    /// hàng đợi ghi của channel từ thread lạ.
    func write(_ part: Part, flush: Bool) -> Bool {
        channel.eventLoop.preconditionInEventLoop()
        guard channel.isActive, !output.isOutputClosed else { return false }
        if flush {
            channel.writeAndFlush(part, promise: nil)
        } else {
            channel.write(part, promise: nil)
        }
        return true
    }

    /// Ghi part CUỐI CÙNG của một response kết thúc (`.end`) rồi đóng channel
    /// khi chính lần ghi đó đã ra tới socket — không cắt cụt phần vừa ghi lẫn
    /// phần còn kẹt trước đó.
    ///
    /// CHỈ dùng cho đúng ngữ cảnh đó, không phải cho việc ghi nói chung: đây là
    /// hàm ghi DUY NHẤT trên `GuardedPeer` không trả tín hiệu từ chối, và nó
    /// được phép như vậy vì ở ngữ cảnh này không có gì để người gọi xử lý —
    /// channel đã chết thì không ghi gì và đóng luôn, đúng thứ người gọi định
    /// làm. Mọi lần ghi khác phải qua `write(_:flush:)` và phải xử lý `false`.
    func writeThenClose(_ part: Part) {
        let channel = self.channel
        guard channel.isActive, !output.isOutputClosed else {
            channel.close(promise: nil)
            return
        }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
        channel.writeAndFlush(part, promise: promise)
    }

    /// Đóng NGAY, VỨT mọi byte đã ghi mà chưa ra tới socket.
    ///
    /// Tên dài là cố ý. `close0` của NIO gọi `cancelWritesOnClose`, tức mọi mục
    /// còn trong `pendingWrites` bị fail — và với `promise: nil` thì thất bại
    /// đó không đi đâu cả. Đó đúng là lớp bug `GuardedPeer` sinh ra để chặn,
    /// chỉ khác lối vào là `close()` thay vì `write()`. Chỉ dùng khi việc vứt
    /// là ĐÚNG Ý (đang huỷ bỏ, hoặc dữ liệu đã hỏng sẵn), và nói rõ lý do tại
    /// chỗ gọi.
    func closeDiscardingPendingWrites() {
        channel.close(promise: nil)
    }
}

extension GuardedPeer where Part == ByteBuffer {
    /// Kết thúc chiều RA sau khi mọi byte đã ghi tới nơi, rồi để channel tự đóng
    /// hẳn khi peer đóng nốt chiều của nó. Dùng cho hai đầu tunnel: khi một
    /// chiều chết, phần đuôi đã nhận được của chiều kia vẫn phải tới nơi.
    ///
    /// Không có việc này thì mọi lần tải file lớn qua host bypass đều có nguy cơ
    /// mất đuôi: origin ghi nhanh hơn client đọc, origin đóng, và
    /// `channelInactive` đóng luôn phía client trong khi `pendingWrites` còn đầy
    /// — im lặng, và transaction của tunnel không hiện gì bất thường.
    ///
    /// PHẢI là `close(mode: .output)` chứ không phải "xả xong rồi đóng hẳn", và
    /// đây là chỗ dễ sai nhất trong cả file:
    ///
    /// - `.output` của NIO tự nó đã là "xả rồi mới đóng": `close0` đưa promise
    ///   cho `pendingWrites.closeOutbound(_:)` và chỉ `shutdown(how: .WR)` sau
    ///   khi hàng đợi ghi đã sạch. Không cần tự xếp một lần ghi rỗng làm mốc.
    /// - Đóng HẲN sau khi xả xong VẪN mất byte, và bản vá đầu tiên của tôi mắc
    ///   đúng lỗi đó: xả sạch `pendingWrites` của NIO không có nghĩa là byte đã
    ///   tới client — chúng còn nằm trong send buffer của kernel. `close()` một
    ///   socket đang CÒN dữ liệu chưa đọc ở chiều vào thì BSD/POSIX gửi RST chứ
    ///   không gửi FIN, và RST vứt luôn send buffer. Mà "còn dữ liệu chưa đọc ở
    ///   chiều vào" chính là ca ta đang xử lý: client vẫn đang gửi. Quan sát
    ///   được: promise xả báo `success()` mà client vẫn thiếu byte, test hồi
    ///   quy đỏ 12/12 cho tới khi đổi sang nửa-đóng.
    ///   `shutdown(how: .WR)` gửi FIN, không đụng gì tới dữ liệu đang chờ.
    ///
    /// HAI giai đoạn, HAI hạn chờ khác nhau, vì hỏng ở hai giai đoạn có hậu quả
    /// khác hẳn nhau:
    ///
    /// - **Xả** (`stallTimeout`): hết hạn ở đây LÀM MẤT DỮ LIỆU. Nên nó không
    ///   phải hạn theo tổng thời gian — tunnel không có backpressure, lượng tồn
    ///   khi origin đóng về nguyên tắc không có trần, và một client đường truyền
    ///   chậm ôm hàng chục MB thì không con số cố định nào là đủ. Nó là hạn
    ///   ĐỨNG IM: mỗi chu kỳ so `bufferedWritableBytes` với lần trước, còn tụt
    ///   thì cho đi tiếp, đứng nguyên trọn một chu kỳ mới bỏ cuộc. Client chậm
    ///   mà vẫn tiến thì chờ bao lâu cũng được; client chết cứng thì vẫn có trần.
    ///   Và khi nó bỏ cuộc thì nó BÁO — xem `onDrainAbandoned`.
    /// - **Nán** (`lingerTimeout`): sau khi FIN của ta đã đi, ta chỉ còn chờ peer
    ///   đóng nốt chiều của nó. Hết hạn ở đây KHÔNG mất gì — byte của ta đã ra
    ///   hết socket — nên một hạn cố định là đủ.
    ///
    /// Ranh giới giữa hai giai đoạn là promise của `close(mode: .output, promise:)`:
    /// NIO chỉ hoàn tất nó SAU khi hàng đợi ghi sạch và `shutdown(how: .WR)` đã
    /// gọi. Truyền `nil` vào đó (bản trước) là vứt đúng tín hiệu phân biệt được
    /// hai giai đoạn, và đó là lý do bản trước gộp cả hai vào một hạn duy nhất.
    ///
    /// Channel đóng hẳn lúc peer đóng chiều của nó (EOF → NIO đóng hẳn vì
    /// `allowRemoteHalfClosure` mặc định là false), hoặc lúc hết hạn nán.
    ///
    /// Vẫn ràng buộc `Part == ByteBuffer` dù giờ không còn ghi gì: nửa-đóng
    /// chiều ra là ngữ nghĩa của TUNNEL. Với một channel HTTP thì nó sai — sau
    /// khi FIN đi rồi ta không còn nói được gì với client nữa, kể cả một lỗi.
    ///
    /// **KHÔNG được chạy trên một channel có `NIOSSLHandler`**, và kể từ Task 8
    /// điều đó được ép bằng một `precondition` ở dòng đầu chứ KHÔNG bằng ràng
    /// buộc `Part == ByteBuffer`. Vì sao ràng buộc kiểu không đủ, nói thẳng:
    /// `Part` là tham số PHANTOM — `GuardedPeer` chỉ giữ một `Channel`, không có
    /// gì buộc `Part` phải khớp kiểu message outbound của channel đó, và từ khi
    /// hàm này thôi ghi thì một `Part` sai còn chẳng hỏng lúc chạy. Chính
    /// codebase này đã có sẵn khuôn mẫu phá được nó:
    /// `ConnectTunnelHandler.handlerAdded` dựng `GuardedPeer<ByteBuffer>` cho
    /// channel client bằng một tham số kiểu tường minh, đúng để mở khoá hàm
    /// này. Ai làm y hệt vậy trên một channel MitM sẽ biên dịch được và chạy
    /// được.
    ///
    /// Thứ hàm này sẽ làm hỏng nếu chạy trên channel TLS:
    /// `NIOSSLHandler.closeOutput` đặt state `.outputClosed` của CHÍNH NÓ ngay ở
    /// ĐẦU thủ tục, và từ giây đó `bufferWrite` fail mọi write bằng
    /// `ChannelError.outputClosed` — với `promise: nil` là byte biến mất im
    /// lặng. `OutputLiveness` ngồi ở `.first`, tức DƯỚI tầng TLS, nên nó chỉ
    /// biết chuyện đó khi SOCKET nửa-đóng ở CUỐI thủ tục shutdown TLS; cả cửa sổ
    /// giữa hai mốc là mù, và cái watchdog xả bên dưới cũng mù theo.
    ///
    /// `precondition` chứ không phải ngả về đóng hẳn: đây là lỗi lập trình, chỉ
    /// tới được bằng một dòng code mới, không tới được bằng input từ xa (không
    /// có đường nào cho peer lắp `NIOSSLHandler` vào pipeline của một tunnel
    /// mù). Ngả về một hành vi "an toàn" nào đó chính là kiểu im lặng mà cả file
    /// này sinh ra để chặn.
    ///
    /// Ràng buộc `Part == ByteBuffer` vẫn giữ, nhưng chỉ vì lý do NGỮ NGHĨA nêu
    /// ở đoạn trên — nó không phải, và chưa bao giờ là, một phép kiểm.
    ///
    /// `onDrainAbandoned` KHÔNG có giá trị mặc định, cùng lý do với việc `write`
    /// không `@discardableResult`: bỏ cuộc giữa lúc xả là CẮT CỤT, và một lần
    /// cắt cụt không ai kể lại thì transaction vẫn hiện kết thúc sạch sẽ —
    /// đúng lớp bug cả file này sinh ra để chặn. Người gọi buộc phải nói ra nó
    /// báo cho ai. Tham số nhận số byte bị vứt (`bufferedWritableBytes` tại thời
    /// điểm bỏ cuộc); nó KHÔNG kể phần đã nằm trong send buffer của kernel mà
    /// RST làm bay theo, nên nó là cận DƯỚI của thiệt hại.
    func closeAfterPendingWrites(stallTimeout: TimeAmount = .seconds(15),
                                 lingerTimeout: TimeAmount = .seconds(15),
                                 onDrainAbandoned: @escaping (Int) -> Void) {
        let channel = self.channel
        // `precondition`, không phải `assert`: `markOutputClosed()` bên dưới là
        // lần ghi CHỦ ĐỘNG duy nhất vào `OutputLiveness.isOutputClosed`, tức
        // chính là chỗ mà cơ sở `@unchecked Sendable` của kiểu đó dựa vào. Một
        // `assert` (`debugOnly`) để hở đúng chỗ đó trong release.
        channel.eventLoop.preconditionInEventLoop()
        // Xem khối doc ở trên: ràng buộc `Part == ByteBuffer` là ngữ nghĩa, KHÔNG
        // phải phép kiểm (`Part` là phantom). Đây mới là phép kiểm.
        precondition(
            !channelHasTLSLayer(channel),
            "closeAfterPendingWrites không dùng được trên channel có NIOSSLHandler: "
            + "NIOSSLHandler.closeOutput vứt write im lặng trong suốt thủ tục shutdown TLS, "
            + "và OutputLiveness (ở .first, dưới tầng TLS) không thấy cửa sổ đó."
        )
        guard channel.isActive else {
            channel.close(promise: nil)
            return
        }
        guard !output.isOutputClosed else {
            // Đã có một lượt nửa-đóng cho channel này. KHÔNG được đóng cứng
            // chồng lên: lượt đầu có thể đang xả, và cắt ngang nó chính là cái
            // mất byte cả hàm này sinh ra để tránh.
            //
            // "Lượt đầu đã hẹn giờ nán nên không có gì bị bỏ dở" chỉ ĐÚNG khi cờ
            // được đặt bởi CHÍNH hàm này. Hai đường đặt cờ còn lại thì không hẹn
            // gì cả, và hôm nay cả hai đều không tới được đây với một channel còn
            // sống — nói cho chính xác thay vì phát biểu chung chung:
            //
            // - `OutputLiveness.attached` fallback (`isOutputClosed = true` khi
            //   `addHandler` ném): chỉ ném khi pipeline đã đóng, tức
            //   `channel.isActive == false` — guard ngay phía trên bắt trước và
            //   vẫn đóng hẳn channel.
            // - `ChannelEvent.outputClosed`: NIO chỉ bắn nó từ
            //   `close0(mode: .output)`, mà trên các channel tunnel (nơi duy nhất
            //   hàm này chạy được) `closeAfterPendingWrites` là chỗ DUY NHẤT gọi
            //   nửa-đóng. Nếu ai đó thêm một đường nửa-đóng khác, đường đó phải
            //   tự đặt hạn treo của nó — ở đây không có hạn nào.
            return
        }
        // Từ NGAY đây mọi `write` vào peer này trả `false` thay vì im lặng biến
        // mất — kể cả `write` gọi qua một giá trị `GuardedPeer` KHÁC đang bọc
        // cùng channel (xem `OutputLiveness`).
        output.markOutputClosed()

        let progress = DrainProgress()
        let abandonReport = NIOLoopBoundBox(onDrainAbandoned, eventLoop: channel.eventLoop)
        let stallWatchdog = channel.eventLoop.scheduleRepeatedTask(
            initialDelay: stallTimeout, delay: stallTimeout
        ) { task in
            // `syncOptions` hợp lệ ở đây: callback của scheduleRepeatedTask luôn
            // chạy trên event loop của chính channel này.
            //
            // Không đọc được số byte còn tồn thì không còn cách nào ràng buộc
            // giai đoạn xả, nên watchdog tự rút. Đường tới đây là channel đã
            // đóng hẳn (`getOption0` ném `ioOnClosedChannel`) — lúc đó không còn
            // gì để canh. Đường "channel còn sống mà option không hỗ trợ" thì
            // KHÔNG có với socket thật; test `stalledDrainIsCutAndReported` ghim
            // đúng nhánh còn lại, vì nếu nhánh này nuốt mọi tick thì trần chống
            // treo biến mất mà không test nào đỏ.
            guard let pending = (try? channel.syncOptions?.getOption(.bufferedWritableBytes)) ?? nil
            else {
                task.cancel()
                return
            }
            if pending == 0 || pending < progress.lastPending {
                progress.lastPending = pending
                return
            }
            task.cancel()
            // Đóng CỨNG giữa lúc xả: `close0(mode: .all)` gọi
            // `cancelWritesOnClose` (vứt `pendingWrites`), và vì chiều vào
            // thường còn dữ liệu chưa đọc thì kernel gửi RST, vứt luôn send
            // buffer. `pending` byte này KHÔNG tới nơi.
            //
            // Báo TRƯỚC khi đóng: đóng có thể chạy đồng bộ vào các đường dọn
            // dẹp khác, và ta muốn sự kiện này là thứ mô tả nguyên nhân.
            abandonReport.value(pending)
            channel.close(promise: nil)
        }

        let outputClosed = channel.eventLoop.makePromise(of: Void.self)
        outputClosed.futureResult.whenComplete { _ in
            stallWatchdog.cancel()
            // Từ đây trở đi hết hạn không mất gì nữa. `Scheduled.cancel()` sau
            // khi task đã chạy là an toàn: NIO ghi rõ cancel là best-effort, và
            // `_setValue` chỉ nhận giá trị đầu tiên (`if self._value == nil`).
            let linger = channel.eventLoop.scheduleTask(in: lingerTimeout) {
                channel.close(promise: nil)
            }
            channel.closeFuture.whenComplete { _ in linger.cancel() }
        }
        channel.close(mode: .output, promise: outputClosed)
    }
}

/// Số byte còn tồn ở lần kiểm trước của watchdog xả.
///
/// `@unchecked Sendable` có cơ sở chứ không phải để làm ngơ: nó CHỈ được đụng
/// bên trong callback của `scheduleRepeatedTask`, mà callback đó luôn chạy trên
/// đúng một event loop — của channel đang xả.
private final class DrainProgress: @unchecked Sendable {
    var lastPending = Int.max
}
