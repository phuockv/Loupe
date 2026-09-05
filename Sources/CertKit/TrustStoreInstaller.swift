import Foundation

public typealias CommandRunner = @Sendable ([String]) async throws -> String

public protocol TrustStoreInstaller: Sendable {
    func isInstalled(commonName: String) async throws -> Bool
    func install(pemPath: URL) async throws
}

public enum TrustStoreError: Error, Sendable {
    case commandFailed(status: Int32, output: String)
}

/// Cài CA qua lệnh `security`. Bước ghi vào System keychain cần quyền admin
/// nên chạy qua osascript, macOS sẽ hiện hộp thoại xin mật khẩu.
///
/// `isInstalled` cũng đi qua cùng `runner`, nên với implementation mặc định
/// (`runProcess`), MỌI lệnh — kể cả `find-certificate` chỉ đọc, vốn không cần
/// quyền admin — đều bị bọc qua osascript "with administrator privileges" và
/// sẽ hiện hộp thoại xin mật khẩu. Đây là giới hạn đã biết của thiết kế một
/// runner duy nhất; xem báo cáo Task 9 để biết chi tiết.
///
/// Toàn bộ phần cần quyền admin nằm sau protocol này: khi chốt hướng
/// ký/phân phối (privileged helper, SMAppService...), chỉ cần thêm impl mới
/// mà không đụng tới engine.
public struct SecurityCommandInstaller: TrustStoreInstaller {
    private let runner: CommandRunner

    public init(runner: @escaping CommandRunner = SecurityCommandInstaller.runProcess) {
        self.runner = runner
    }

    public func isInstalled(commonName: String) async throws -> Bool {
        let output = try await runner([
            "/usr/bin/security", "find-certificate", "-c", commonName,
            "/Library/Keychains/System.keychain",
        ])
        return output.contains(commonName)
    }

    public func install(pemPath: URL) async throws {
        _ = try await runner([
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", pemPath.path,
        ])
    }

    /// Chạy `arguments` với quyền administrator qua `osascript`.
    ///
    /// Đường đi này có HAI lớp quoting chồng nhau — shell (bên trong
    /// `do shell script`) và AppleScript string literal (nguồn kịch bản
    /// truyền cho osascript) — nên tự tay escape một chuỗi bất kỳ để nội suy
    /// an toàn vào CẢ HAI lớp cùng lúc là rất dễ sai (backslash, dấu nháy
    /// đơn/kép, `$(...)`, newline đều là điểm rơi). Cách ở đây né hẳn việc
    /// nội suy: script AppleScript là một literal CỐ ĐỊNH, không bao giờ
    /// chứa nội dung của `arguments`. `arguments` được truyền cho osascript
    /// như tham số dòng lệnh thật (qua mảng argument của `Process`, tức
    /// `execve`, không qua `/bin/sh`), rồi bên trong script, `argv` (từ
    /// `on run argv`) được duyệt và mỗi phần tử được đưa qua `quoted form of`
    /// — hàm dựng sẵn của AppleScript chuyên escape một chuỗi để dùng an toàn
    /// làm một "từ" trong dòng lệnh shell — trước khi nối bằng dấu cách và
    /// chạy bằng `do shell script ... with administrator privileges`. Đã
    /// kiểm tay bằng osascript thật (không qua admin) với các input: dấu
    /// nháy đơn, dấu nháy kép, backslash, `$(...)`, newline nhúng trong một
    /// argument, chuỗi rỗng, và đường dẫn có khoảng trắng (như chính thư mục
    /// làm việc của project này) — không lệnh nào bị inject, mọi argument đi
    /// qua nguyên vẹn thành một token duy nhất.
    ///
    /// Không dùng `--` để tách "hết flag, tới positional args": osascript
    /// không tự bỏ `--` khỏi `argv`, nên nó sẽ lọt vào làm phần tử đầu của
    /// `argv` và phá lệnh — thứ tự tham số ở đây là những gì đã kiểm tay là
    /// đúng, không phải suy đoán.
    ///
    /// Lưu ý: `do shell script` chuyển line ending trong text trả về từ LF
    /// sang CR (hành vi đã biết của AppleScript, không phải lỗi ở đây).
    /// `isInstalled` chỉ làm `.contains(commonName)` nên không bị ảnh hưởng;
    /// `install` bỏ qua output. Hàm này chuẩn hoá CR về LF trước khi trả về
    /// để bất kỳ caller nào sau này parse theo dòng không bị bất ngờ.
    public static let runProcess: CommandRunner = { arguments in
        let script = """
        on run argv
            set cmd to ""
            repeat with anArg in argv
                if cmd is not "" then set cmd to cmd & " "
                set cmd to cmd & quoted form of (anArg as text)
            end repeat
            do shell script cmd with administrator privileges
        end run
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rawOutput = String(data: data, encoding: .utf8) ?? ""
        let output = rawOutput.replacingOccurrences(of: "\r", with: "\n")
        guard process.terminationStatus == 0 else {
            throw TrustStoreError.commandFailed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
