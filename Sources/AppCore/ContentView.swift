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
        .searchable(text: $store.searchText, prompt: "Lọc theo URL")
        // Refresh CA duy nhất lúc view xuất hiện — KHÔNG trong body/computed
        // property/timer, xem doc comment của `AppModel.refreshCertificateStatus()`.
        .task { await model.refreshCertificateStatus() }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = model.selection,
           let transaction = model.store.transactions.first(where: { $0.id == id }) {
            // Task 12 thay bằng InspectorView(transaction:) — placeholder này
            // chỉ để build xanh, không phải UI cuối cùng.
            Text(transaction.request.url.absoluteString)
                .textSelection(.enabled)
                .padding()
        } else {
            ContentUnavailableView("Chọn một request", systemImage: "arrow.left.arrow.right")
        }
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
            TableColumn("Size") { transaction in
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(transaction.response?.body.totalBytes ?? 0),
                    countStyle: .file
                ))
            }
            .width(min: 70, ideal: 80)
        }
    }

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
            Button("Cài Root CA") { Task { await model.installCertificate() } }
        }
        ToolbarItem { certificateStatusView }
        ToolbarItem {
            Picker("Method", selection: methodFilter) {
                Text("Tất cả").tag(String?.none)
                ForEach(["GET", "POST", "PUT", "DELETE", "CONNECT"], id: \.self) {
                    Text($0).tag(String?.some($0))
                }
            }
        }
        ToolbarItem { Button("Xoá hết") { store.clear() } }
        ToolbarItem(placement: .status) {
            Text(model.statusMessage).foregroundStyle(.secondary)
        }
    }

    /// Hiện trạng thái CA đã kiểm tra lần gần nhất, kèm nút refresh THỦ CÔNG
    /// — bấm mới gọi lại `isInstalled`, không có timer/computed property nào
    /// tự gọi lại nó.
    @ViewBuilder
    private var certificateStatusView: some View {
        HStack(spacing: 4) {
            switch model.certificateInstalled {
            case .some(true):
                Label("CA đã cài", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .some(false):
                Label("CA chưa cài", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .none:
                Label("CA: chưa rõ", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refreshCertificateStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Kiểm tra lại trạng thái Root CA")
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
