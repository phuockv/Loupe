import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import TrafficModel

/// Nhận request từ client, mở upstream, forward, và mở transaction.
///
/// `fixedTarget` nil nghĩa là plaintext: request tới ở absolute-form và ta
/// tự parse host từ URI. Khác nil nghĩa là đã đi qua MitM (Task 8): request
/// ở origin-form và host lấy từ dòng CONNECT.
final class HTTPProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct Target: Sendable {
        var host: String
        var port: Int
        var scheme: Scheme
    }

    /// Kết nối upstream đang mở, kèm target nó đang phục vụ.
    ///
    /// Bọc `Channel` thay vì giữ nó trần là CHỦ Ý: `channel` để `private`,
    /// nên bên trong `HTTPProxyHandler` không có cách nào lấy ra channel để
    /// ghi thẳng vào. Mọi `HTTPClientRequestPart` đi ra upstream buộc phải
    /// qua `write(_:flush:)` — chỗ DUY NHẤT giữ kiểm tra `isActive`, và
    /// trình biên dịch không cho đi vòng.
    ///
    /// Vì sao phải cứng tới mức đó: bug "ghi request part vào một channel
    /// không nhận được, byte biến mất im lặng, trong khi transaction ta ghi
    /// lại vẫn hiện đầy đủ" đã tái xuất BA lần ở ba đường khác nhau của
    /// đúng file này (cửa sổ đang connect; tái dùng kết nối; upstream chết
    /// giữa request). Vá đúng đường vừa tìm ra thì lần sau lòi ra đường kế
    /// tiếp, vì thứ giữ cho các chỗ ghi CÒN LẠI an toàn chỉ là một lập luận
    /// về thứ tự ("liveness vừa kiểm ở chỗ khác, giữa đó không có gì chạy")
    /// — mà `sink` là closure do người gọi truyền vào, và Task 7/8 còn gắn
    /// thêm handler vào pipeline này: cả hai đều có thể phá lập luận đó mà
    /// không sửa một dòng nào trong file này.
    struct UpstreamConnection {
        private let channel: Channel
        let target: Target

        init(channel: Channel, target: Target) {
            self.channel = channel
            self.target = target
        }

        var isActive: Bool { channel.isActive }

        func close() { channel.close(promise: nil) }

        /// Ghi một part ra upstream; trả `false` — và KHÔNG ghi gì — nếu
        /// channel đã chết. Cố ý KHÔNG `@discardableResult`: bỏ qua giá trị
        /// trả về chính là bỏ qua tín hiệu mà cả lớp bug này xoay quanh.
        func write(_ part: HTTPClientRequestPart, flush: Bool) -> Bool {
            guard channel.isActive else { return false }
            if flush {
                channel.writeAndFlush(NIOAny(part), promise: nil)
            } else {
                channel.write(NIOAny(part), promise: nil)
            }
            return true
        }
    }

    private let configuration: ProxyConfiguration
    private let sink: TrafficEventSink
    private let fixedTarget: Target?
    /// `internal` (không `private`) chỉ để test dựng được trạng thái cần
    /// kiểm: một `UpstreamHandler` dùng CHUNG `SessionState` với handler này
    /// mà không phải chạy connect thật (`ClientBootstrap` không chạy được
    /// trên `EmbeddedEventLoop`). Không có nơi nào khác trong ProxyCore đụng
    /// tới nó.
    let state = SessionState()

    /// Cùng lý do `internal` như `state`: test gắn thẳng một upstream stub
    /// vào đây để lái trực tiếp `isActive` — trạng thái "upstream đã chết mà
    /// ta chưa kịp biết" không dựng tất định được qua socket thật.
    var upstream: UpstreamConnection?
    private var collector: BodyCollector?

    /// LƯU Ý CHO TASK 7/8: handler này xử lý MỘT request tại một thời điểm
    /// trên một connection — không hỗ trợ HTTP/1.1 pipelining (nhiều request
    /// đang bay cùng lúc chưa nhận response). `pendingRequestID` chỉ theo
    /// dõi request HIỆN TẠI, không phải một hàng đợi.
    ///
    /// Id transaction đang nhận body ở phía CLIENT ngay lúc này — khác với
    /// `state.pendingIDs.first` (id cũ nhất đang chờ RESPONSE). Dưới HTTP/1.1
    /// pipelining hai id này có thể khác nhau (client gửi tiếp request 2
    /// trước khi response request 1 về); dùng đúng biến này để không gán
    /// nhầm body của request N vào transaction của request khác.
    private var pendingRequestID: UUID?

    /// `HTTPClientRequestPart` (body/end) tới trong lúc `connectUpstream`
    /// còn đang await async TCP connect (upstream vẫn `nil`). Không buffer
    /// thì `upstream?.write(...)` sẽ âm thầm no-op và request tới origin bị
    /// cụt — mà bản ghi transaction vẫn hiện đầy đủ, tức là proxy nói dối về
    /// những gì nó thực sự gửi. Đây là lưới an toàn phụ: hàng phòng thủ
    /// chính là tạm dừng đọc từ client (`pauseClientReads`) ngay khi bắt đầu
    /// connect, nên trong điều kiện bình thường buffer này hiếm khi phải
    /// giữ quá vài KB. Vẫn bị chặn bởi `maxInMemoryBodyBytes` phòng trường
    /// hợp nhiều phần đã tới trong CÙNG một lượt đọc trước khi kịp tạm dừng.
    private var pendingUpstreamParts: [HTTPClientRequestPart] = []
    private var pendingUpstreamBytes: Int = 0

    /// Request HIỆN TẠI không còn forward được nữa: phần body/end còn lại
    /// của nó phải bị nuốt, không ghi mà cũng KHÔNG buffer. Hai nguyên nhân:
    /// vượt giới hạn buffer trong lúc đang connect
    /// (`abortForUpstreamBufferOverflow`), hoặc upstream chết giữa lúc còn
    /// đang forward (`abandonRequestOnDeadUpstream`).
    ///
    /// Cũng dùng để nếu một connect còn đang bay sau đó vẫn thành công, ta
    /// đóng luôn channel vừa mở thay vì lưu vào `self.upstream` (không còn
    /// ai dùng nó). `handle(head:)` reset cờ này cho mỗi request mới.
    private var isUpstreamAborted = false

    /// Bật lên khi CLIENT đã ngắt kết nối (channelInactive) trong lúc một
    /// connect upstream vẫn còn đang bay. `self` vẫn sống được tới lúc đó vì
    /// closure `whenComplete`/`map` giữ nó qua `NIOLoopBoundBox` (thay cho
    /// `[weak self]` của brief — xem chú thích ở `handle`). Không có cờ này,
    /// nếu connect sau đó thành công, ta sẽ gửi tiếp request cho một client
    /// đã biến mất, và không ai còn đóng channel upstream đó nữa.
    private var isClientGone = false

    /// Đang tạm dừng đọc từ client (`autoRead = false`) trong lúc chờ
    /// connect upstream — xem `pauseClientReads`/`resumeClientReads`.
    private var isClientReadPaused = false

    init(configuration: ProxyConfiguration, sink: @escaping TrafficEventSink,
         fixedTarget: Target?) {
        self.configuration = configuration
        self.sink = sink
        self.fixedTarget = fixedTarget
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): handle(head: head, context: context)
        case .body(let buffer):
            collector?.append(Data(buffer.readableBytesView))
            forwardOrBuffer(.body(.byteBuffer(buffer)), byteCount: buffer.readableBytes,
                            flushImmediately: false, context: context)
        case .end(let trailers):
            finishRequestBody()
            forwardOrBuffer(.end(trailers), byteCount: 0,
                            flushImmediately: true, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        isClientGone = true
        upstream?.close()
        upstream = nil
        context.fireChannelInactive()
    }

    private func handle(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let target = resolveTarget(head: head) else {
            respond(channel: context.channel, status: .badRequest,
                    message: "proxy cần absolute-form URI, nhận được: \(head.uri)")
            return
        }
        let originForm = fixedTarget == nil
            ? (HeaderSanitizer.parseAbsoluteForm(head.uri)?.originForm ?? head.uri)
            : head.uri

        // Đóng upstream CŨ (nếu có, không tái dùng được cho target này)
        // TRƯỚC KHI enqueue transaction MỚI vào `state` dùng chung giữa
        // handler này và `UpstreamHandler`. Lý do phải làm TRƯỚC: đóng
        // channel kích hoạt UpstreamHandler CŨ chạy `channelInactive` ngay
        // trong cùng lượt sự kiện (cùng event loop), và `channelInactive`
        // rút HẾT mọi id đang chờ khỏi `state` — kể cả id transaction vừa
        // enqueue, nếu ta enqueue trước khi đóng. Đóng trước khi enqueue
        // nghĩa là lúc rút chạy, request MỚI chưa có mặt trong `state` để
        // bị rút nhầm thành ".failed" oan.
        let needsNewUpstream = !isUpstreamReusable(for: target)
        if needsNewUpstream {
            upstream?.close()
            upstream = nil
            pauseClientReads(context: context)
        }

        let transaction = makeTransaction(head: head, target: target, originForm: originForm)
        state.enqueue(transaction)
        sink(.started(transaction))

        // Request mới → chu kỳ forward mới: reset trạng thái buffer/abort
        // của request TRƯỚC (nếu có) trên connection này. `isClientGone`
        // KHÔNG reset ở đây — một khi client đã ngắt, nó ngắt vĩnh viễn cho
        // cả đời handler này.
        isUpstreamAborted = false
        pendingRequestID = transaction.id
        pendingUpstreamParts.removeAll()
        pendingUpstreamBytes = 0

        collector = BodyCollector(
            limit: configuration.maxInMemoryBodyBytes,
            spillDirectory: configuration.bodySpillDirectory
        )

        var forwarded = HTTPRequestHead(
            version: .http1_1, method: head.method, uri: originForm,
            headers: HeaderSanitizer.sanitize(head.headers)
        )
        if forwarded.headers.first(name: "Host") == nil {
            forwarded.headers.add(name: "Host", value: hostHeader(for: target))
        }
        // Fixée thành `let` trước khi vào closure @Sendable bên dưới: capture
        // một `var` bị coi là tham chiếu có thể đổi đồng thời, dù thực tế nó
        // không còn bị sửa sau điểm này.
        let forwardedHead = forwarded

        // `context` (ChannelHandlerContext) không phải Sendable và không được
        // capture qua ranh giới closure @Sendable của `whenComplete`; dùng
        // `clientChannel` (Sendable) cho mọi thao tác ghi/đáp xảy ra sau khi
        // upstream connect xong. `self` được bọc trong NIOLoopBoundBox vì
        // NIO yêu cầu closure truyền cho `whenComplete` phải @Sendable —
        // an toàn ở đây vì future này luôn hoàn tất trên cùng event loop
        // (xem `connectUpstream`). Đây cũng là lý do cần `isClientGone`:
        // capture mạnh (không phải `[weak self]` như brief gốc) nghĩa là
        // `self` luôn còn sống khi closure chạy, kể cả khi client đã ngắt.
        let clientChannel = context.channel
        let loopBoundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)

        connectUpstream(to: target, context: context).whenComplete { result in
            let this = loopBoundSelf.value
            guard !this.isUpstreamAborted, !this.isClientGone else {
                // Request đã bị huỷ (vượt giới hạn buffer) hoặc client đã
                // ngắt kết nối trước khi connect xong; nếu connect vừa
                // thành công thì channel đó đã bị đóng ngay trong `.map`
                // của connectUpstream. Không còn gì để làm ở đây.
                return
            }
            switch result {
            case .success:
                // Không nhận `Channel` từ future: kết nối vừa mở đã nằm
                // trong `this.upstream` (xem `connectUpstream`), và đó là
                // dạng DUY NHẤT có cổng ghi được canh gác. Cầm thêm một
                // tham chiếu channel trần ở đây là mở lại đúng lối tắt mà
                // `UpstreamConnection` sinh ra để bịt.
                this.handleUpstreamReady(forwardedHead: forwardedHead,
                                         clientChannel: clientChannel)
            case .failure(let error):
                this.discardPendingUpstreamWrites()
                this.resumeClientReads(channel: clientChannel)
                // Xoá đúng transaction này bằng id, không dùng state.dequeue()
                // (dequeue lấy id CŨ NHẤT đang chờ response — có thể là một
                // request khác đang pipelining, không phải request vừa fail).
                this.state.transactions.removeValue(forKey: transaction.id)
                this.state.pendingIDs.removeAll { $0 == transaction.id }
                this.pendingRequestID = nil
                this.collector = nil
                this.sink(.failed(id: transaction.id,
                                  message: "không nối được \(target.host):\(target.port) — \(error)",
                                  endedAt: Date()))
                this.respond(channel: clientChannel, status: .badGateway,
                             message: "không nối được upstream: \(error)")
            }
        }
    }

    /// Kết nối upstream hiện có (nếu có) còn dùng được cho `target` này
    /// không: cùng host:port:scheme và channel vẫn active. `false` bao gồm
    /// cả trường hợp chưa từng kết nối (`upstream == nil`). So cả `scheme`
    /// (không chỉ host:port): thiếu nó, `http://h:443` rồi `https://h:443`
    /// trên cùng client connection sẽ tái dùng nhầm một channel plaintext
    /// cho request lẽ ra cần TLS. Chưa có đường nào chạm được điều kiện này
    /// hôm nay (mỗi request tự chọn cổng mặc định theo scheme trừ khi client
    /// nêu cổng tường minh) và sẽ hết ý nghĩa khi Task 8 dùng `fixedTarget`
    /// cố định — nhưng đây đúng một điều kiện, và hàm đang được sửa sẵn.
    private func isUpstreamReusable(for target: Target) -> Bool {
        guard let upstream else { return false }
        return upstream.target.host == target.host
            && upstream.target.port == target.port
            && upstream.target.scheme == target.scheme
            && upstream.isActive
    }

    /// Upstream vừa connect xong (lần đầu hoặc dùng lại kết nối cũ): mở lại
    /// việc đọc từ client (đã tạm dừng lúc bắt đầu connect — xem
    /// `pauseClientReads`), gửi head rồi phát lại đúng thứ tự mọi phần
    /// body/end đã phải buffer trong lúc còn chờ connect.
    private func handleUpstreamReady(forwardedHead: HTTPRequestHead,
                                     clientChannel: Channel) {
        resumeClientReads(channel: clientChannel)
        // Head và mọi part đã buffer đi qua ĐÚNG cổng ghi mà body/end tới
        // sau dùng (`writeUpstream`), không có lối tắt "liveness vừa được
        // kiểm ở `isUpstreamReusable` / connect vừa xong nên khỏi kiểm lại".
        // Giữa lần kiểm đó và lúc ghi ở đây đã có ít nhất một closure của
        // người gọi chạy xen vào (`sink(.started)`).
        let replay = pendingUpstreamParts
        discardPendingUpstreamWrites()
        guard writeUpstream(.head(forwardedHead), flush: replay.isEmpty) else { return }
        for (index, part) in replay.enumerated() {
            guard writeUpstream(part, flush: index == replay.count - 1) else { return }
        }
    }

    /// Gửi thẳng tới upstream nếu đã kết nối xong VÀ còn sống; nếu chưa kết
    /// nối (còn đang async connect) thì xếp hàng đợi, giới hạn bởi
    /// `maxInMemoryBodyBytes` — vượt giới hạn thì huỷ transaction và trả 502
    /// thay vì âm thầm cắt bớt. Với backpressure (`pauseClientReads`) đã bật
    /// ngay khi bắt đầu connect, nhánh vượt giới hạn này chỉ còn là lưới an
    /// toàn hiếm khi chạm tới.
    private func forwardOrBuffer(_ part: HTTPClientRequestPart, byteCount: Int,
                                 flushImmediately: Bool, context: ChannelHandlerContext) {
        // Request này đã bỏ dở (upstream chết, hoặc vượt cap buffer): nuốt
        // phần còn lại — không ghi, và cũng KHÔNG buffer.
        guard !isUpstreamAborted else { return }
        guard upstream == nil else {
            // Đã có upstream: ghi qua đúng một cổng. Nếu nó đã chết,
            // `writeUpstream` tự bỏ nốt request (không ghi gì cả).
            writeUpstream(part, flush: flushImmediately)
            return
        }
        guard pendingUpstreamBytes + byteCount <= configuration.maxInMemoryBodyBytes else {
            abortForUpstreamBufferOverflow(context: context)
            return
        }
        pendingUpstreamBytes += byteCount
        pendingUpstreamParts.append(part)
    }

    /// Cổng DUY NHẤT để một `HTTPClientRequestPart` đi ra upstream. Cả head
    /// (`handleUpstreamReady`) lẫn body/end (`forwardOrBuffer`) đều qua đây;
    /// `UpstreamConnection` giấu `Channel` nên không có đường nào khác.
    ///
    /// Trả `false` khi part KHÔNG được gửi: chưa có upstream, hoặc upstream
    /// đã chết (khi đó phần còn lại của request bị bỏ — xem
    /// `abandonRequestOnDeadUpstream`).
    @discardableResult
    private func writeUpstream(_ part: HTTPClientRequestPart, flush: Bool) -> Bool {
        guard let upstream else { return false }
        guard upstream.write(part, flush: flush) else {
            abandonRequestOnDeadUpstream()
            return false
        }
        return true
    }

    /// Upstream chết giữa lúc ta còn đang forward request tới nó (origin
    /// crash, RST, idle timeout, hoặc origin trả lời sớm rồi đóng trong khi
    /// client vẫn đang upload).
    ///
    /// KHÔNG phát `.failed` và KHÔNG trả lời client ở đây:
    /// `UpstreamHandler.channelInactive` đã xử lý xong toàn bộ phần nhìn
    /// thấy được từ bên ngoài (rút transaction khỏi `state`, phát `.failed`,
    /// trả 502 hoặc đóng client) TRƯỚC KHI ta có thể thấy `isActive == false`
    /// — NIO chuyển `isActive` và bắn `channelInactive` trong CÙNG một lệnh
    /// gọi đồng bộ `close0`, không nhường control giữa chừng (xem chú thích
    /// ở `UpstreamHandler.channelInactive`).
    ///
    /// `isUpstreamAborted = true` là phần bắt buộc, không phải cho gọn: chỉ
    /// nil hoá `upstream` thì phần body còn lại của CHÍNH request này rơi
    /// xuống nhánh buffer của `forwardOrBuffer` (nhánh đó hiểu
    /// `upstream == nil` là "đang connect") — tức quay lại đúng kiểu âm thầm
    /// giữ byte mà nhánh này sinh ra để chặn, chỉ chậm hơn một lần gọi. Tệ
    /// hơn: nếu phần còn lại vượt cap, `abortForUpstreamBufferOverflow` sẽ
    /// bắn một response 502 THỨ HAI xuống một client có khi vừa nhận đủ
    /// response đầu tiên.
    private func abandonRequestOnDeadUpstream() {
        isUpstreamAborted = true
        discardPendingUpstreamWrites()
        pendingRequestID = nil
        collector = nil
        upstream = nil
    }

    /// Request body vượt quá giới hạn buffer trong khi upstream còn đang
    /// connect: không có chỗ nào an toàn để giữ thêm byte (không rơi vào RAM
    /// vô hạn, không được âm thầm cắt bớt), nên huỷ transaction và báo lỗi.
    private func abortForUpstreamBufferOverflow(context: ChannelHandlerContext) {
        guard !isUpstreamAborted else { return }
        isUpstreamAborted = true
        discardPendingUpstreamWrites()
        // Mở lại đọc trước khi đóng: một channel đang tạm dừng đọc vẫn đóng
        // được, nhưng mở lại cho rõ ràng và để read() còn dang dở (nếu có)
        // không kẹt handler ở trạng thái "đang chờ" vĩnh viễn.
        resumeClientReads(channel: context.channel)
        if let id = pendingRequestID,
           let failedTransaction = state.transactions.removeValue(forKey: id) {
            state.pendingIDs.removeAll { $0 == id }
            sink(.failed(id: failedTransaction.id,
                         message: "request body vượt quá giới hạn buffer trong lúc đang kết nối upstream",
                         endedAt: Date()))
        }
        pendingRequestID = nil
        collector = nil
        respond(channel: context.channel, status: .badGateway,
                message: "request body exceeded buffer size while connecting to upstream")
    }

    private func discardPendingUpstreamWrites() {
        pendingUpstreamParts.removeAll()
        pendingUpstreamBytes = 0
    }

    /// Tạm dừng đọc thêm từ client trong lúc connect upstream còn đang chạy.
    /// Đây là hàng phòng thủ CHÍNH cho việc "client bơm nhanh hơn connect
    /// xong" — không phải `pendingUpstreamParts`/`maxInMemoryBodyBytes`, vốn
    /// chỉ là lưới an toàn phụ (bị giới hạn bởi `maxMessagesPerRead`/kích
    /// thước recv-buffer của MỘT lượt đọc, không phải kích thước cap).
    /// `autoRead = false` chỉ chặn được LẦN `read()` TIẾP THEO — không tránh
    /// khỏi việc một phần dữ liệu đã kịp giải mã trong lượt đọc đầu tiên
    /// (cùng với `.head`) vẫn phải rơi vào buffer phụ đó.
    private func pauseClientReads(context: ChannelHandlerContext) {
        guard !isClientReadPaused else { return }
        isClientReadPaused = true
        try? context.channel.syncOptions?.setOption(ChannelOptions.autoRead, value: false)
    }

    /// Mở lại đọc từ client sau khi connect xong (thành công, thất bại, hay
    /// bị huỷ vì vượt buffer). NIO không tự đọc lại chỉ vì `autoRead` được
    /// bật lại — phải gọi `read()` tường minh để thực sự nối lại việc đọc.
    private func resumeClientReads(channel: Channel) {
        guard isClientReadPaused else { return }
        isClientReadPaused = false
        try? channel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
        channel.read()
    }

    private func resolveTarget(head: HTTPRequestHead) -> Target? {
        if let fixedTarget { return fixedTarget }
        guard let parsed = HeaderSanitizer.parseAbsoluteForm(head.uri) else { return nil }
        return Target(host: parsed.host, port: parsed.port, scheme: parsed.scheme)
    }

    private func makeTransaction(head: HTTPRequestHead, target: Target,
                                 originForm: String) -> Transaction {
        let absolute = "\(target.scheme.rawValue)://\(hostHeader(for: target))\(originForm)"
        let url = URL(string: absolute) ?? URL(string: "\(target.scheme.rawValue)://\(target.host)/")!
        let request = RequestModel(
            method: head.method.rawValue,
            url: url,
            httpVersion: "HTTP/\(head.version.major).\(head.version.minor)",
            headers: head.headers.map { (name: $0.name, value: $0.value) }
        )
        return Transaction(scheme: target.scheme, host: target.host,
                           port: target.port, request: request)
    }

    private func hostHeader(for target: Target) -> String {
        let isDefaultPort = (target.scheme == .http && target.port == 80)
            || (target.scheme == .https && target.port == 443)
        return isDefaultPort ? target.host : "\(target.host):\(target.port)"
    }

    private func finishRequestBody() {
        // `pendingRequestID`, không phải `state.pendingIDs.first`: id "cũ
        // nhất đang chờ response" và id "request đang nhận body ở đây ngay
        // bây giờ" là hai thứ khác nhau dưới HTTP/1.1 pipelining (client gửi
        // request 2 trước khi response request 1 về) — dùng nhầm cái đầu sẽ
        // gán body của request 2 vào transaction của request 1.
        guard let collector, let id = pendingRequestID else { return }
        let body = collector.finish()
        self.collector = nil
        self.pendingRequestID = nil
        // Transaction có thể đã bị UpstreamHandler đánh `.failed` và rút
        // khỏi `state` (upstream chết giữa lúc body này còn đang forward)
        // trước khi ta kịp chạy tới đây — đừng phát `.requestBody` cho một
        // transaction đã hỏng, và đừng ghi body vào một entry không còn tồn
        // tại (optional chaining bên dưới vốn đã an toàn, nhưng sink thì
        // không nên chạy).
        guard state.transactions[id] != nil else { return }
        state.transactions[id]?.request.body = body
        sink(.requestBody(id: id, body))
    }

    /// Trả `EventLoopFuture<Void>`, KHÔNG phải `<Channel>`: kết quả của hàm
    /// này là "self.upstream đã sẵn sàng", chứ không phải một `Channel` trần
    /// để nơi khác cầm mà ghi vào (xem `UpstreamConnection`). Channel trần
    /// chỉ tồn tại trong đúng closure `.map` bên dưới, vừa đủ để bọc lại.
    private func connectUpstream(to target: Target,
                                 context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        // `handle(head:)` đã quyết định TRƯỚC khi gọi hàm này: nếu upstream
        // hiện có không tái dùng được, nó đã đóng và nil hoá `upstream` rồi.
        // Nên ở đây chỉ còn hai khả năng: `upstream` vẫn còn (tái dùng được)
        // hoặc `nil` (phải mở kết nối mới) — không cần kiểm tra/đóng lại.
        if upstream != nil {
            return context.eventLoop.makeSucceededVoidFuture()
        }

        let clientChannel = context.channel
        let configuration = self.configuration
        let sink = self.sink
        // `state` (SessionState) chủ ý không Sendable (xem chú thích trong
        // SessionState.swift), nhưng `channelInitializer` của NIO yêu cầu
        // closure @Sendable. Bọc bằng NIOLoopBoundBox: an toàn vì bootstrap
        // dùng `group: context.eventLoop` nên closure này chạy đúng trên
        // event loop mà `state` đang sống.
        let loopBoundState = NIOLoopBoundBox(state, eventLoop: context.eventLoop)

        // Ghim upstream vào ĐÚNG event loop của client channel. Đây là điều
        // kiện để SessionState không cần khoá — xem chú thích trong SessionState.
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    if target.scheme == .https {
                        var tls = TLSConfiguration.makeClientConfiguration()
                        tls.applicationProtocols = ["http/1.1"]
                        // KHÔNG BAO GIỜ tắt verify ở đây: tắt là biến app
                        // thành lỗ hổng thật cho mọi traffic đi qua nó.
                        let sslContext = try NIOSSLContext(configuration: tls)
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: sslContext, serverHostname: target.host)
                        )
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(
                        UpstreamHandler(clientChannel: clientChannel,
                                        configuration: configuration,
                                        sink: sink, state: loopBoundState.value)
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let loopBoundSelf = NIOLoopBoundBox(self, eventLoop: context.eventLoop)
        return bootstrap.connect(host: target.host, port: target.port)
            .map { channel -> Void in
                let this = loopBoundSelf.value
                let connection = UpstreamConnection(channel: channel, target: target)
                guard !this.isUpstreamAborted, !this.isClientGone else {
                    // Request đã bị huỷ (vượt giới hạn buffer) hoặc client
                    // đã ngắt kết nối trong lúc connect còn đang chạy: không
                    // còn ai dùng channel này — đóng luôn, đừng để rò rỉ một
                    // kết nối upstream không ai đóng.
                    connection.close()
                    return
                }
                this.upstream = connection
            }
    }

    private func respond(channel: Channel, status: HTTPResponseStatus,
                         message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
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
