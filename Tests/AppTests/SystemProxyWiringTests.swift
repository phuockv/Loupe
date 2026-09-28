// Tests/AppTests/SystemProxyWiringTests.swift
import Testing
import Foundation
@testable import AppCore

@Suite("AppModel — nối proxy hệ thống")
@MainActor
struct SystemProxyWiringTests {

    @Test("Toggle mặc định BẬT")
    func defaultsToOn() {
        #expect(AppModel().setSystemProxy == true)
    }

    @Test("Toggle không lưu qua các lần mở app — model mới luôn bật lại")
    func doesNotPersistAcrossLaunches() async {
        let first = AppModel()
        await first.setSetSystemProxy(false)
        #expect(first.setSystemProxy == false)

        #expect(AppModel().setSystemProxy == true,
                "công tắc đổi cài đặt mạng toàn máy nên về giá trị đã biết mỗi lần mở")
    }

    @Test("Đặt lại đúng giá trị đang có thì không làm gì")
    func ignoresRedundantChange() async {
        let model = AppModel()
        await model.setSetSystemProxy(true)
        #expect(model.setSystemProxy == true)
    }
}
