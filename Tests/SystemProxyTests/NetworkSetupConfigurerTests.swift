import Testing
import Foundation
@testable import SystemProxy

@Suite("NetworkSetupConfigurer")
struct NetworkSetupConfigurerTests {

    /// Runner giả: ghi lại mọi lệnh đã chạy, trả output đặt sẵn theo thứ tự.
    actor FakeRunner {
        private(set) var commands: [[String]] = []
        private var outputs: [String]
        private let failAt: Int?

        init(outputs: [String], failAt: Int? = nil) {
            self.outputs = outputs
            self.failAt = failAt
        }

        func run(_ args: [String]) async throws -> String {
            commands.append(args)
            if let failAt, commands.count == failAt {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi")
            }
            return outputs.isEmpty ? "" : outputs.removeFirst()
        }

        var runner: CommandRunner {
            { [self] args in try await self.run(args) }
        }
    }

    @Test("Bỏ dịch vụ bị tắt (dấu * đầu tên) và bỏ dòng tiêu đề")
    func parsesActiveServicesOnly() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        Thunderbolt Bridge
        Wi-Fi
        *Urban VPN Desktop
        phuoc.kieu-c-sg
        """
        #expect(NetworkSetupConfigurer.parseServices(output)
                == ["Thunderbolt Bridge", "Wi-Fi", "phuoc.kieu-c-sg"])
    }

    @Test("Tên có dấu cách và dấu chấm/gạch không bị cắt")
    func keepsServiceNamesWithSpacesAndPunctuation() {
        let parsed = NetworkSetupConfigurer.parseServices("Thunderbolt Bridge\nphuoc.kieu-c-sg")
        #expect(parsed.first == "Thunderbolt Bridge")
        #expect(parsed.last == "phuoc.kieu-c-sg")
    }

    @Test("Parse output getwebproxy khi đang bật")
    func parsesEnabledProxy() throws {
        let output = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 9090
        Authenticated Proxy Enabled: 0
        """
        let setting = try NetworkSetupConfigurer.parseProxy(output)
        #expect(setting == ProxySetting(enabled: true, server: "127.0.0.1", port: 9090))
    }

    @Test("Parse output getwebproxy khi đang tắt")
    func parsesDisabledProxy() throws {
        let output = "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0"
        let setting = try NetworkSetupConfigurer.parseProxy(output)
        #expect(setting.enabled == false)
        #expect(setting.port == 0)
    }

    @Test("Output không đọc được thì ném lỗi, không đoán bừa thành 'đang tắt'")
    func throwsOnUnreadableOutput() {
        #expect(throws: SystemProxyError.self) {
            try NetworkSetupConfigurer.parseProxy("** Error: dịch vụ không tồn tại")
        }
    }

    @Test("Đang bật nhưng Port không phải số thì ném lỗi, không rơi về 0")
    func throwsWhenEnabledWithGarbagePort() {
        #expect(throws: SystemProxyError.self) {
            try NetworkSetupConfigurer.parseProxy("Enabled: Yes\nServer: 127.0.0.1\nPort: abc")
        }
    }

    @Test("Đang bật nhưng thiếu Server thì ném lỗi, không rơi về rỗng")
    func throwsWhenEnabledWithMissingServer() {
        #expect(throws: SystemProxyError.self) {
            try NetworkSetupConfigurer.parseProxy("Enabled: Yes\nPort: 9090")
        }
    }

    @Test("Đang tắt với Server rỗng và Port 0 vẫn parse được, không bị coi là lỗi")
    func disabledWithEmptyServerAndZeroPortStillParses() throws {
        let setting = try NetworkSetupConfigurer.parseProxy("Enabled: No\nServer: \nPort: 0")
        #expect(setting.enabled == false)
        #expect(setting.server == "")
        #expect(setting.port == 0)
    }

    @Test("apply đặt cả HTTP lẫn HTTPS, dùng đường dẫn tuyệt đối")
    func applySetsBothProtocols() async throws {
        let fake = FakeRunner(outputs: ["", ""])
        let sut = NetworkSetupConfigurer(runner: await fake.runner)
        try await sut.apply(host: "127.0.0.1", port: 9090, to: "Wi-Fi")

        let commands = await fake.commands
        #expect(commands == [
            ["/usr/sbin/networksetup", "-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
            ["/usr/sbin/networksetup", "-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"],
        ])
    }

    @Test("Khôi phục về TẮT dùng -setwebproxystate off, KHÔNG set server rỗng port 0")
    func restoreToOffUsesStateCommand() async throws {
        let fake = FakeRunner(outputs: [""])
        let sut = NetworkSetupConfigurer(runner: await fake.runner)
        try await sut.restore(.off, field: .web, of: "Wi-Fi")

        let commands = await fake.commands
        #expect(commands == [
            ["/usr/sbin/networksetup", "-setwebproxystate", "Wi-Fi", "off"],
        ], "`-setwebproxy Wi-Fi \"\" 0` là lệnh không hợp lệ, sẽ lỗi lúc chạy thật")
    }

    @Test("Khôi phục về một proxy đang bật thì set server rồi bật state")
    func restoreToEnabledSetsServerThenState() async throws {
        let fake = FakeRunner(outputs: ["", ""])
        let sut = NetworkSetupConfigurer(runner: await fake.runner)
        let corporate = ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
        try await sut.restore(corporate, field: .web, of: "Wi-Fi")

        let commands = await fake.commands
        #expect(commands == [
            ["/usr/sbin/networksetup", "-setwebproxy", "Wi-Fi", "proxy.corp.local", "3128"],
            ["/usr/sbin/networksetup", "-setwebproxystate", "Wi-Fi", "on"],
        ])
    }

    @Test("Khôi phục một field KHÔNG phát lệnh nào cho field kia")
    func restoreTouchesOnlyTheGivenField() async throws {
        let fake = FakeRunner(outputs: ["", ""])
        let sut = NetworkSetupConfigurer(runner: await fake.runner)
        let corporate = ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
        try await sut.restore(corporate, field: .secureWeb, of: "Wi-Fi")

        let commands = await fake.commands
        #expect(commands == [
            ["/usr/sbin/networksetup", "-setsecurewebproxy", "Wi-Fi", "proxy.corp.local", "3128"],
            ["/usr/sbin/networksetup", "-setsecurewebproxystate", "Wi-Fi", "on"],
        ], "một `-setwebproxy` thừa xoá sạch credential của proxy HTTP có xác thực")
    }
}
