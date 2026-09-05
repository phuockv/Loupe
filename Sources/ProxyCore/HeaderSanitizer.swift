import Foundation
import NIOHTTP1
import TrafficModel

public struct RequestTarget: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var scheme: Scheme
    public var originForm: String
}

public enum HeaderSanitizer {

    /// RFC 9110 §7.6.1. Proxy phải tiêu thụ, không forward.
    static let hopByHop: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "transfer-encoding",
        "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization",
    ]

    public static func sanitize(_ headers: HTTPHeaders) -> HTTPHeaders {
        var result = HTTPHeaders()
        for (name, value) in headers where !hopByHop.contains(name.lowercased()) {
            result.add(name: name, value: value)
        }
        return result
    }

    public static func parseAbsoluteForm(_ target: String) -> RequestTarget? {
        guard let components = URLComponents(string: target),
              let scheme = components.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              let host = components.host, !host.isEmpty
        else { return nil }

        var originForm = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { originForm += "?" + query }

        return RequestTarget(
            host: host,
            port: components.port ?? (scheme == .https ? 443 : 80),
            scheme: scheme,
            originForm: originForm
        )
    }

    public static func parseConnectTarget(_ target: String) -> (host: String, port: Int)? {
        guard !target.isEmpty else { return nil }
        // Chỉ tách ở dấu ':' cuối cùng để không phá IPv6 dạng [::1]:443.
        guard let colon = target.lastIndex(of: ":"), !target.hasSuffix("]") else {
            return (target, 443)
        }
        let host = String(target[target.startIndex..<colon])
        guard let port = Int(target[target.index(after: colon)...]), !host.isEmpty else {
            return nil
        }
        return (host, port)
    }
}
