import Foundation

public struct ProxyConfiguration: Sendable {
    public var listenHost: String
    public var listenPort: Int
    /// Host trong tập này chỉ được tunnel byte thô, không MitM.
    /// Mặc định là các domain pin cert, sẽ hỏng ngay nếu bị chặn.
    public var bypassedHosts: Set<String>
    public var maxInMemoryBodyBytes: Int
    public var bodySpillDirectory: URL

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
    public func isBypassed(host: String) -> Bool {
        let lower = host.lowercased()
        return bypassedHosts.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }
}
