import Foundation
import NIOSSL

public struct ProxyConfiguration: Sendable {
    public var listenHost: String
    public var listenPort: Int
    /// Host trong tập này chỉ được tunnel byte thô, không MitM.
    /// Mặc định là các domain pin cert, sẽ hỏng ngay nếu bị chặn.
    public var bypassedHosts: Set<String>
    public var maxInMemoryBodyBytes: Int
    public var bodySpillDirectory: URL

    /// Root TIN THÊM khi verify certificate của upstream. System trust store
    /// vẫn giữ NGUYÊN — đây là cộng thêm, không phải thay thế.
    ///
    /// Đây là cách ĐÚNG DUY NHẤT để chạy được với một origin tự ký (test dựng
    /// origin HTTPS bằng cert do CA của chính test ký). Nó KHÔNG BAO GIỜ được
    /// thay bằng `certificateVerification = .none`: proxy này giải mã rồi mã
    /// hoá lại mọi byte đi qua, nên tắt verify biến nó thành một lỗ hổng thật
    /// cho toàn bộ traffic của người dùng, chứ không chỉ cho test.
    ///
    /// Là property có giá trị mặc định chứ KHÔNG phải tham số init: thêm vào
    /// init sẽ buộc mọi call site hiện có phải biết tới một khái niệm mà
    /// 99% trong số chúng không cần, và giá trị mặc định `[]` đã là hành vi
    /// đúng cho production.
    public var additionalTrustRoots: [NIOSSLCertificate] = []

    public init(
        listenHost: String = "127.0.0.1",
        listenPort: Int = 9090,
        bypassedHosts: Set<String> = [
            "apple.com", "icloud.com", "itunes.apple.com",
            "mzstatic.com", "push.apple.com",
        ],
        maxInMemoryBodyBytes: Int = 2 * 1024 * 1024,
        bodySpillDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyManClone", isDirectory: true)
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.bypassedHosts = bypassedHosts
        self.maxInMemoryBodyBytes = maxInMemoryBodyBytes
        self.bodySpillDirectory = bodySpillDirectory
    }

    /// Khớp cả subdomain: "api.apple.com" khớp mục "apple.com".
    /// Handles trailing dot (FQDN) and case-insensitive matching.
    public func isBypassed(host: String) -> Bool {
        var lower = host.lowercased()
        if lower.hasSuffix(".") {
            lower.removeLast()
        }
        return bypassedHosts.contains { lower == $0.lowercased() || lower.hasSuffix("." + $0.lowercased()) }
    }
}
