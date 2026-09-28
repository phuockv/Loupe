import Foundation

/// Kết quả cài Root CA vào các simulator đang chạy. Một máy lỗi không chặn
/// các máy còn lại, nên kết quả luôn tách riêng máy thành công và máy lỗi.
public struct SimulatorInstallReport: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public let name: String
        public let message: String

        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }
    }

    /// Tên các simulator đã cài xong, xếp theo tên.
    public let installed: [String]
    public let failed: [Failure]

    public init(installed: [String], failed: [Failure]) {
        self.installed = installed
        self.failed = failed
    }
}

public enum SimulatorTrustError: Error, Sendable, Equatable {
    /// Không có simulator nào đang ở trạng thái Booted.
    case noBootedSimulator
    /// `xcrun simctl` không chạy được — thường vì máy chưa cài Xcode, hoặc
    /// `xcode-select` đang trỏ vào Command Line Tools (không có simctl).
    case simctlUnavailable(String)
}

extension SimulatorTrustError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noBootedSimulator:
            return "Không có simulator nào đang chạy — mở simulator rồi bấm lại."
        case .simctlUnavailable(let output):
            return "Không chạy được xcrun simctl (máy đã cài Xcode chưa?): \(output)"
        }
    }
}

/// Simulator iOS có trust store riêng, KHÔNG đọc keychain của macOS — nên
/// CA đã tin trên Mac vẫn bị simulator từ chối, và mọi HTTPS từ simulator
/// hỏng ở bước bắt tay TLS. Trust store đó nằm trong thư mục của người
/// dùng, nên cài không cần quyền admin.
public protocol SimulatorTrustInstalling: Sendable {
    func installOnBootedSimulators(pemPath: URL) async throws -> SimulatorInstallReport
}

/// Cài qua `xcrun simctl keychain <udid> add-root-cert`. Lệnh này cài lại
/// cùng một cert không sinh bản trùng, nên bấm nhiều lần vô hại.
public struct SimctlTrustInstaller: SimulatorTrustInstalling {
    private let runner: CommandRunner

    public init(runner: @escaping CommandRunner = SecurityCommandInstaller.runProcessUnprivileged) {
        self.runner = runner
    }

    public func installOnBootedSimulators(pemPath: URL) async throws -> SimulatorInstallReport {
        let simulators = try await bootedSimulators()
        guard !simulators.isEmpty else { throw SimulatorTrustError.noBootedSimulator }

        var installed: [String] = []
        var failed: [SimulatorInstallReport.Failure] = []
        for simulator in simulators {
            do {
                _ = try await runner([
                    "/usr/bin/xcrun", "simctl", "keychain", simulator.udid, "add-root-cert", pemPath.path,
                ])
                installed.append(simulator.name)
            } catch TrustStoreError.commandFailed(_, let output) {
                failed.append(.init(
                    name: simulator.name,
                    message: output.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                failed.append(.init(name: simulator.name, message: error.localizedDescription))
            }
        }
        return SimulatorInstallReport(installed: installed, failed: failed)
    }

    private struct Simulator: Decodable {
        let udid: String
        let name: String
        let state: String
    }

    private struct DeviceList: Decodable {
        /// Khoá là runtime identifier, ví dụ `...SimRuntime.iOS-26-5`.
        let devices: [String: [Simulator]]
    }

    private func bootedSimulators() async throws -> [Simulator] {
        let output: String
        do {
            output = try await runner(["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"])
        } catch TrustStoreError.commandFailed(_, let failure) {
            throw SimulatorTrustError.simctlUnavailable(
                failure.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let list = try JSONDecoder().decode(DeviceList.self, from: Data(output.utf8))
        return list.devices.values
            .flatMap { $0 }
            .filter { $0.state == "Booted" }
            .sorted { $0.name < $1.name }
    }
}
