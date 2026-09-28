import Foundation

public typealias CommandRunner = @Sendable ([String]) async throws -> String

public enum SystemProxyError: Error, Sendable, Equatable {
    case commandFailed(status: Int32, output: String)
    /// `networksetup` chạy xong exit 0 nhưng output không đúng định dạng kỳ
    /// vọng. Tách riêng khỏi `commandFailed` vì nó KHÔNG được phép im lặng
    /// rơi về "đang tắt": đoán sai theo hướng đó sẽ làm ta ghi đè một cấu
    /// hình thật của người dùng bằng một giá trị bịa ra.
    case unreadableOutput(command: String, output: String)
    case snapshotUnreadable(String)
}

extension SystemProxyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Lệnh mạng thất bại (mã \(status))."
                : "Lệnh mạng thất bại (mã \(status)): \(trimmed)"
        case .unreadableOutput(let command, let output):
            return "Không đọc được kết quả của \(command): \(output)"
        case .snapshotUnreadable(let reason):
            return "Không đọc được file trạng thái proxy đã lưu: \(reason)"
        }
    }
}

/// Đọc và ghi cài đặt proxy của MỘT dịch vụ mạng mỗi lần.
///
/// Việc điều phối nhiều dịch vụ, quản file snapshot và chuẩn hoá nằm ở
/// `SystemProxyController`, không nằm ở đây — lớp này chỉ biết dịch một thao
/// tác thành lệnh và dịch output thành kiểu dữ liệu.
public protocol SystemProxyConfiguring: Sendable {
    func activeServices() async throws -> [String]
    func read(service: String) async throws -> ServiceProxySnapshot
    func apply(host: String, port: Int, to service: String) async throws
    func restore(_ snapshot: ServiceProxySnapshot) async throws
}
