import Testing
import Foundation
@testable import CertKit

/// Runner giả trả output dựng sẵn cho từng lệnh và ghi lại mọi lệnh đã
/// chạy — không bao giờ exec `xcrun` thật, nên test không đụng vào
/// simulator nào trên máy chạy `swift test`.
private actor ScriptedRunner {
    private(set) var calls: [[String]] = []
    private let respond: @Sendable ([String]) throws -> String

    init(respond: @escaping @Sendable ([String]) throws -> String) {
        self.respond = respond
    }

    func run(_ arguments: [String]) throws -> String {
        calls.append(arguments)
        return try respond(arguments)
    }
}

private let listCommand = ["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"]

/// Output thật của `simctl list devices booted -j` rút gọn: runtime không
/// có máy nào đang chạy vẫn xuất hiện với mảng rỗng.
private let twoBootedJSON = """
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
      { "udid" : "E0EE-AIR", "state" : "Booted", "name" : "iPhone Air", "isAvailable" : true }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-3" : [],
    "com.apple.CoreSimulator.SimRuntime.iOS-18-0" : [
      { "udid" : "AAAA-16", "state" : "Booted", "name" : "iPhone 16", "isAvailable" : true }
    ]
  }
}
"""

private let pem = URL(fileURLWithPath: "/tmp/ca.pem")

@Suite("SimulatorTrustInstaller")
struct SimulatorTrustInstallerTests {

    @Test("Cài vào TỪNG simulator đang chạy, đúng lệnh simctl keychain add-root-cert theo udid")
    func installsOnEveryBootedSimulator() async throws {
        let runner = ScriptedRunner { args in args == listCommand ? twoBootedJSON : "" }
        let installer = SimctlTrustInstaller(runner: { try await runner.run($0) })

        let report = try await installer.installOnBootedSimulators(pemPath: pem)

        let calls = await runner.calls
        #expect(calls.first == listCommand)
        #expect(Set(calls.dropFirst()) == [
            ["/usr/bin/xcrun", "simctl", "keychain", "E0EE-AIR", "add-root-cert", "/tmp/ca.pem"],
            ["/usr/bin/xcrun", "simctl", "keychain", "AAAA-16", "add-root-cert", "/tmp/ca.pem"],
        ])
        #expect(report.installed == ["iPhone 16", "iPhone Air"])
        #expect(report.failed.isEmpty)
    }

    @Test("Không có simulator nào đang chạy: throw noBootedSimulator, không chạy lệnh cài nào")
    func throwsWhenNothingBooted() async throws {
        let runner = ScriptedRunner { _ in #"{ "devices" : { "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [] } }"# }
        let installer = SimctlTrustInstaller(runner: { try await runner.run($0) })

        await #expect(throws: SimulatorTrustError.noBootedSimulator) {
            _ = try await installer.installOnBootedSimulators(pemPath: pem)
        }
        #expect(await runner.calls == [listCommand])
    }

    @Test("simctl list thất bại (máy chưa có Xcode): throw simctlUnavailable kèm output")
    func throwsWhenSimctlUnavailable() async throws {
        let installer = SimctlTrustInstaller(runner: { _ in
            throw TrustStoreError.commandFailed(status: 72, output: "xcrun: error: unable to find utility \"simctl\"")
        })

        await #expect(throws: SimulatorTrustError.simctlUnavailable("xcrun: error: unable to find utility \"simctl\"")) {
            _ = try await installer.installOnBootedSimulators(pemPath: pem)
        }
    }

    @Test("Một máy cài lỗi không chặn máy còn lại: báo cả máy thành công lẫn máy lỗi")
    func reportsPartialFailure() async throws {
        let runner = ScriptedRunner { args in
            if args == listCommand { return twoBootedJSON }
            if args.contains("AAAA-16") {
                throw TrustStoreError.commandFailed(status: 1, output: "Invalid device state\n")
            }
            return ""
        }
        let installer = SimctlTrustInstaller(runner: { try await runner.run($0) })

        let report = try await installer.installOnBootedSimulators(pemPath: pem)

        #expect(report.installed == ["iPhone Air"])
        #expect(report.failed == [.init(name: "iPhone 16", message: "Invalid device state")])
    }
}
