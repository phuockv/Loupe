import SwiftUI
import AppKit
import Dispatch
import AppCore
import SystemProxy

/// Dọn proxy hệ thống ở ba thời điểm mà SwiftUI không tự lo:
/// mở app, thoát bình thường, và bị SIGTERM/SIGINT.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Việc đầu tiên, trước khi làm gì khác: file snapshot còn sót nghĩa
        // là lần trước chết bất thường, người dùng lúc này nhiều khả năng
        // đang không vào được mạng — đây là việc khẩn nhất app phải làm, nên
        // bắn Task ngay dòng đầu tiên chứ không đợi cửa sổ dựng xong.
        //
        // Dùng `SystemProxyController.recoverIfNeeded`, KHÔNG phải
        // `SyncProxyRestore.restoreNow`: đường đồng bộ chỉ `try?` đọc
        // snapshot, snapshot hỏng thì lặng lẽ bỏ qua. `recoverIfNeeded` có
        // đường cứu riêng cho snapshot hỏng (tắt dấu vết loopback đúng cổng
        // của app), và đây là nơi duy nhất đường cứu đó được gọi tới. Mở app
        // không bị giới hạn thời gian như lúc thoát, nên `await` thoải mái.
        Task {
            _ = try? await SystemProxyController().recoverIfNeeded()
        }

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
