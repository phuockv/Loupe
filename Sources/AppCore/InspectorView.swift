import SwiftUI
import TrafficModel

/// Tab Request/Response cho transaction đang được chọn trong bảng.
///
/// Thứ tự kiểm tra trong `responseTab` là phần quan trọng nhất của view này:
/// `isTunnelled` phải được xét TRƯỚC `state`/`response`. Một CONNECT bị bypass
/// vẫn phát `.completed` kèm một response tổng hợp ("200 Connection
/// Established", `Content-Length: 0`) khi tunnel đóng sạch — response đó tả
/// đúng cái proxy trả lời CHO LỆNH CONNECT, không phải cho bất kỳ request nào
/// chạy BÊN TRONG tunnel, vì proxy không đọc được những request đó (xem
/// `ConnectEstablished`/`ProxyEntryHandler` ở `ProxyCore`). Nếu tab này ưu
/// tiên `response != nil` trước, nó sẽ hiện "200, body rỗng, completed" như
/// thể server không trả gì — đúng kết luận sai mà `Transaction.isTunnelled`
/// tồn tại để ngăn, xem doc comment của nó trong `TrafficModel/Models.swift`.
public struct InspectorView: View {
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
                    BodyView(payload: transaction.request.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var responseTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if transaction.isTunnelled {
                    tunnelledUnavailable
                } else if let response = transaction.response {
                    LabeledContent("Status", value: "\(response.statusCode) \(response.reasonPhrase)")
                    InspectorSection("Headers") { KeyValueTable(pairs: response.headers) }
                    InspectorSection("Body") { BodyView(payload: response.body) }
                } else if case .failed(let reason) = transaction.state {
                    failedUnavailable(reason: reason)
                } else {
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
    /// suy ra từ một body rỗng. Nếu `state` cũng là `.failed` (tunnel relay
    /// thật sự hỏng, chứ không chỉ "không giải mã"), hiện thêm lý do đó bên
    /// dưới — mất thông tin đó cũng tệ không kém việc giấu sự thật "chưa từng
    /// giải mã".
    @ViewBuilder
    private var tunnelledUnavailable: some View {
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

            if case .failed(let reason) = transaction.state {
                Divider()
                Text("Tunnel relay cũng thất bại:").font(.subheadline).bold()
                failureReasonText(reason)
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

    private func failureReasonText(_ reason: String) -> some View {
        Text(reason)
            .font(.system(.body, design: .monospaced))
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
private struct BodyView: View {
    let payload: BodyPayload

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

    @ViewBuilder
    private func content(for data: Data) -> some View {
        if let root = JSONNode.parse(data), let children = root.children, !children.isEmpty {
            OutlineGroup(children, children: \.children) { node in
                HStack(alignment: .top, spacing: 8) {
                    Text(node.key).bold()
                    Text(node.value).foregroundStyle(.secondary)
                }
                .font(.system(.body, design: .monospaced))
            }
        } else if let text = String(data: data, encoding: .utf8) {
            Text(text).font(.system(.body, design: .monospaced))
        } else {
            Text("\(byteCount(data.count)) dữ liệu nhị phân, không hiện được dạng text")
                .foregroundStyle(.secondary)
        }
    }

    private func byteCount(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
