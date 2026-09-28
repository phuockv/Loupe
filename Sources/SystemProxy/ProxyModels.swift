import Foundation

/// Nhận diện host trỏ về chính máy này.
///
/// Danh sách CỐ TÌNH hẹp: đúng ba chuỗi, không nhận cả dải `127.0.0.0/8`.
/// Người cố ý đặt proxy ở `127.0.0.2` đang trỏ vào một thứ khác đang chạy
/// trên máy, không phải vào ta — và luật này được dùng để quyết định có xoá
/// một cấu hình của người dùng hay không, nên nhận rộng là hỏng theo hướng
/// tốn kém.
public enum Loopback {
    public static func isLoopback(_ host: String) -> Bool {
        switch host.lowercased() {
        case "127.0.0.1", "::1", "localhost": return true
        default: return false
        }
    }
}

/// Trạng thái proxy của MỘT giao thức (HTTP hoặc HTTPS) trên MỘT dịch vụ.
public struct ProxySetting: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var server: String
    public var port: Int

    public init(enabled: Bool, server: String, port: Int) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }

    public static let off = ProxySetting(enabled: false, server: "", port: 0)

    /// Cấu hình này có đang trỏ vào đúng `host:port` không.
    public func pointsAt(host: String, port: Int) -> Bool {
        enabled && Loopback.isLoopback(server) && Loopback.isLoopback(host) && self.port == port
    }

    /// Giá trị sẽ ghi vào snapshot làm "trạng thái nguyên bản".
    ///
    /// Thấy dấu vết của CHÍNH app (loopback + đúng cổng sắp đặt) thì ghi nhận
    /// là tắt. Không có luật này, mớ cũ còn sót trên máy sẽ bị đóng băng
    /// thành "nguyên bản" và mỗi lần Dừng lại đặt máy về đúng trạng thái mất
    /// mạng — tính năng sinh ra để sửa lỗi đó sẽ tự tái tạo nó vĩnh viễn.
    ///
    /// Điều kiện PHẢI khớp cả cổng: một Charles ở `127.0.0.1:8888` cũng là
    /// loopback nhưng không phải dấu vết của ta.
    public func normalizedAsOriginal(appliedHost: String, appliedPort: Int) -> ProxySetting {
        pointsAt(host: appliedHost, port: appliedPort) ? .off : self
    }
}

public struct ServiceProxySnapshot: Sendable, Equatable, Codable {
    public var service: String
    public var web: ProxySetting
    public var secureWeb: ProxySetting

    public init(service: String, web: ProxySetting, secureWeb: ProxySetting) {
        self.service = service
        self.web = web
        self.secureWeb = secureWeb
    }
}

public struct ProxySnapshot: Sendable, Equatable, Codable {
    public var takenAt: Date
    /// Host app đã đặt. Lưu lại để nhận ra dấu vết của chính mình về sau.
    public var appliedHost: String
    /// Cổng app đã đặt — cổng THẬT SỰ bind được, không phải cổng trong cấu
    /// hình. Hai giá trị đó khác nhau khi cấu hình dùng cổng 0.
    public var appliedPort: Int
    public var services: [ServiceProxySnapshot]

    public init(takenAt: Date, appliedHost: String, appliedPort: Int,
                services: [ServiceProxySnapshot]) {
        self.takenAt = takenAt
        self.appliedHost = appliedHost
        self.appliedPort = appliedPort
        self.services = services
    }
}
