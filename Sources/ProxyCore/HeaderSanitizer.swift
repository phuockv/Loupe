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
        // Per RFC 9110 §7.6.1, Connection header values are also hop-by-hop.
        var toStrip = hopByHop
        if let connectionValue = headers.first(name: "Connection") {
            for field in connectionValue.split(separator: ",") {
                let trimmed = field.trimmingCharacters(in: .whitespaces).lowercased()
                toStrip.insert(trimmed)
            }
        }

        var result = HTTPHeaders()
        for (name, value) in headers where !toStrip.contains(name.lowercased()) {
            result.add(name: name, value: value)
        }
        return result
    }

    public static func parseAbsoluteForm(_ target: String) -> RequestTarget? {
        guard let components = URLComponents(string: target),
              let scheme = components.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              let host = components.host, !host.isEmpty
        else { return nil }

        let port = components.port ?? (scheme == .https ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }

        var originForm = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { originForm += "?" + query }

        return RequestTarget(
            host: host,
            port: port,
            scheme: scheme,
            originForm: originForm
        )
    }

    public static func parseConnectTarget(_ target: String) -> (host: String, port: Int)? {
        guard !target.isEmpty else { return nil }

        // Check for IPv6 literal with port: must be [host]:port
        if target.hasPrefix("[") {
            guard let closeBracket = target.firstIndex(of: "]") else { return nil }
            let afterBracket = target.index(after: closeBracket)

            // Bare IPv6: [::1] with no port
            if afterBracket == target.endIndex {
                return (target, 443)
            }

            // IPv6 with port: [::1]:port
            guard afterBracket < target.endIndex, target[afterBracket] == ":" else { return nil }
            let portStr = String(target[target.index(after: afterBracket)...])
            guard !portStr.isEmpty, let port = Int(portStr), (1...65535).contains(port) else { return nil }
            return (target[..<closeBracket] + "]", port)
        }

        // IPv4 or hostname: check for port
        if let colon = target.lastIndex(of: ":") {
            let host = String(target[target.startIndex..<colon])
            let portStr = String(target[target.index(after: colon)...])
            guard !host.isEmpty, !portStr.isEmpty, let port = Int(portStr), (1...65535).contains(port) else {
                return nil
            }
            return (host, port)
        }

        // No port specified, default to 443
        return (target, 443)
    }
}
