import SwiftUI

@main
struct ProxyManCloneApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("ProxyManClone") {
            Text("ProxyManClone")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
