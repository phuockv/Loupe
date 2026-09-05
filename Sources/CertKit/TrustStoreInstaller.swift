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
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", pemPath.path,
        ])
    }

    // MARK: - Command execution

    /// Rút số exit code thật từ message lỗi mà AppleScript đính kèm khi
    /// `do shell script` thất bại — dạng "... (<n>)" ở cuối message, ví dụ
    /// "The command exited with a non-zero status. (42)" hay
    /// "User canceled. (-128)". `osascript` (tiến trình) luôn thoát 1 cho
    /// MỌI lỗi kịch bản, nên exit code của chính nó không phân biệt được
    /// nguyên nhân; số trong ngoặc mới là exit code thật của lệnh bên
    /// trong, hoặc mã lỗi AppleScript (như -128 khi người dùng bấm Cancel).
    /// Trả `nil` nếu message không theo đúng dạng đó.
    static func parseExitStatus(from output: String) -> Int32? {
        guard let openParen = output.lastIndex(of: "("),
            let closeParen = output[openParen...].firstIndex(of: ")"),
            openParen < closeParen
        else { return nil }
        return Int32(output[output.index(after: openParen)..<closeParen])
    }

    /// Script AppleScript cố định dùng cho lệnh cần quyền admin. KHÔNG bao
    /// giờ nội suy nội dung của `arguments` vào đây — xem giải thích đầy đủ
    /// ở `runProcess`.
    private static let privilegedScript = """
        on run argv
            set cmd to ""
            repeat with anArg in argv
                if cmd is not "" then set cmd to cmd & " "
                set cmd to cmd & quoted form of (anArg as text)
            end repeat
            do shell script cmd with administrator privileges
        end run
        """

    /// Chạy `arguments` với quyền administrator qua `osascript`.
    ///
    /// Đường đi này có HAI lớp quoting chồng nhau — shell (bên trong
    /// `do shell script`) và AppleScript string literal (nguồn kịch bản
    /// truyền cho osascript) — nên tự tay escape một chuỗi bất kỳ để nội suy
    /// an toàn vào CẢ HAI lớp cùng lúc là rất dễ sai (backslash, dấu nháy
    /// đơn/kép, `$(...)`, newline đều là điểm rơi). Cách ở đây né hẳn việc
    /// nội suy: script AppleScript (`privilegedScript`) là một literal CỐ
    /// ĐỊNH, không bao giờ chứa nội dung của `arguments`. `arguments` được
    /// truyền cho osascript như tham số dòng lệnh thật (qua mảng argument
    /// của `Process`, tức `execve`, không qua `/bin/sh`), rồi bên trong
    /// script, `argv` (từ `on run argv`) được duyệt và mỗi phần tử được đưa
    /// qua `quoted form of` — hàm dựng sẵn của AppleScript chuyên escape một
    /// chuỗi để dùng an toàn làm một "từ" trong dòng lệnh shell — trước khi
    /// nối bằng dấu cách và chạy bằng
    /// `do shell script ... with administrator privileges`. Đã kiểm tay
    /// bằng osascript thật (không qua admin) với các input: dấu nháy
    /// đơn/kép, backslash, `$(...)`, newline nhúng trong một argument, chuỗi
    /// rỗng, và đường dẫn có khoảng trắng (như chính thư mục làm việc của
    /// project này) — không lệnh nào bị inject, mọi argument đi qua nguyên
    /// vẹn thành một token duy nhất.
    ///
    /// Đối số đầu tiên của `arguments` PHẢI là đường dẫn tuyệt đối (guard
    /// bên dưới ép điều này): sau khi tiêu thụ cặp `-e privilegedScript`,
    /// osascript tiếp tục parse các phần tử còn lại bằng chính flag-parser
    /// của nó — một phần tử đúng bằng `"-e"` ở vị trí đó KHÔNG được xem là
    /// dữ liệu cho script, mà bị hiểu là một lệnh `-e` thứ hai, nối thêm một
    /// dòng AppleScript nữa vào script đang biên dịch. Đã kiểm tay: chạy
    /// `osascript -e '<privilegedScript>' -e 'return "INJECTED"'` khiến
    /// osascript biên dịch CẢ HAI làm một script (ở đây báo lỗi cú pháp vì
    /// đụng hai `on run` handler, nhưng với script khác việc nối này có thể
    /// biên dịch và chạy được — tức chạy AppleScript do "argument" quyết
    /// định). Hai caller hiện tại luôn truyền `/usr/bin/security` làm phần
    /// tử đầu nên không chạm vào đường này, nhưng đây là hàm `public`, nên
    /// bất biến đó cần được CHÍNH HÀM ép, không phải chỉ dựa vào quy ước của
    /// caller.
    ///
    /// Lưu ý: `do shell script` chuyển line ending trong text trả về từ LF
    /// sang CR (hành vi đã biết của AppleScript, không phải lỗi ở đây). Hàm
    /// này chuẩn hoá CR về LF trước khi trả về để caller parse theo dòng
    /// không bị bất ngờ.
    ///
    /// Chạy trên một thread riêng (không phải cooperative pool của Swift
    /// concurrency): `process.run()`/đọc pipe/`waitUntilExit()` chặn đồng bộ
    /// cho tới khi người dùng đóng hộp thoại xin mật khẩu, có thể vô hạn
    /// nếu họ bỏ đi — chặn một thread trong cooperative pool (rộng bằng số
    /// core) sẽ làm cạn pool đó cho các Task khác, dù UI không đơ vì SwiftUI
    /// không dùng thread đó.
    public static let runProcess: CommandRunner = { arguments in
        try await execute(arguments: arguments, privileged: true)
    }

    /// Chạy `arguments` trực tiếp — không qua osascript, không cần quyền
    /// admin, không hộp thoại. Dùng cho lệnh chỉ đọc như
    /// `security verify-cert`, vốn không ghi vào keychain nên không cần
    /// quyền admin.
    public static let runProcessUnprivileged: CommandRunner = { arguments in
        try await execute(arguments: arguments, privileged: false)
    }

    private static func execute(arguments: [String], privileged: Bool) async throws -> String {
        guard let first = arguments.first, first.hasPrefix("/") else {
            throw TrustStoreError.commandFailed(
                status: -1,
                output: "Đối số đầu tiên phải là đường dẫn tuyệt đối, nhận được: \(arguments.first ?? "<rỗng>")"
            )
        }

        let process = Process()
        if privileged {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", privilegedScript] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: first)
            process.arguments = Array(arguments.dropFirst())
        }
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
                    guard privileged else {
                        // Không qua osascript: terminationStatus đã là exit
                        // code thật, không cần rút số từ message.
                        continuation.resume(
                            throwing: TrustStoreError.commandFailed(
                                status: process.terminationStatus, output: output
                            )
                        )
                        return
                    }
                    let status = parseExitStatus(from: output) ?? process.terminationStatus
                    if status == -128 {
                        continuation.resume(throwing: TrustStoreError.cancelled)
                    } else {
                        continuation.resume(
                            throwing: TrustStoreError.commandFailed(status: status, output: output)
                        )
                    }
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }
}
