// Sources/SystemProxy/ProxySnapshotStore.swift
import Foundation

/// Lưu trạng thái proxy nguyên bản ra đĩa.
///
/// Đây là toàn bộ đường về sau một lần crash, nên `write` phải `fsync`: dữ
/// liệu nằm trong page cache mà máy mất điện thì file rỗng, và một file
/// snapshot rỗng còn tệ hơn không có file — nó nói dối rằng đã lưu xong.
public struct ProxySnapshotStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyManClone", isDirectory: true)
            .appendingPathComponent("system-proxy-snapshot.json")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func write(_ snapshot: ProxySnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)

        // `.atomic` đảm bảo file không bị đọc thấy ở trạng thái nửa vời,
        // nhưng KHÔNG đảm bảo dữ liệu đã xuống đĩa. Với một file mà lý do tồn
        // tại của nó là sống sót qua crash, thiếu bước này là hỏng đúng chỗ.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public func read() throws -> ProxySnapshot? {
        guard exists else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SystemProxyError.snapshotUnreadable("không đọc được file: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(ProxySnapshot.self, from: data)
        } catch {
            // KHÔNG xoá file ở đây. Nội dung hỏng vẫn có thể cứu được bằng
            // tay; xoá đi là chắc chắn không.
            throw SystemProxyError.snapshotUnreadable("JSON hỏng: \(error.localizedDescription)")
        }
    }

    public func delete() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: url)
    }
}
