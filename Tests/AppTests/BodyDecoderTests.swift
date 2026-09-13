import Testing
import Foundation
@testable import AppCore

/// Giải nén body và hex dump.
///
/// Dữ liệu gzip trong các test này do `/usr/bin/gzip` của hệ thống tạo ra chứ
/// không phải byte tự chế: một test tự sinh dữ liệu nén bằng chính giả định
/// mình đang kiểm thì chỉ chứng minh giả định nhất quán với chính nó.
@Suite("Giải nén body")
struct BodyDecoderTests {

    /// Nén bằng gzip thật của hệ thống.
    static func systemGzip(_ text: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("body")
        try Data(text.utf8).write(to: raw)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-6", raw.path]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: dir.appendingPathComponent("body.gz"))
    }

    @Test("Không có Content-Encoding thì trả nguyên xi")
    func identityPassesThrough() {
        let data = Data("xin chào".utf8)
        #expect(BodyDecoder.decode(data, contentEncoding: nil) == .identity(data))
        #expect(BodyDecoder.decode(data, contentEncoding: "identity") == .identity(data))
    }

    @Test("gzip thật của hệ thống giải ra đúng nội dung gốc")
    func decompressesRealSystemGzip() throws {
        let original = String(repeating: "{\"user\":\"phuoc\",\"ok\":true}\n", count: 400)
        let gzipped = try Self.systemGzip(original)
        #expect(gzipped.count < original.utf8.count, "gzip phải nhỏ hơn bản gốc")

        guard case .decompressed(let out, let encoding, let wire, let truncated) =
                BodyDecoder.decode(gzipped, contentEncoding: "gzip") else {
            Issue.record("mong đợi .decompressed"); return
        }
        #expect(String(data: out, encoding: .utf8) == original)
        #expect(encoding == "gzip")
        #expect(wire == gzipped.count, "phải báo số byte TRÊN DÂY, không phải sau giải nén")
        #expect(truncated == false)
    }

    @Test("Content-Encoding có nhiều giá trị thì lấy cái cuối — đó là lớp nén ngoài cùng")
    func usesLastEncodingInList() throws {
        let gzipped = try Self.systemGzip("hello")
        guard case .decompressed = BodyDecoder.decode(gzipped, contentEncoding: "identity, gzip") else {
            Issue.record("mong đợi .decompressed"); return
        }
    }

    @Test("brotli và zstd: báo KHÔNG HỖ TRỢ, không ngụy trang thành lỗi hỏng")
    func reportsUnsupportedRatherThanFailed() {
        let data = Data(repeating: 0xAB, count: 100)
        #expect(BodyDecoder.decode(data, contentEncoding: "br")
                == .unsupported(encoding: "br", byteCount: 100))
        #expect(BodyDecoder.decode(data, contentEncoding: "zstd")
                == .unsupported(encoding: "zstd", byteCount: 100))
    }

    @Test("Khai gzip nhưng byte không phải gzip: báo failed, không crash")
    func reportsFailureOnCorruptBody() {
        let junk = Data(repeating: 0x41, count: 200)
        #expect(BodyDecoder.decode(junk, contentEncoding: "gzip")
                == .failed(encoding: "gzip", byteCount: 200))
    }

    @Test("Bóc header gzip có FNAME (gzip -k giữ tên file) không làm hỏng payload")
    func handlesGzipHeaderWithFilename() throws {
        let gzipped = try Self.systemGzip("nội dung có dấu tiếng Việt")
        let stripped = BodyDecoder.stripGzipWrapper(gzipped)
        #expect(stripped != nil)
        #expect(stripped!.count < gzipped.count, "phải bỏ bớt header và trailer")
    }

    @Test("Hex dump: đúng định dạng offset + hex + ASCII")
    func hexDumpFormat() {
        let dump = BodyDecoder.hexDump(Data("ABC".utf8))
        #expect(dump.hasPrefix("00000000  41 42 43"))
        #expect(dump.hasSuffix("ABC"))
    }

    @Test("Hex dump: byte không in được thành dấu chấm")
    func hexDumpMasksUnprintable() {
        let dump = BodyDecoder.hexDump(Data([0x00, 0x41, 0xff]))
        #expect(dump.hasSuffix(".A."))
    }

    @Test("Hex dump: vượt limit thì cắt VÀ nói rõ còn bao nhiêu")
    func hexDumpStatesWhatItOmitted() {
        let dump = BodyDecoder.hexDump(Data(repeating: 0x41, count: 5000), limit: 64)
        #expect(dump.contains("còn 4936 byte nữa"))
    }
}
