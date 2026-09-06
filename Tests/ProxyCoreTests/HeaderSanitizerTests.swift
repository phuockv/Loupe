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

    // Edge cases and correctness tests

    @Test("Connection header value makes field hop-by-hop")
    func connectionHeaderNamesList() {
        var headers = HTTPHeaders()
        headers.add(name: "X-Custom", value: "value")
        headers.add(name: "Connection", value: "X-Custom")
        headers.add(name: "Authorization", value: "Bearer abc")

        let clean = HeaderSanitizer.sanitize(headers)
        #expect(clean.first(name: "X-Custom") == nil)
        #expect(clean.first(name: "Authorization") == "Bearer abc")
        #expect(clean.first(name: "Connection") == nil)
    }

    /// RFC 9110 cho phép `Connection` xuất hiện trên NHIỀU dòng field, và một
    /// client/origin thật hoàn toàn có thể gửi như vậy. Đọc mỗi dòng ĐẦU
    /// (`first(name:)`) thì mọi tên chỉ được nêu ở dòng sau được forward
    /// nguyên — tức proxy chuyển tiếp đúng thứ RFC bảo nó phải tiêu thụ.
    @Test("Connection trải trên NHIỀU dòng field: tên ở dòng sau cũng là hop-by-hop")
    func connectionHeaderAcrossMultipleFieldLines() {
        var headers = HTTPHeaders()
        headers.add(name: "X-First", value: "1")
        headers.add(name: "X-Second", value: "2")
        headers.add(name: "X-Third", value: "3")
        headers.add(name: "Connection", value: "X-First")
        // Dòng thứ hai, và có cả dạng nhiều tên phân tách bằng dấu phẩy kèm
        // khoảng trắng — cả hai phải cùng được xử lý.
        headers.add(name: "Connection", value: "X-Second, X-Third")
        headers.add(name: "Authorization", value: "Bearer abc")

        let clean = HeaderSanitizer.sanitize(headers)
        #expect(clean.first(name: "X-First") == nil)
        #expect(clean.first(name: "X-Second") == nil,
                "tên nêu ở dòng Connection THỨ HAI vẫn phải bị gỡ")
        #expect(clean.first(name: "X-Third") == nil,
                "tên sau dấu phẩy trên dòng Connection thứ hai vẫn phải bị gỡ")
        #expect(clean.first(name: "Authorization") == "Bearer abc")
        #expect(clean.first(name: "Connection") == nil)
    }

    @Test("Port out of range in parseAbsoluteForm returns nil")
    func absoluteFormOutOfRangePort() {
        #expect(HeaderSanitizer.parseAbsoluteForm("http://example.com:99999") == nil)
        #expect(HeaderSanitizer.parseAbsoluteForm("http://example.com:0") == nil)
        #expect(HeaderSanitizer.parseAbsoluteForm("http://example.com:65536") == nil)
    }

    @Test("parseConnectTarget IPv6 with port [::1]:443")
    func connectIPv6WithPort() {
        let target = HeaderSanitizer.parseConnectTarget("[::1]:443")
        #expect(target?.host == "[::1]")
        #expect(target?.port == 443)
    }

    @Test("parseConnectTarget bare IPv6 [::1] defaults to 443")
    func connectIPv6Bare() {
        let target = HeaderSanitizer.parseConnectTarget("[::1]")
        #expect(target?.host == "[::1]")
        #expect(target?.port == 443)
    }

    @Test("parseConnectTarget malformed IPv6 [::1 returns nil")
    func connectIPv6Malformed() {
        #expect(HeaderSanitizer.parseConnectTarget("[::1") == nil)
    }

    @Test("parseConnectTarget empty string returns nil")
    func connectEmptyString() {
        #expect(HeaderSanitizer.parseConnectTarget("") == nil)
    }

    @Test("parseConnectTarget missing host before colon returns nil")
    func connectMissingHost() {
        #expect(HeaderSanitizer.parseConnectTarget(":443") == nil)
    }

    @Test("parseConnectTarget missing port after colon returns nil")
    func connectMissingPort() {
        #expect(HeaderSanitizer.parseConnectTarget("example.com:") == nil)
    }

    @Test("parseConnectTarget non-numeric port returns nil")
    func connectNonNumericPort() {
        #expect(HeaderSanitizer.parseConnectTarget("example.com:notanumber") == nil)
    }

    @Test("parseConnectTarget out of range port returns nil")
    func connectOutOfRangePort() {
        #expect(HeaderSanitizer.parseConnectTarget("example.com:99999") == nil)
        #expect(HeaderSanitizer.parseConnectTarget("example.com:0") == nil)
        #expect(HeaderSanitizer.parseConnectTarget("example.com:-443") == nil)
    }

    @Test("isBypassed matches trailing-dot FQDN")
    func bypassedTrailingDot() {
        let config = ProxyConfiguration()
        #expect(config.isBypassed(host: "apple.com."))
    }

    @Test("isBypassed does not match unrelated hosts")
    func bypassedNotmatching() {
        let config = ProxyConfiguration()
        #expect(!config.isBypassed(host: "notapple.com"))
    }

    @Test("isBypassed does not match partial subdomain")
    func bypassedPartialSubdomain() {
        let config = ProxyConfiguration()
        #expect(!config.isBypassed(host: "apple.com.evil.com"))
    }

    @Test("isBypassed case-insensitive matching")
    func bypassedCaseInsensitive() {
        let config = ProxyConfiguration()
        #expect(config.isBypassed(host: "API.APPLE.COM"))
    }

    @Test("isBypassed subdomain with custom bypass list")
    func bypassedSubdomain() {
        let config = ProxyConfiguration(bypassedHosts: ["example.com"])
        #expect(config.isBypassed(host: "api.example.com"))
        #expect(config.isBypassed(host: "api.example.com."))
    }

    /// `isIPLiteral` bảo vệ đúng một thứ: `ClientBootstrap.connect(host:)`, tức
    /// `getaddrinfo`. Nên nó phải nhận ĐÚNG những dạng `getaddrinfo` coi là địa
    /// chỉ số — kể cả các dạng lịch sử mà `inet_pton` từ chối. Lọt một dạng
    /// nghĩa là mint một leaf `dNSName` cho một chuỗi không client nào chấp
    /// nhận, rồi người dùng nhận một lỗi TLS khó đoán.
    @Test("isIPLiteral nhận cả dạng IPv4 lịch sử mà getaddrinfo chấp nhận")
    func detectsHistoricalIPv4Forms() {
        for host in ["127.0.0.1", "192.0.2.1", "0x7f000001", "127.1", "2130706433", "0177.0.0.1"] {
            #expect(HeaderSanitizer.isIPLiteral(host), "phải coi \(host) là IP")
        }
    }

    @Test("isIPLiteral nhận IPv6, cả dạng còn ngoặc của parseConnectTarget")
    func detectsIPv6IncludingBracketedForm() {
        #expect(HeaderSanitizer.isIPLiteral("::1"))
        #expect(HeaderSanitizer.isIPLiteral("2001:db8::1"))
        #expect(HeaderSanitizer.isIPLiteral("[2001:db8::1]"))
    }

    /// Vế còn lại, và là vế `inet_aton` dễ làm hỏng: một tên miền thật KHÔNG
    /// được coi là IP, nếu không thì MitM chết cho mọi host.
    @Test("isIPLiteral không nhận tên miền")
    func doesNotTreatHostnamesAsIP() {
        for host in ["localhost", "example.com", "api.example.com", "1.example.com",
                     "127.0.0.1.example.com", ""] {
            #expect(!HeaderSanitizer.isIPLiteral(host), "\(host) không phải IP")
        }
    }
}
