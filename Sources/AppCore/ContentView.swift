import SwiftUI
import TrafficModel

public struct ContentView: View {
    @State private var model = AppModel()

    public init() {}

    public var body: some View {
        // `store` là `let` trên `AppModel`, nên `$model.store.searchText`
        // không phải một reference-writable key path hợp lệ để lấy Binding
        // qua `$model`. Rebind cục bộ qua `@Bindable` lấy đúng tham chiếu
        // `TrafficStore` (chính nó là `@Observable`) và cho `$store.xxx`
        // hoạt động độc lập với việc `store` trên `AppModel` có phải `var`
        // hay không. Phải khai báo cục bộ trong `body` (không phải property
        // của `ContentView`): tại đây `model` đã là giá trị đã được SwiftUI
        // gắn với `@State` thật, trong khi làm điều này ở `init` sẽ đọc nhầm
        // một `AppModel` mới toanh, dùng-một-lần mỗi khi SwiftUI dựng lại
        // struct view.
        @Bindable var store = model.store

        NavigationSplitView {
            transactionTable(transactions: store.filtered)
                .navigationSplitViewColumnWidth(min: 520, ideal: 720)
        } detail: {
            detailPane
        }
        .toolbar { toolbarContent(store: store, methodFilter: $store.methodFilter) }
        // `placement: .sidebar` thay vì mặc định (`.toolbar` trên
        // NavigationSplitView): ô tìm kiếm chiếm chỗ đáng kể ngay cả khi thu
        // gọn thành nút, và đó là một phần lý do toolbar chính hết chỗ cho
        // nút Chạy/Dừng ở độ rộng cửa sổ mặc định — xem doc comment của
        // `toolbarContent`.
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Lọc theo URL")
        // statusMessage nằm ở đây (thanh trạng thái đáy cửa sổ), KHÔNG phải
        // trong toolbar — xem doc comment của `toolbarContent`: mục nó từng
        // chiếm trong toolbar là lý do chính khiến nút Chạy/Dừng bị đẩy vào
        // "more toolbar items" ở độ rộng cửa sổ mặc định. Ở đây nó luôn hiện
        // trọn vẹn, không phụ thuộc chỗ trống của toolbar.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.statusMessage).foregroundStyle(.secondary)
                Spacer()
                // Toggle nằm ở thanh trạng thái chứ KHÔNG phải toolbar: toolbar
                // vừa được sửa cho vừa nút Chạy/Dừng ở độ rộng cửa sổ mặc định
                // (xem doc comment của `toolbarContent`), thêm một mục nữa vào
                // đó là đẩy nút Chạy về lại "more toolbar items".
                Toggle("Ép server không nén", isOn: Binding(
                    get: { model.forceDecompressible },
                    set: { force in Task { await model.setForceDecompressible(force) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Viết lại Accept-Encoding thành \"gzip, deflate\" để server không trả brotli/zstd — "
                    + "hệ thống không giải nén được hai loại đó. Lưu ý: việc này THAY ĐỔI request đi trên dây; "
                    + "header ghi lại trong transaction vẫn là bản gốc client gửi.")

                Toggle("Cho thiết bị LAN dùng", isOn: Binding(
                    get: { model.allowLANDevices },
                    set: { allow in Task { await model.setAllowLANDevices(allow) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Bind 0.0.0.0 để iPhone hoặc máy khác cùng Wi-Fi dùng được proxy. "
                    + "Bật lên là bất kỳ ai trong mạng cũng đi qua được — tắt khi xong.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        // Refresh CA duy nhất lúc view xuất hiện — KHÔNG trong body/computed
        // property/timer, xem doc comment của `AppModel.refreshCertificateStatus()`.
        .task { await model.refreshCertificateStatus() }
    }

    private var detailPane: some View {
        // `frame` ở ĐÂY, ngoài cả hai nhánh: nếu không, bề ngang mà pane này
        // đòi phụ thuộc nội dung của dòng đang chọn (một URL dài đòi khác một
        // URL ngắn, `ContentUnavailableView` đòi khác cả hai) và
        // NavigationSplitView đáp ứng bằng cách dời đường chia mỗi lần đổi
        // dòng — cùng gốc với việc cho Text tự do đòi bề ngang, xem
        // `KeyValueTable` ở `InspectorView.swift`. Một `minWidth` cố định
        // biến bề ngang thành thuộc tính của cửa sổ, không phải của dòng.
        Group {
            if let id = model.selection,
               let transaction = model.store.transactions.first(where: { $0.id == id }) {
                InspectorView(transaction: transaction)
            } else {
                ContentUnavailableView("Chọn một request", systemImage: "arrow.left.arrow.right")
            }
        }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func transactionTable(transactions: [TrafficModel.Transaction]) -> some View {
        Table(transactions, selection: $model.selection) {
            TableColumn("Method") { Text($0.request.method).monospaced() }
                .width(min: 60, ideal: 70)
            TableColumn("Status") { StatusCell(transaction: $0) }
                .width(min: 80, ideal: 110)
            TableColumn("Host") { Text($0.host) }
                .width(min: 120, ideal: 200)
            TableColumn("Path") { Text($0.request.url.path) }
                .width(min: 120, ideal: 260)
            TableColumn("Duration") { transaction in
                Text(transaction.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Size") { SizeCell(transaction: $0) }
                .width(min: 70, ideal: 80)
        }
    }

    // Task 12: ở độ rộng cửa sổ mặc định (1000pt, xem `minWidth` trong
    // `App.swift`), toolbar cũ (Chạy/Dừng + Cài Root CA + badge trạng thái +
    // nút refresh + Method picker + Xoá hết + status text, cộng thêm ô tìm
    // kiếm và nút ẩn sidebar mà SwiftUI tự thêm) không đủ chỗ và macOS gói
    // gần như TOÀN BỘ vào menu "more toolbar items" — xác nhận bằng
    // Accessibility Inspector lúc chạy thật: chỉ còn "Hide Sidebar" và
    // "Search" hiện trực tiếp, mọi thứ khác (kể cả nút Chạy) nằm sau một
    // chevron ẩn. Ba thay đổi gộp lại mới đủ nhường chỗ cho nút Chạy/Dừng —
    // điều khiển quan trọng nhất của app — hiện trực tiếp: gộp thao tác CA
    // vào một `Menu` (một điều khiển thay vì ba), thu gọn "Xoá hết" về chỉ
    // icon, và dời status message + ô tìm kiếm ra khỏi toolbar chính (xem
    // `.safeAreaInset`/`.searchable` ở `body`) — hai thứ đó riêng rẽ vẫn
    // không đủ, xem lịch sử đo ở test thủ công của task này.
    @ToolbarContentBuilder
    private func toolbarContent(store: TrafficStore, methodFilter: Binding<String?>) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(model.isRunning ? "Dừng" : "Chạy") {
                Task {
                    if model.isRunning {
                        await model.stop()
                    } else {
                        await model.start()
                    }
                }
            }
        }
        ToolbarItem {
            Menu {
                Button("Cài Root CA") { Task { await model.installCertificate() } }
                Button("Kiểm tra lại trạng thái CA") {
                    Task { await model.refreshCertificateStatus() }
                }
            } label: {
                certificateStatusLabel
            }
        }
        ToolbarItem {
            Picker("Method", selection: methodFilter) {
                Text("Tất cả").tag(String?.none)
                ForEach(["GET", "POST", "PUT", "DELETE", "CONNECT"], id: \.self) {
                    Text($0).tag(String?.some($0))
                }
            }
        }
        ToolbarItem {
            Button {
                store.clear()
            } label: {
                Label("Xoá hết", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("Xoá hết transaction đang hiện")
        }
    }

    /// Hiện trạng CA đã kiểm tra lần gần nhất làm label cho menu thao tác CA.
    /// Trạng thái chỉ được set bởi `refreshCertificateStatus()` — xem doc
    /// comment của `AppModel.certificateInstalled` — nên không có gì ở đây
    /// tự gọi lại nó ngoài hành động refresh trong menu.
    @ViewBuilder
    private var certificateStatusLabel: some View {
        switch model.certificateInstalled {
        case .some(true):
            Label("CA", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .some(false):
            Label("CA", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .none:
            Label("CA", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// Suy diễn thuần logic những gì `StatusCell` cần hiển thị, tách khỏi
/// SwiftUI để test được không cần dựng view thật.
///
/// `isTunnelled` và `state` (qua `kind`) là hai tín hiệu ĐỘC LẬP — xem doc
/// comment của `Transaction.isTunnelled` và `TransactionState`. Đây là nơi
/// DUY NHẤT trong toàn app hai tín hiệu đó gặp lại nhau để hiển thị cho
/// người dùng: một bypass connection có thể vừa `isTunnelled` vừa
/// `.completed` cùng lúc, và cả hai PHẢI cùng hiện ra. Chỉ hiện "completed"
/// khiến người dùng tưởng đã có dữ liệu giải mã trong khi thực ra proxy
/// chưa từng đọc được byte nào của kết nối đó — đúng lỗi mà việc tách
/// `isTunnelled` ra khỏi `TransactionState` tồn tại để chặn.
struct StatusPresentation: Equatable {
    enum Kind: Equatable {
        case pending
        case completed(code: Int)
        case failed(reason: String)
    }

    let isTunnelled: Bool
    let kind: Kind

    init(transaction: TrafficModel.Transaction) {
        isTunnelled = transaction.isTunnelled
        switch transaction.state {
        case .pending:
            kind = .pending
        case .completed:
            kind = .completed(code: transaction.response?.statusCode ?? 0)
        case .failed(let reason):
            kind = .failed(reason: reason)
        }
    }
}

/// Status code kèm màu, và badge tunnel ĐỘC LẬP với nó — xem
/// `StatusPresentation`. `.failed` không phải lúc nào cũng là sự cố cần
/// người dùng xử lý (ví dụ client bỏ preconnect trước khi tunnel kịp dựng
/// xong là kết cục bình thường — xem doc comment ở `ProxyEntryHandler`/
/// `ConnectTunnelHandler`), nên nhãn dùng "thất bại" trung tính thay vì
/// "lỗi", và toàn bộ lý do thật nằm trong tooltip thay vì bị cắt bớt.
struct StatusCell: View {
    let transaction: TrafficModel.Transaction

    var body: some View {
        let presentation = StatusPresentation(transaction: transaction)
        HStack(spacing: 4) {
            if presentation.isTunnelled {
                Image(systemName: "lock.slash")
                    .foregroundStyle(.secondary)
                    .help("""
                    Host nằm trong bypass list — proxy chỉ tunnel byte thô, \
                    không giải mã nội dung. Đúng cả khi trạng thái bên cạnh \
                    là kết quả cuối: tunnel đóng sạch không có nghĩa nội \
                    dung từng được đọc.
                    """)
            }
            kindView(presentation.kind)
        }
    }

    @ViewBuilder
    private func kindView(_ kind: StatusPresentation.Kind) -> some View {
        switch kind {
        case .pending:
            ProgressView().controlSize(.small)
        case .completed(let code):
            Text(code > 0 ? "\(code)" : "—")
                .foregroundStyle(code >= 400 ? .red : .primary)
        case .failed(let reason):
            Text("thất bại").foregroundStyle(.orange).help(reason)
        }
    }
}

/// Suy diễn thuần logic những gì cột Size hiển thị, tách khỏi SwiftUI để test
/// được — cùng khuôn với `StatusPresentation`.
///
/// Kiểu này tồn tại vì một dòng: `response?.body.totalBytes ?? 0` chạy qua
/// `ByteCountFormatter` in ra "Zero bytes" cho MỌI dòng CONNECT — cả tunnel mù
/// đã relay 8 MB lẫn phiên MitM, vì response của cả hai là
/// `200 Connection Established` tổng hợp với body `.none` — và cho cả một
/// transaction `.failed` chết giữa body sau khi đã có `.responseHead`.
/// "Zero bytes" là một KHẲNG ĐỊNH về dây; `.unknown` (hiện "—") là việc không
/// đưa ra khẳng định nào.
///
/// Hệ quả CÓ CHỦ Ý: cột này không bao giờ in ra số 0. Một response rỗng thật
/// (204/304) cũng hiện "—", vì model không phân biệt "origin không gửi body"
/// với "ta chưa thu được body" — cả hai đều là `BodyPayload.none`. Nói ít hơn
/// những gì mình biết là cái giá chấp nhận được; nói nhiều hơn thì không.
struct SizePresentation: Equatable {
    enum Kind: Equatable {
        /// Không có con số nào ta biết chắc.
        case unknown
        /// Body đã thu TRỌN VẸN của một response đã giải mã.
        case responseBody(bytes: Int)
        /// Byte thô hai chiều của một tunnel mù — xem `Transaction.bytesSent`.
        case relayedThroughTunnel(sent: Int, received: Int)
    }

    let kind: Kind

    init(transaction: TrafficModel.Transaction) {
        if transaction.isTunnelled {
            // Tunnel mù không có "response body" nào để đo: đơn vị đo là cả
            // phiên, và nó chỉ tồn tại sau khi tunnel đóng (`.bytesRelayed`).
            //
            // Tổng bằng 0 được coi là CHƯA BIẾT, và điều đó cố ý gộp hai
            // trường hợp: tunnel đang chạy (byte đang chảy nhưng chưa ai báo)
            // và tunnel thật sự chưa chở byte nào. Gộp về phía "chưa biết" là
            // phía an toàn — phía kia in "Zero bytes" lên một tunnel đang tải
            // dở, đúng lời nói dối cả kiểu này sinh ra để chặn.
            let total = transaction.bytesSent + transaction.bytesReceived
            kind = total > 0
                ? .relayedThroughTunnel(sent: transaction.bytesSent,
                                        received: transaction.bytesReceived)
                : .unknown
            return
        }
        guard let body = transaction.response?.body, body.totalBytes > 0 else {
            kind = .unknown
            return
        }
        // `.truncated` cũng vào đây: `totalBytes` của nó là con số THẬT trên
        // dây, chỉ phần nội dung giữ lại mới bị cắt (xem `BodyPayload`).
        kind = .responseBody(bytes: body.totalBytes)
    }
}

/// Cột Size. Xem `SizePresentation` cho lý do "—" thay vì "Zero bytes".
struct SizeCell: View {
    let transaction: TrafficModel.Transaction

    var body: some View {
        switch SizePresentation(transaction: transaction).kind {
        case .unknown:
            Text("—").foregroundStyle(.secondary)
        case .responseBody(let bytes):
            Text(Self.formatted(bytes))
        case .relayedThroughTunnel(let sent, let received):
            // Con số ở đây là TỔNG hai chiều byte thô, không phải kích thước
            // một response — tooltip nói rõ ra chứ không để người đọc tự suy.
            Text(Self.formatted(sent + received))
                .help("""
                Tunnel mù: \(Self.formatted(sent)) client→origin \
                + \(Self.formatted(received)) origin→client đã relay thô. \
                Proxy không đọc được nội dung, và đây là phần peer đã nhận vào \
                hàng đợi ghi — không hứa đã ra hết tới dây.
                """)
        }
    }

    private static func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
