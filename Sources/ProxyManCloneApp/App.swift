import SwiftUI
import AppCore

@main
struct ProxyManCloneApp: App {
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
