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
    /// Ít nhất một dịch vụ không khôi phục được — nhưng những dịch vụ CÒN
    /// LẠI đã được thử xong trước khi lỗi này được ném.
    ///
    /// Bỏ dở vòng lặp ở dịch vụ hỏng đầu tiên (VPN vừa sập, cáp vừa rút) là
    /// để lại mọi dịch vụ phía sau trỏ vào một cổng sắp chết — đúng cái §7.3
    /// cấm. Ném ở CUỐI cũng là thứ giữ lại file snapshot: `disable()` chỉ
    /// xoá file khi hàm này trả về bình thường.
    case restoreIncomplete(services: [String])
    /// `enable` được gọi với host không phải loopback.
    ///
    /// Luật nhận diện dấu vết của chính app (§2.3) CHỈ khớp host loopback,
    /// nên một host LAN sẽ làm `pointsAt` luôn trả về false: app sẽ chụp
    /// chính cấu hình của mình làm "nguyên bản" và đường về mất vĩnh viễn —
    /// im lặng, không lỗi, không test nào đỏ. Chặn ồn ào ngay ở cửa vào thay
    /// vì nới lỏng `pointsAt`.
    case nonLoopbackHost(String)
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
        case .restoreIncomplete(let services):
            return "Không trả lại được cài đặt proxy cho: \(services.joined(separator: ", "))"
        case .nonLoopbackHost(let host):
            return "Host đặt proxy phải là loopback, nhận được \"\(host)\"."
        }
    }
}

/// Một trong hai giao thức proxy mà tính năng này quản (§ phi mục tiêu: không
/// SOCKS, FTP, Gopher, PAC).
///
/// Tồn tại vì mọi quyết định khôi phục đều xét TỪNG FIELD riêng: người dùng
/// hay chỉ đổi một field và để yên field kia. Không có kiểu này thì lớp dưới
/// buộc phải phát lệnh cho cả hai field mỗi lần, tức ghi đè luôn field người
/// dùng vừa đổi.
public enum ProxyField: String, Sendable, Equatable, CaseIterable, Codable {
    case web
    case secureWeb

    var setCommand: String {
        switch self {
        case .web: return "-setwebproxy"
        case .secureWeb: return "-setsecurewebproxy"
        }
    }

    var stateCommand: String {
        switch self {
        case .web: return "-setwebproxystate"
        case .secureWeb: return "-setsecurewebproxystate"
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
    /// Trả lại ĐÚNG MỘT field. Người gọi quyết định field nào đáng đụng vào;
    /// lớp này không được tự ý phát lệnh cho field kia.
    func restore(_ setting: ProxySetting, field: ProxyField, of service: String) async throws
}
