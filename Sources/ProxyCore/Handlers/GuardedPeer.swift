import NIOCore

/// Một channel "phía bên kia" mà handler này ghi vào, với `Channel` bị giấu kín.
///
/// Đây là cơ chế canh gác DUY NHẤT cho mọi lần ghi ra một channel khác trong
/// đường proxy: `channel` để `private` nên không có cách nào lấy nó ra để ghi
/// thẳng, và `write(_:flush:)` — chỗ duy nhất ghi được — vừa giữ kiểm tra
/// `isActive` vừa trả về một `Bool` KHÔNG `@discardableResult`.
///
/// Vì sao phải cứng tới mức đó: bug "ghi vào một channel không nhận được, byte
/// biến mất im lặng, trong khi transaction ta ghi lại vẫn hiện đầy đủ" đã tái
/// xuất BỐN lần ở bốn đường khác nhau của đường HTTP plaintext. Ba lần đầu vá
/// đúng đường vừa tìm ra, và lần sau lại lòi ra đường kế tiếp, vì thứ giữ cho
/// các chỗ ghi CÒN LẠI an toàn chỉ là một lập luận về thứ tự. Lần thứ tư mới
/// làm nó thành cấu trúc: không handler nào giữ `Channel` trần nữa.
///
/// Với một proxy gỡ rối thì lớp bug này là tệ nhất có thể: công cụ nói dối về
/// thứ nó đã gửi.
///
/// Generic trên `Part` vì hai đường dùng hai kiểu message khác nhau —
/// `HTTPClientRequestPart` cho đường HTTP (xem `HTTPProxyHandler.UpstreamConnection`)
/// và `ByteBuffer` cho tunnel mù (xem `ConnectTunnelHandler`) — nhưng cái
/// guard thì chỉ có MỘT bản, ở đây.
struct GuardedPeer<Part> {
    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    var isActive: Bool { channel.isActive }

    func close() { channel.close(promise: nil) }

    /// Ghi một part ra peer; trả `false` — và KHÔNG ghi gì — nếu channel đã
    /// chết. Cố ý KHÔNG `@discardableResult`: bỏ qua giá trị trả về chính là
    /// bỏ qua tín hiệu mà cả lớp bug này xoay quanh.
    func write(_ part: Part, flush: Bool) -> Bool {
        guard channel.isActive else { return false }
        if flush {
            channel.writeAndFlush(NIOAny(part), promise: nil)
        } else {
            channel.write(NIOAny(part), promise: nil)
        }
        return true
    }
}
