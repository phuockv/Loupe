import SwiftUI
import AppKit
import Dispatch
import AppCore
import SystemProxy

/// Dọn proxy hệ thống ở ba thời điểm mà SwiftUI không tự lo:
/// mở app, thoát bình thường, và bị SIGTERM/SIGINT.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    /// Trần thời gian chặn lúc mở app. Khôi phục thật chỉ tốn vài trăm ms
    /// (2 lệnh đọc + 2–3 lệnh ghi cho mỗi dịch vụ), nhưng một `networksetup`
    /// treo không được phép treo luôn cả app: hết giờ thì thả cho cửa sổ hiện
    /// ra trong khi việc khôi phục chạy tiếp ngầm. Cửa sổ có hiện sớm cũng
    /// không sinh ra cuộc đua nữa — `enable()` tự đợi đúng task này.
    private static let recoveryDeadline: DispatchTimeInterval = .seconds(10)

    /// §4.3: khôi phục chạy XONG trước khi vẽ cửa sổ. `willFinishLaunching`
    /// chạy trước khi scene nào được dựng, nên đây là chỗ duy nhất chặn được
    /// mà không phải chặn một cửa sổ đã hiện ra.
    ///
    /// Chặn main thread có chủ ý: việc khôi phục không cần tới main thread
    /// (actor của nó không phải `@MainActor`, và `networksetup` chạy trên một
    /// `Thread` riêng), nên không có vòng chờ lẫn nhau nào ở đây. Đổi lại,
    /// M4 quan sát được đúng như spec mô tả: `kill -9` rồi mở lại app thì
    /// proxy đã tắt TRƯỚC khi cửa sổ hiện.
    ///
    /// Dùng `SystemProxyController.recoverAtLaunch`, KHÔNG phải
    /// `SyncProxyRestore.restoreNow`: đường đồng bộ chỉ `try?` đọc snapshot,
    /// snapshot hỏng thì lặng lẽ bỏ qua. Đường async có đường cứu riêng cho
    /// snapshot hỏng (tắt dấu vết loopback đúng cổng của app), và đây là nơi
    /// duy nhất đường cứu đó được gọi tới.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // ĐÚNG instance mà `AppModel` dùng. Hai instance riêng không loại trừ
        // nhau được: trạng thái chung nằm ở file snapshot và ở cấu hình OS,
        // và cái chốt chặn `enable()` trong lúc đang khôi phục chỉ chặn được
        // lời gọi trên cùng một instance.
        let controller = SystemProxyController.shared
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await controller.recoverAtLaunch()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + Self.recoveryDeadline)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bảo hiểm cho đúng một tình huống: `willFinishLaunching` không tới
        // được (SwiftUI gắn delegate qua `@NSApplicationDelegateAdaptor`, và
        // thời điểm gắn không nằm trong tay ta). Thiếu nó thì hỏng theo hướng
        // đắt nhất — không khôi phục lần nào cả. Gọi lại là vô hại: cùng một
        // task, lần gọi thứ hai chỉ đợi kết quả của lần đầu.
        Task { await SystemProxyController.shared.recoverAtLaunch() }

        installSignalHandler(SIGTERM)
        installSignalHandler(SIGINT)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Đồng bộ, KHÔNG Task { }: hàm này trả về xong là app chết, một Task
        // async sẽ không kịp chạy tới nơi.
        SyncProxyRestore.restoreNow(storeURL: ProxySnapshotStore.defaultURL)
    }

    /// `DispatchSource` chạy handler trên một hàng đợi bình thường, không
    /// trong ngữ cảnh signal — nên gọi được `Process`, `FileManager` và mọi
    /// thứ khác vốn KHÔNG async-signal-safe. Một `signal(2)` handler thì
    /// không: ghi file hay spawn tiến trình trong đó là hành vi không xác
    /// định.
    private func installSignalHandler(_ sig: Int32) {
        signal(sig, SIG_IGN)   // tắt hành vi mặc định, nếu không tiến trình chết ngay
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            SyncProxyRestore.restoreNow(storeURL: ProxySnapshotStore.defaultURL)
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

@main
struct ProxyManCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // Chạy bằng `swift run` thì binary không nằm trong .app bundle, nên
        // phải tự activate để cửa sổ nhận được focus (mặc định nó mở phía
        // sau các app khác, dễ trông như app "không chạy").
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("ProxyManClone") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 640)
        }
    }
}
