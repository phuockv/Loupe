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
/// và ghi vào đó, compiler không phản đối. Ba bản `respond(channel:)` trong
/// `HTTPProxyHandler`/`ProxyEntryHandler` vẫn ghi thẳng — chúng ghi vào channel
/// của CHÍNH pipeline mình đang nằm trong, không phải một peer, nên nằm ngoài
/// hình dạng này; đã ghi nhận, chưa gộp vào đây.
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

    /// Ghi part CUỐI CÙNG rồi đóng channel khi chính lần ghi đó đã ra tới
    /// socket — không cắt cụt phần vừa ghi lẫn phần còn kẹt trước đó.
    ///
    /// Không trả tín hiệu vì không có gì để người gọi xử lý: channel đã chết
    /// thì nó không ghi gì và đóng luôn, đúng thứ người gọi định làm.
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
    /// Đóng SAU KHI mọi byte đã ghi ra hết socket. Dùng cho hai đầu tunnel: khi
    /// một chiều chết, phần đuôi đã nhận được của chiều kia vẫn phải tới nơi.
    ///
    /// Không có việc này thì mọi lần tải file lớn qua host bypass đều có nguy
    /// cơ mất đuôi: origin ghi nhanh hơn client đọc, origin đóng, và
    /// `channelInactive` đóng luôn phía client trong khi `pendingWrites` còn
    /// đầy — im lặng, và transaction `.tunnelled` không hiện gì bất thường.
    ///
    /// Cách làm là idiom của NIO: xếp thêm một lần ghi RỖNG có promise. Promise
    /// trong `PendingStreamWritesState` hoàn tất theo đúng thứ tự FIFO khi byte
    /// thoát ra socket (`didWrite` coi mục 0 byte ở đầu hàng là đã ghi xong),
    /// nên promise của mục rỗng cuối hàng chỉ nổ sau khi mọi byte trước nó đã đi.
    ///
    /// Đánh đổi: nếu peer còn sống mà KHÔNG BAO GIỜ đọc, lần ghi đó không bao
    /// giờ xong và channel không bao giờ đóng. Đó là hành vi đúng của một tunnel
    /// (ta còn nợ peer số byte đó) và bị chặn trên bởi kích thước buffer socket,
    /// nhưng nó không có timeout.
    func closeAfterPendingWrites() {
        let channel = self.channel
        guard channel.isActive else {
            channel.close(promise: nil)
            return
        }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
        channel.writeAndFlush(channel.allocator.buffer(capacity: 0), promise: promise)
    }
}
