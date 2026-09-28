// Tests/AppTests/SystemProxyWiringTests.swift
import Testing
import Foundation
import SystemProxy
@testable import AppCore

@Suite("AppModel — nối proxy hệ thống")
@MainActor
struct SystemProxyWiringTests {

    /// KHÔNG BAO GIỜ `AppModel()` trần ở suite này.
    ///
    /// `AppModel()` trần là `SystemProxyController.shared`: configurer thật
    /// chạy `/usr/sbin/networksetup` thật, store thật trỏ vào Application
    /// Support thật của máy đang chạy `swift test`. Ba test dưới đây hiện
    /// không chạm tới `start()` nên nó vô hại — nhưng "vô hại vì tình cờ
    /// không ai gọi tới" là thứ hỏng ngay ở lần thêm khẳng định sau, và cái
    /// hỏng đó là đổi cấu hình mạng thật của người chạy test.
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemProxyWiringTests-\(UUID().uuidString)")
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemProxyWiringTests-snapshot-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.json")
        return AppModel(
            installer: FakeTrustStoreInstaller(),
            caDirectory: dir,
            systemProxy: SystemProxyController(
                configurer: FakeSystemProxyConfigurer(),
                store: ProxySnapshotStore(url: snapshotURL)))
    }

    @Test("Toggle mặc định BẬT")
    func defaultsToOn() {
        #expect(makeModel().setSystemProxy == true)
    }

    @Test("Toggle không lưu qua các lần mở app — model mới luôn bật lại")
    func doesNotPersistAcrossLaunches() async {
        let first = makeModel()
        await first.setSetSystemProxy(false)
        #expect(first.setSystemProxy == false)

        #expect(makeModel().setSystemProxy == true,
                "công tắc đổi cài đặt mạng toàn máy nên về giá trị đã biết mỗi lần mở")
    }

    @Test("Đặt lại đúng giá trị đang có thì không làm gì")
    func ignoresRedundantChange() async {
        let model = makeModel()
        await model.setSetSystemProxy(true)
        #expect(model.setSystemProxy == true)
    }

    @Test("Thông báo tự cứu gọi tên ĐÚNG dịch vụ trong snapshot, không hard-code Wi-Fi")
    func rescueMessageNamesEveryServiceInSnapshot() {
        let message = AppModel.systemProxyRescueMessage(
            error: SystemProxyError.restoreIncomplete(services: ["phuoc.kieu-c-sg"]),
            services: ["phuoc.kieu-c-sg", "Thunderbolt Bridge"])

        #expect(message.contains("networksetup -setwebproxystate \"phuoc.kieu-c-sg\" off"))
        #expect(message.contains("networksetup -setsecurewebproxystate \"phuoc.kieu-c-sg\" off"))
        #expect(message.contains("networksetup -setwebproxystate \"Thunderbolt Bridge\" off"))
        #expect(message.contains("networksetup -setsecurewebproxystate \"Thunderbolt Bridge\" off"))
        #expect(!message.contains("Wi-Fi"),
                "sự cố gốc là một VPN: đưa hai lệnh Wi-Fi cho người đang kẹt ngoài mạng là đưa thứ không sửa được gì")
    }

    @Test("Snapshot đọc không được thì chỉ đường tự liệt kê, KHÔNG bịa tên dịch vụ")
    func rescueMessageFallsBackWhenSnapshotUnreadable() {
        let message = AppModel.systemProxyRescueMessage(
            error: SystemProxyError.snapshotUnreadable("JSON hỏng"), services: [])

        #expect(message.contains("networksetup -listallnetworkservices"))
        #expect(!message.contains("Wi-Fi"))
    }
}
