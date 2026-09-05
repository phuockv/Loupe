import Testing
import NIOHTTP1
import TrafficModel
@testable import ProxyCore

@Suite("HeaderSanitizer")
struct HeaderSanitizerTests {

    @Test("Parse absolute-form http có path và query")
    func parsesAbsoluteFormHTTP() {
        let target = HeaderSanitizer.parseAbsoluteForm("http://example.com/a/b?c=1")
        #expect(target == RequestTarget(host: "example.com", port: 80,
                                        scheme: .http, originForm: "/a/b?c=1"))
    }

    @Test("Absolute-form không có path thì origin-form là /")
    func defaultsEmptyPathToSlash() {
        let target = HeaderSanitizer.parseAbsoluteForm("http://example.com")
        #expect(target?.originForm == "/")
    }

    @Test("Port tường minh được giữ nguyên")
    func keepsExplicitPort() {
        let target = HeaderSanitizer.parseAbsoluteForm("http://example.com:8080/x")
        #expect(target?.port == 8080)
    }

    @Test("https absolute-form mặc định port 443")
    func defaultsHTTPSPort() {
        let target = HeaderSanitizer.parseAbsoluteForm("https://example.com/x")
        #expect(target?.scheme == .https)
        #expect(target?.port == 443)
    }

    @Test("Origin-form không phải absolute-form, trả nil")
    func rejectsOriginForm() {
        #expect(HeaderSanitizer.parseAbsoluteForm("/a/b") == nil)
    }

    @Test("Parse CONNECT host:port")
    func parsesConnectTarget() {
        let target = HeaderSanitizer.parseConnectTarget("example.com:443")
        #expect(target?.host == "example.com")
        #expect(target?.port == 443)
    }

    @Test("CONNECT thiếu port thì mặc định 443")
    func connectDefaultsTo443() {
        #expect(HeaderSanitizer.parseConnectTarget("example.com")?.port == 443)
    }

    @Test("Gỡ đúng các header hop-by-hop, giữ nguyên header end-to-end")
    func stripsHopByHopHeaders() {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "example.com")
        headers.add(name: "Proxy-Connection", value: "keep-alive")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        headers.add(name: "Authorization", value: "Bearer abc")

        let clean = HeaderSanitizer.sanitize(headers)
        #expect(clean.first(name: "Host") == "example.com")
        #expect(clean.first(name: "Authorization") == "Bearer abc")
        #expect(clean.first(name: "Proxy-Connection") == nil)
        #expect(clean.first(name: "Connection") == nil)
        // NIO tự dựng lại framing theo body thật; forward header gốc sinh framing kép.
        #expect(clean.first(name: "Transfer-Encoding") == nil)
    }

    @Test("Header lặp được giữ đủ, không gộp")
    func preservesRepeatedHeaders() {
        var headers = HTTPHeaders()
        headers.add(name: "Set-Cookie", value: "a=1")
        headers.add(name: "Set-Cookie", value: "b=2")
        #expect(HeaderSanitizer.sanitize(headers)["Set-Cookie"].count == 2)
    }
}
