import Foundation

/// Tích luỹ byte của một body. Dưới ngưỡng thì giữ RAM, vượt thì spill ra đĩa.
///
/// Không `Sendable` một cách có chủ ý: mỗi instance chỉ sống trong một
/// ChannelHandler và chỉ được chạm trên event loop của channel đó.
public final class BodyCollector {
    private let limit: Int
    private let spillDirectory: URL
    private var buffer = Data()
    private var totalBytes = 0
    private var fileURL: URL?
    private var handle: FileHandle?
    private var spillFailed = false

    public init(limit: Int, spillDirectory: URL) {
        self.limit = limit
        self.spillDirectory = spillDirectory
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        totalBytes += data.count

        if handle != nil {
            write(data)
            return
        }
        if buffer.count + data.count <= limit {
            buffer.append(data)
            return
        }
        guard !spillFailed else { return }   // đã hỏng rồi thì thôi, giữ nguyên phần đầu
        startSpilling(with: data)
    }

    public func finish() -> BodyPayload {
        try? handle?.close()
        handle = nil

        if spillFailed { return .truncated(buffer, totalBytes: totalBytes) }
        if let fileURL { return .file(fileURL, totalBytes: totalBytes) }
        return buffer.isEmpty ? .none : .inMemory(buffer)
    }

    private func startSpilling(with data: Data) {
        let url = spillDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(
                at: spillDirectory, withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: buffer)
            try handle.write(contentsOf: data)
            self.handle = handle
            self.fileURL = url
            self.buffer = Data()            // đã nằm trên đĩa, nhả RAM
        } catch {
            spillFailed = true
        }
    }

    private func write(_ data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            try? handle?.close()
            handle = nil
            fileURL = nil
            spillFailed = true
        }
    }
}
