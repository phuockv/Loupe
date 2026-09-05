import NIOCore

/// Một channel "phía bên kia" mà handler này ghi vào, với `Channel` bị giấu kín.
///
/// Đây là bản cài đặt DUY NHẤT của phép kiểm liveness trước khi ghi: `channel`
/// để `private` nên không có cách nào lấy nó ra để ghi thẳng, và
/// `write(_:flush:)` — chỗ duy nhất ghi được — vừa giữ kiểm tra `isActive` vừa
/// trả về một `Bool` KHÔNG `@discardableResult`.
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

    init(channel: Channel) {
        self.channel = channel
    }

    var isActive: Bool { channel.isActive }

    /// Dùng để dựng `ByteBuffer` cho peer này. Không phải lối thoát: allocator
    /// không ghi được gì.
    var allocator: ByteBufferAllocator { channel.allocator }

    /// Ghi một part ra peer; trả `false` — và KHÔNG ghi gì — nếu channel đã
    /// chết. Cố ý KHÔNG `@discardableResult`: bỏ qua giá trị trả về chính là
    /// bỏ qua tín hiệu mà cả lớp bug này xoay quanh.
    ///
    /// `promise: nil` là chủ ý cho đường nóng (một promise cho mỗi gói tin
    /// relay là một cấp phát cho mỗi gói tin), nhưng nó có một hệ quả PHẢI
    /// biết: `flush` chỉ là yêu cầu, byte có thể còn nằm trong `pendingWrites`
    /// nếu send buffer của socket đã đầy. Vì thế "ghi xong rồi đóng" phải dùng
    /// `writeThenClose` hoặc `closeAfterPendingWrites`, KHÔNG phải
    /// `closeDiscardingPendingWrites`.
    func write(_ part: Part, flush: Bool) -> Bool {
        guard channel.isActive else { return false }
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
        guard channel.isActive else {
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
    /// — im lặng, và transaction `.tunnelled` không hiện gì bất thường.
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
    ///   chiều vào" chính là ca ta đang xử lý: client vẫn đang gửi. Đo được:
    ///   promise xả báo `success()` xong client vẫn chỉ nhận 701 KB trên 8 MiB.
    ///   `shutdown(how: .WR)` gửi FIN, không đụng gì tới dữ liệu đang chờ.
    ///
    /// Channel đóng hẳn lúc peer đóng chiều của nó (EOF → NIO đóng hẳn vì
    /// `allowRemoteHalfClosure` mặc định là false), hoặc lúc hết `timeout` —
    /// chặn trên để một peer không bao giờ đóng cũng không giữ channel mãi mãi.
    ///
    /// Vẫn ràng buộc `Part == ByteBuffer` dù giờ không còn ghi gì: nửa-đóng
    /// chiều ra là ngữ nghĩa của TUNNEL. Với một channel HTTP thì nó sai — sau
    /// khi FIN đi rồi ta không còn nói được gì với client nữa, kể cả một lỗi.
    func closeAfterPendingWrites(within timeout: TimeAmount = .seconds(15)) {
        let channel = self.channel
        guard channel.isActive else {
            channel.close(promise: nil)
            return
        }
        // Hạn chót cho TOÀN BỘ việc dọn dẹp, không riêng phần xả: sau nửa-đóng
        // ta còn chờ peer đóng nốt chiều của nó. Huỷ khi channel đóng hẳn để
        // không giữ một task treo lơ lửng cho mỗi lần dọn tunnel.
        // `Scheduled.cancel()` sau khi task đã chạy là an toàn: NIO ghi rõ cancel
        // là best-effort, và `_setValue` chỉ nhận giá trị đầu tiên
        // (`if self._value == nil`), không precondition.
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        channel.closeFuture.whenComplete { _ in deadline.cancel() }
        channel.close(mode: .output, promise: nil)
    }
}
