import SwiftUI
import TrafficModel

/// Tab Request/Response cho transaction đang được chọn trong bảng.
///
/// Quyết định hiện gì ở tab Response nằm trong `ResponsePresentation`
/// (bên dưới), KHÔNG nằm rải rác trong `body` — xem doc comment của nó để
/// biết vì sao thứ tự ưu tiên trong đó (isTunnelled → response → failed →
/// pending) là phần quan trọng nhất của cả file này, và vì sao review vòng 1
/// tìm ra chỗ cùng một lớp lỗi (giấu mất `.failed`) còn sót lại ở đường
/// không-tunnelled sau khi override 1 chỉ sửa đường tunnelled.
public struct InspectorView: View {
    /// Đọc một header không phân biệt hoa thường. Headers được lưu dạng mảng
    /// cặp (HTTP cho phép lặp), nên không tra được bằng subscript.
    static func header(_ name: String, in headers: [(name: String, value: String)]) -> String? {
        headers.last { $0.name.lowercased() == name.lowercased() }?.value
    }

    let transaction: TrafficModel.Transaction
    @State private var selectedTab: Tab = .request

    private enum Tab: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"
        var id: String { rawValue }
    }

    public init(transaction: TrafficModel.Transaction) {
        self.transaction = transaction
    }

    public var body: some View {
        // KHÔNG dùng `TabView`/`.tabItem`: chạy thật (Accessibility Inspector
        // qua `System Events`, xem task report) cho thấy trong ngữ cảnh này —
        // `TabView` nằm trong `detail:` của `NavigationSplitView` — nó KHÔNG
        // vẽ thanh chuyển tab nào cả, chỉ hiện mãi nội dung tab đầu tiên và
        // không có cách nào bấm sang tab còn lại, kể cả qua accessibility.
        // Một `Picker` kiểu segmented tự quản lý bằng `@State` tránh hẳn sự
        // mập mờ đó và chắc chắn bấm được.
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .padding(.bottom, 4)

            switch selectedTab {
            case .request: requestTab
            case .response: responseTab
            }
        }
    }

    private var requestTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("URL", value: transaction.request.url.absoluteString)
                LabeledContent("Method", value: transaction.request.method)
                LabeledContent("HTTP", value: transaction.request.httpVersion)

                if !transaction.request.queryItems.isEmpty {
                    InspectorSection("Query Parameters") {
                        KeyValueTable(pairs: transaction.request.queryItems.map {
                            (name: $0.name, value: $0.value ?? "")
                        })
                    }
                }
                InspectorSection("Headers") {
                    KeyValueTable(pairs: transaction.request.headers)
                }
                InspectorSection("Body") {
                    BodyView(payload: transaction.request.body,
                             contentEncoding: Self.header("Content-Encoding", in: transaction.request.headers))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var responseTab: some View {
        let presentation = ResponsePresentation(
            isTunnelled: transaction.isTunnelled,
            state: transaction.state,
            response: transaction.response
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch presentation.kind {
                case .tunnelled:
                    tunnelledUnavailable(failureReason: presentation.failureReason)

                case .response(let statusCode, let reasonPhrase):
                    if let response = transaction.response {
                        LabeledContent("Status", value: "\(statusCode) \(reasonPhrase)")
                        if let reason = presentation.failureReason {
                            partialResponseFailureNotice(reason)
                        }
                        InspectorSection("Headers") { KeyValueTable(pairs: response.headers) }
                        InspectorSection("Body") {
                            BodyView(payload: response.body,
                                     contentEncoding: Self.header("Content-Encoding", in: response.headers))
                        }
                    }

                case .failed:
                    if let reason = presentation.failureReason {
                        failedUnavailable(reason: reason)
                    }

                case .pending:
                    ProgressView("Đang chờ response")
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    /// Host nằm trong bypass list: PHẢI nói rõ ngay, không đợi người dùng tự
    /// suy ra từ một body rỗng. Nếu tunnel relay cũng `.failed` (chứ không chỉ
    /// "không giải mã"), `failureReason` khác nil và hiện thêm lý do đó bên
    /// dưới — mất thông tin đó cũng tệ không kém việc giấu sự thật "chưa từng
    /// giải mã".
    @ViewBuilder
    private func tunnelledUnavailable(failureReason: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Không giải mã", systemImage: "lock.slash")
                .font(.title3.bold())
            Text("""
            \(transaction.host) nằm trong bypass list. Proxy chỉ relay byte thô \
            hai chiều cho kết nối này, không bao giờ đọc hay giải mã nội dung TLS \
            bên trong — kể cả khi trạng thái bên cạnh là "completed": tunnel đóng \
            sạch không có nghĩa nội dung từng được đọc. Không có request/response \
            thật nào để hiện ở tab này.
            """)
            .foregroundStyle(.secondary)

            if let failureReason {
                Divider()
                Text("Tunnel relay cũng thất bại:").font(.subheadline).bold()
                failureReasonText(failureReason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "thất bại" trung tính, không phải "lỗi": client bỏ preconnect trước khi
    /// tunnel dựng xong cũng đi qua đường này và là kết cục bình thường — xem
    /// doc comment ở `ConnectTunnelHandler`/`ProxyEntryHandler`. Toàn bộ
    /// message hiện ra, chọn được: đây thường là dòng chữ hữu ích nhất trong
    /// app khi nó là gợi ý cert pinning, xem
    /// `MITMUpgradeHandler.handshakeFailureMessage`.
    @ViewBuilder
    private func failedUnavailable(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Request thất bại", systemImage: "exclamationmark.triangle")
                .font(.title3.bold())
                .foregroundStyle(.orange)
            failureReasonText(reason)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Review vòng 1: `UpstreamHandler` phát `.responseHead` (header thật,
    /// `body: .none`) ngay khi origin trả xong header, TRƯỚC khi body tải
    /// xong; nếu origin đóng kết nối giữa chừng sau đó, `.failed` phát ra mà
    /// KHÔNG đụng tới `response` đã ghi. Kết quả: `response != nil` VÀ
    /// `state == .failed` cùng lúc, y hệt lớp lỗi override 1 sửa cho đường
    /// tunnelled nhưng chừa lại ở đây. Notice này hiện NGAY TRÊN header/body
    /// thật, không thay thế chúng: response một phần cộng lý do thất bại hữu
    /// ích hơn hẳn chỉ một trong hai.
    @ViewBuilder
    private func partialResponseFailureNotice(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Response chưa hoàn tất", systemImage: "exclamationmark.triangle")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            failureReasonText(reason)
        }
    }

    private func failureReasonText(_ reason: String) -> some View {
        Text(reason)
            .font(.system(.body, design: .monospaced))
    }
}

/// Suy diễn thuần logic những gì tab Response cần hiển thị, tách khỏi
/// SwiftUI để test được không cần dựng view thật — cùng cách
/// `StatusPresentation` (`ContentView.swift`) làm cho `StatusCell`.
///
/// Thứ tự ưu tiên, ĐÚNG THEO THỨ TỰ:
/// 1. `isTunnelled` → `.tunnelled`. Một CONNECT bị bypass vẫn phát `.completed`
///    kèm response tổng hợp ("200 Connection Established") khi tunnel đóng
///    sạch — response đó tả cái proxy trả lời CHO LỆNH CONNECT, không phải
///    cho bất kỳ request nào chạy BÊN TRONG tunnel, vì proxy không đọc được
///    những request đó (xem `ConnectEstablished`/`ProxyEntryHandler` ở
///    `ProxyCore`). Ưu tiên `response` trước sẽ hiện "200, body rỗng,
///    completed" như thể server không trả gì.
/// 2. `response != nil` → `.response`. QUAN TRỌNG: xét TRƯỚC `state == .failed`.
///    `UpstreamHandler` phát `.responseHead` (header thật, `body: .none`)
///    ngay khi origin trả xong dòng đầu, trước khi body tải xong; nếu origin
///    chết giữa chừng sau đó, `.failed` phát ra mà không đụng tới `response`
///    đã ghi — nghĩa là `response != nil` VÀ `state == .failed` có thể cùng
///    đúng cho một request bình thường, không chỉ cho tunnel. Xét
///    `state == .failed` trước ở đây sẽ giấu mất response thật đã nhận được;
///    ngược lại xét `response` trước mà bỏ qua `failureReason` sẽ giấu mất
///    sự thật request đã thất bại — nên `failureReason` được tính ĐỘC LẬP và
///    lộ ra CÙNG với `.response`, không đánh đổi cái này lấy cái kia.
/// 3. Còn `state == .failed` mà không có response → `.failed`.
/// 4. Còn lại → `.pending`.
struct ResponsePresentation: Equatable {
    enum Kind: Equatable {
        case tunnelled
        case response(statusCode: Int, reasonPhrase: String)
        case failed
        case pending
    }

    let kind: Kind
    /// Lý do thất bại nếu `state == .failed`, tính ĐỘC LẬP với `kind` — có
    /// thể khác nil dù `kind` là `.tunnelled` (tunnel relay hỏng) hay
    /// `.response` (response một phần rồi origin chết) chứ không chỉ khi
    /// `kind == .failed`.
    let failureReason: String?

    init(isTunnelled: Bool, state: TransactionState, response: ResponseModel?) {
        if case .failed(let reason) = state {
            failureReason = reason
        } else {
            failureReason = nil
        }

        if isTunnelled {
            kind = .tunnelled
        } else if let response {
            kind = .response(statusCode: response.statusCode, reasonPhrase: response.reasonPhrase)
        } else if failureReason != nil {
            kind = .failed
        } else {
            kind = .pending
        }
    }
}

/// Tiêu đề + nội dung, không phụ thuộc `Section` hiểu ngữ cảnh `List`/`Form`
/// để vẽ header — ở đây `Section` nằm thẳng trong `VStack`, nơi việc nó có tự
/// vẽ tiêu đề hay không tuỳ phiên bản SwiftUI. Một `Text` tường minh luôn
/// hiện, bất kể container ngoài là gì.
private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct KeyValueTable: View {
    let pairs: [(name: String, value: String)]

    var body: some View {
        if pairs.isEmpty {
            Text("(không có)").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top) {
                        Text(pair.name).bold().frame(width: 180, alignment: .leading)
                        Text(pair.value)
                    }
                    .font(.system(.body, design: .monospaced))
                }
            }
        }
    }
}

/// Hiện `BodyPayload`, phân biệt rõ bốn case — xem doc comment của
/// `BodyPayload` trong `TrafficModel/Models.swift`. `.file` KHÔNG nạp nội
/// dung file vào view: làm vậy dựng lại đúng vấn đề RAM mà việc spill ra đĩa
/// sinh ra để tránh. `.truncated` phải nói rõ đây không phải toàn bộ body —
/// im lặng ở đây khiến người xem tưởng nhầm phần đầu là tất cả.
/// Cách hiển thị một body đọc được.
enum BodyDisplayMode: String, CaseIterable, Identifiable {
    /// JSON in đẹp — mặc định khi body là JSON, vì mở response ra là để ĐỌC.
    case json = "JSON"
    /// Đúng byte nhận được, không sắp xếp lại gì. Cần khi thứ tự khoá quan
    /// trọng, hoặc khi body không phải JSON.
    case raw = "Thô"
    /// Cây thu gọn — hữu ích với cấu trúc lớn, vô dụng làm mặc định.
    case tree = "Cây"
    var id: String { rawValue }
}

private struct BodyView: View {
    let payload: BodyPayload
    /// Giá trị header `Content-Encoding` của chính phía này (request hoặc
    /// response). `nil` nghĩa là không khai báo nén.
    var contentEncoding: String? = nil

    @State private var mode: BodyDisplayMode?

    var body: some View {
        switch payload {
        case .none:
            Text("Không có body").foregroundStyle(.secondary)

        case .inMemory(let data):
            content(for: data)

        case .file(let url, let total):
            VStack(alignment: .leading, spacing: 4) {
                Text("""
                Body \(byteCount(total)) đã lưu ra đĩa thay vì giữ trong RAM (vượt \
                ngưỡng spill). Không nạp lại vào view để tránh đúng vấn đề RAM mà \
                việc spill này sinh ra để tránh — mở file dưới đây bằng công cụ \
                khác để xem nội dung.
                """)
                .foregroundStyle(.secondary)
                Text(url.path)
                    .font(.system(.body, design: .monospaced))
            }

        case .truncated(let data, let total):
            VStack(alignment: .leading, spacing: 8) {
                Text("""
                Chỉ còn giữ được \(byteCount(data.count)) trong tổng \
                \(byteCount(total)) — ghi xuống đĩa thất bại giữa chừng nên phần \
                còn lại đã mất vĩnh viễn. Đây KHÔNG phải toàn bộ body.
                """)
                .foregroundStyle(.orange)
                if data.isEmpty {
                    Text("Không còn byte nào để hiện.").foregroundStyle(.secondary)
                } else {
                    content(for: data)
                }
            }
        }
    }

    /// Giải nén trước khi quyết định hiển thị thế nào, và nói rõ đã giải nén.
    @ViewBuilder
    private func content(for data: Data) -> some View {
        switch BodyDecoder.decode(data, contentEncoding: contentEncoding) {
        case .identity(let raw):
            rendered(raw)

        case .decompressed(let out, let encoding, let wire, let truncated):
            VStack(alignment: .leading, spacing: 6) {
                Text(truncated
                     ? "Đã giải nén từ \(encoding): \(bytes(wire)) trên dây → cắt ở \(bytes(out.count)) (quá lớn)"
                     : "Đã giải nén từ \(encoding): \(bytes(wire)) trên dây → \(bytes(out.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                rendered(out)
            }

        case .unsupported(let encoding, let count):
            VStack(alignment: .leading, spacing: 6) {
                Text("Body nén bằng \(encoding) (\(bytes(count))) — chưa giải nén được.")
                    .foregroundStyle(.orange)
                Text("Compression framework của hệ thống chỉ có gzip và deflate. "
                     + "Bật \"Ép server không nén\" ở thanh dưới rồi gửi lại request để xem nội dung.")
                    .font(.caption).foregroundStyle(.secondary)
                hex(data)
            }

        case .failed(let encoding, let count):
            VStack(alignment: .leading, spacing: 6) {
                Text("Khai báo \(encoding) nhưng giải nén thất bại (\(bytes(count))). "
                     + "Body có thể hỏng, hoặc server khai sai.")
                    .foregroundStyle(.orange)
                hex(data)
            }
        }
    }

    /// Hiển thị dữ liệu đã ở dạng cuối: JSON → cây, text → nguyên văn,
    /// còn lại → hex dump thay vì một câu từ chối.
    @ViewBuilder
    private func rendered(_ data: Data) -> some View {
        let pretty = JSONNode.prettyPrinted(data)
        let text = String(data: data, encoding: .utf8)
        // Mặc định: JSON in đẹp nếu parse được, không thì văn bản thô. Cây
        // KHÔNG bao giờ là mặc định — thu gọn hết thì nó không cho biết gì.
        let current = mode ?? (pretty != nil ? .json : .raw)

        if pretty != nil || text != nil {
            VStack(alignment: .leading, spacing: 8) {
                if pretty != nil {
                    Picker("", selection: Binding(
                        get: { current }, set: { mode = $0 })) {
                        ForEach(BodyDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                switch current {
                case .json:
                    Text(pretty ?? text ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                case .raw:
                    Text(text ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                case .tree:
                    if let children = JSONNode.parse(data)?.children, !children.isEmpty {
                        OutlineGroup(children, children: \.children) { node in
                            HStack(alignment: .top, spacing: 8) {
                                Text(node.key).bold()
                                Text(node.value).foregroundStyle(.secondary)
                            }
                            .font(.system(.body, design: .monospaced))
                        }
                    } else {
                        Text(text ?? "").font(.system(.body, design: .monospaced))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(byteCount(data.count)) dữ liệu nhị phân")
                    .font(.caption).foregroundStyle(.secondary)
                hex(data)
            }
        }
    }

    @ViewBuilder
    private func hex(_ data: Data) -> some View {
        Text(BodyDecoder.hexDump(data))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }

    private func bytes(_ n: Int) -> String { byteCount(n) }

    private func byteCount(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
