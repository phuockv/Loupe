import Foundation
import Compression

/// Giải nén body để HIỂN THỊ, và dựng hex dump cho dữ liệu nhị phân thật.
///
/// Body luôn được LƯU nguyên dạng đi trên dây. Giải nén chỉ xảy ra lúc render,
/// và UI nói rõ nó đã giải nén — vì thứ thật sự đi qua dây mới là cái công cụ
/// này tồn tại để cho xem, còn bản giải nén chỉ là một cách đọc nó.
public enum BodyDecoder {

    /// Trần giải nén. Một file gzip 40 KB có thể phình ra hàng gigabyte
    /// (decompression bomb), và body ở đây đến từ server bất kỳ — không phải
    /// nguồn tin cậy. Vượt trần thì trả phần đã giải được và nói rõ là cắt.
    public static let maxDecompressedBytes = 16 * 1024 * 1024

    public enum Result: Equatable {
        /// Không nén, hoặc không khai báo nén.
        case identity(Data)
        /// Đã giải nén được. `originalByteCount` là số byte trên dây.
        case decompressed(Data, encoding: String, originalByteCount: Int, truncated: Bool)
        /// Có khai báo nén nhưng thuật toán không hỗ trợ (`br`, `zstd`).
        case unsupported(encoding: String, byteCount: Int)
        /// Khai báo nén nhưng giải không ra — body hỏng, hoặc khai báo sai.
        case failed(encoding: String, byteCount: Int)
    }

    /// `Compression` của Apple có gzip/deflate nhưng KHÔNG có brotli và zstd.
    /// Trình duyệt gửi cả bốn trong `Accept-Encoding`, nên hai cái sau sẽ gặp
    /// thật — và được báo là không hỗ trợ chứ không bị ngụy trang thành lỗi.
    static let supported: Set<String> = ["gzip", "x-gzip", "deflate"]

    public static func decode(_ data: Data, contentEncoding: String?) -> Result {
        let encoding = (contentEncoding ?? "")
            .split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""

        guard !encoding.isEmpty, encoding != "identity" else { return .identity(data) }
        guard supported.contains(encoding) else {
            return .unsupported(encoding: encoding, byteCount: data.count)
        }

        let payload: Data
        if encoding == "gzip" || encoding == "x-gzip" {
            guard let stripped = stripGzipWrapper(data) else {
                return .failed(encoding: encoding, byteCount: data.count)
            }
            payload = stripped
        } else {
            payload = stripZlibWrapperIfPresent(data)
        }

        guard let (inflated, truncated) = inflate(payload) else {
            return .failed(encoding: encoding, byteCount: data.count)
        }
        return .decompressed(inflated, encoding: encoding,
                             originalByteCount: data.count, truncated: truncated)
    }

    // MARK: - gzip / zlib wrapper

    /// Bỏ header và trailer của gzip (RFC 1952), để lại DEFLATE thô.
    /// `COMPRESSION_ZLIB` của Apple là DEFLATE THÔ (RFC 1951), không phải
    /// zlib-wrapped, nên phải tự bóc lớp vỏ.
    static func stripGzipWrapper(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flags = bytes[3]
        var i = 10
        func need(_ n: Int) -> Bool { i + n <= bytes.count - 8 }

        if flags & 0x04 != 0 {                     // FEXTRA
            guard need(2) else { return nil }
            let extra = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
            guard need(extra) else { return nil }
            i += extra
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {   // FNAME, FCOMMENT
            while i < bytes.count - 8, bytes[i] != 0 { i += 1 }
            guard i < bytes.count - 8 else { return nil }
            i += 1
        }
        if flags & 0x02 != 0 {                     // FHCRC
            guard need(2) else { return nil }
            i += 2
        }
        guard i < bytes.count - 8 else { return nil }
        return data.subdata(in: i..<(data.count - 8))
    }

    /// `Content-Encoding: deflate` trên thực tế thường là zlib-wrapped
    /// (RFC 1950) chứ không phải DEFLATE thô, dù tên gọi nói ngược lại.
    /// Nhận diện qua 2 byte header rồi bóc; không khớp thì coi như thô.
    static func stripZlibWrapperIfPresent(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 2, bytes[0] & 0x0f == 0x08 else { return data }
        let check = (Int(bytes[0]) << 8) | Int(bytes[1])
        guard check % 31 == 0 else { return data }
        return data.subdata(in: 2..<data.count)
    }

    // MARK: - DEFLATE

    /// Trả `(dữ liệu, đã bị cắt vì chạm trần chưa)`, hoặc `nil` nếu giải hỏng.
    static func inflate(_ deflated: Data) -> (Data, Bool)? {
        guard !deflated.isEmpty else { return (Data(), false) }

        let chunk = 64 * 1024
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }

        var stream = compression_stream(dst_ptr: out, dst_size: chunk,
                                        src_ptr: out, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        return deflated.withUnsafeBytes { raw -> (Data, Bool)? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = raw.count

            var result = Data()
            while true {
                stream.dst_ptr = out
                stream.dst_size = chunk
                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                let produced = chunk - stream.dst_size
                if produced > 0 { result.append(out, count: produced) }

                switch status {
                case COMPRESSION_STATUS_END:
                    return (result, false)
                case COMPRESSION_STATUS_OK:
                    if result.count >= maxDecompressedBytes {
                        return (result.prefix(maxDecompressedBytes), true)
                    }
                    // Không tiêu thụ được gì và cũng không sinh ra gì: bế tắc.
                    // Thoát thay vì quay vòng vô hạn.
                    if produced == 0, stream.src_size == 0 { return nil }
                default:
                    return nil
                }
            }
        }
    }

    // MARK: - Hex dump

    /// Hex dump kiểu `xxd`: offset, 16 byte hex, cột ASCII.
    ///
    /// `limit` có chủ ý: render vài megabyte vào một `Text` làm treo UI, và
    /// dữ liệu nhị phân thì vài trăm dòng đầu đã đủ để nhận ra nó là gì.
    public static func hexDump(_ data: Data, limit: Int = 4 * 1024) -> String {
        let slice = [UInt8](data.prefix(limit))
        var lines: [String] = []
        for offset in stride(from: 0, to: slice.count, by: 16) {
            let row = slice[offset..<min(offset + 16, slice.count)]
            let hex = row.map { String(format: "%02x", $0) }
                .joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = row.map { $0 >= 0x20 && $0 < 0x7f ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %@  %@", offset, hex, ascii))
        }
        if data.count > limit {
            lines.append("… còn \(data.count - limit) byte nữa, không hiện")
        }
        return lines.joined(separator: "\n")
    }
}
