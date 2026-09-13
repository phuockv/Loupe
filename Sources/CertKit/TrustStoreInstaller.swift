import Foundation

public typealias CommandRunner = @Sendable ([String]) async throws -> String

public protocol TrustStoreInstaller: Sendable {
    /// True nếu CHÍNH cert tại `pemPath` (đúng nội dung, không chỉ common
    /// name) đang được hệ thống tin làm root NGAY LÚC gọi. False cho mọi
    /// trường hợp "chưa cài đúng nghĩa": không có trong keychain nào, có
    /// nhưng nội dung khác (ví dụ CA cũ bị regenerate — cùng common name,
    /// khác key/serial), hoặc có nhưng trust đã bị người dùng thu hồi trong
    /// Keychain Access. Không throw cho các trường hợp đó — chỉ throw khi
    /// bản thân việc gọi `security` thất bại ở tầng hạ tầng (ví dụ không
    /// exec được binary).
    func isInstalled(pemPath: URL) async throws -> Bool
    func install(pemPath: URL) async throws
}

public enum TrustStoreError: Error, Sendable {
    /// Người dùng bấm Cancel ở hộp thoại xin quyền admin.
    case cancelled

    /// Lệnh thất bại. `status`, khi lấy được, là exit code THẬT của lệnh
    /// shell bên trong `do shell script` (rút ra từ số trong ngoặc mà
    /// AppleScript đính kèm ở cuối message lỗi) — KHÔNG phải exit code của
    /// tiến trình `osascript`, vì cái đó luôn luôn là 1 cho mọi lỗi kịch
    /// bản và không phân biệt được nguyên nhân. Khi không rút được số đó
    /// (định dạng message không như kỳ vọng), `status` rơi về exit code
    /// của tiến trình đã chạy — trường hợp đó, tên field không còn đúng
    /// nghĩa "exit code của lệnh", nhưng đây là thông tin tốt nhất còn lại.
    case commandFailed(status: Int32, output: String)
}

extension TrustStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Bạn đã huỷ hộp thoại xin quyền admin, nên chưa cài được Root CA."
        case .commandFailed(let status, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Lệnh thất bại (mã \(status))."
                : "Lệnh thất bại (mã \(status)): \(trimmed)"
        }
    }
}

/// Cài CA qua lệnh `security`. Bước ghi vào System keychain (`install`) cần
/// quyền admin nên chạy qua osascript, macOS sẽ hiện hộp thoại xin mật khẩu.
/// `isInstalled` chỉ ĐỌC (`security verify-cert`), không cần quyền admin,
/// nên đi qua một runner khác — không hộp thoại, không chờ người dùng.
///
/// Toàn bộ phần cần quyền admin nằm sau protocol này: khi chốt hướng
/// ký/phân phối (privileged helper, SMAppService...), chỉ cần thêm impl mới
/// mà không đụng tới engine.
public struct SecurityCommandInstaller: TrustStoreInstaller {
    private let runner: CommandRunner
    private let readRunner: CommandRunner

    /// - Parameters:
    ///   - runner: chạy lệnh CẦN quyền admin (`install`). Mặc định đi qua
    ///     osascript + "with administrator privileges", sẽ hiện hộp thoại
    ///     xin mật khẩu.
    ///   - readRunner: chạy lệnh CHỈ ĐỌC, không cần quyền admin
    ///     (`isInstalled`). Mặc định chạy `security` trực tiếp, không qua
    ///     osascript, không hộp thoại.
    public init(
        runner: @escaping CommandRunner = SecurityCommandInstaller.runProcess,
        readRunner: @escaping CommandRunner = SecurityCommandInstaller.runProcessUnprivileged
    ) {
        self.runner = runner
        self.readRunner = readRunner
    }

    public func isInstalled(pemPath: URL) async throws -> Bool {
        do {
            // `-l`: cho phép cert "lá" mang basic-constraint CA (root của ta
            // luôn là CA, nếu thiếu cờ này security coi đó là lỗi input).
            // `-L`: không thử tải cert thiếu qua mạng — không cần cho root
            // tự ký, nhưng chặn hẳn khả năng gọi mạng ở một phép kiểm cục bộ.
            _ = try await readRunner([
                "/usr/bin/security", "verify-cert", "-l", "-L", "-c", pemPath.path,
            ])
            return true
        } catch let error as TrustStoreError {
            if case .commandFailed = error {
                // verify-cert thoát khác 0: không tự ký/không khớp nội dung
                // nào đang được trust làm root, hoặc file không đọc được —
                // với isInstalled, tất cả những điều đó đều có nghĩa "chưa
                // cài", không phải một lỗi hạ tầng cần throw.
                return false
            }
            throw error
        }
    }

    public func install(pemPath: URL) async throws {
        _ = try await runner([
            "/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", pemPath.path,
        ])
    }

    // MARK: - Command execution

    /// Người dùng bấm Cancel trên hộp thoại trust settings mà `securityd`
    /// hiện ra.
    ///
    /// Nhận diện bằng text vì `security` trả cùng exit code cho mọi kiểu lỗi.
    /// Chuỗi khớp được giữ HẸP có chủ ý: bắt rộng quá thì một lỗi thật sẽ bị
    /// hiện thành "bạn đã huỷ", tức công cụ đổ lỗi cho người dùng về một việc
    /// họ không làm.
    static func looksCancelled(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("user canceled")
            || lower.contains("user cancelled")
            || lower.contains("errauthorizationcanceled")
    }

    /// Chạy `arguments` trực tiếp — không qua osascript, không cần quyền
    /// admin, không hộp thoại. Dùng cho lệnh chỉ đọc như
    /// `security verify-cert`, vốn không ghi vào keychain nên không cần
    /// quyền admin.
    public static let runProcessUnprivileged: CommandRunner = { arguments in
        try await execute(arguments: arguments)
    }

    /// Tên cũ, giữ cho call site sẵn có. Giờ hai đường là một: không còn
    /// đường nào chạy dưới quyền root.
    public static let runProcess: CommandRunner = runProcessUnprivileged

    private static func execute(arguments: [String]) async throws -> String {
        guard let first = arguments.first, first.hasPrefix("/") else {
            throw TrustStoreError.commandFailed(
                status: -1,
                output: "Đối số đầu tiên phải là đường dẫn tuyệt đối, nhận được: \(arguments.first ?? "<rỗng>")"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // Thread riêng, KHÔNG phải Task.detached: Task.detached vẫn chạy
            // trên cooperative pool của Swift concurrency, không giải quyết
            // được vấn đề chặn thread nói ở doc comment của runProcess.
            Thread.detachNewThread {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let rawOutput = String(data: data, encoding: .utf8) ?? ""
                let output = rawOutput.replacingOccurrences(of: "\r", with: "\n")

                guard process.terminationStatus == 0 else {
                    // Chạy trực tiếp nên terminationStatus ĐÃ là exit code
                    // thật của `security`, không phải của một lớp bọc.
                    if Self.looksCancelled(output) {
                        continuation.resume(throwing: TrustStoreError.cancelled)
                    } else {
                        continuation.resume(
                            throwing: TrustStoreError.commandFailed(
                                status: process.terminationStatus, output: output))
                    }
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }
}
