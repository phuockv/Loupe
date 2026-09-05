import Testing
import Foundation
@testable import TrafficModel

@Suite("BodyCollector")
struct BodyCollectorTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BodyCollectorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Không có byte nào thì trả .none")
    func emptyBodyIsNone() {
        let collector = BodyCollector(limit: 1024, spillDirectory: tempDir())
        guard case .none = collector.finish() else {
            Issue.record("mong đợi .none"); return
        }
    }

    @Test("Body dưới ngưỡng giữ trong RAM")
    func smallBodyStaysInMemory() {
        let collector = BodyCollector(limit: 1024, spillDirectory: tempDir())
        collector.append(Data(repeating: 0x41, count: 100))
        guard case .inMemory(let data) = collector.finish() else {
            Issue.record("mong đợi .inMemory"); return
        }
        #expect(data.count == 100)
    }

    @Test("Body vượt ngưỡng spill ra đĩa, nội dung nguyên vẹn")
    func largeBodySpillsToDisk() throws {
        let collector = BodyCollector(limit: 100, spillDirectory: tempDir())
        collector.append(Data(repeating: 0x41, count: 60))
        collector.append(Data(repeating: 0x42, count: 60))

        guard case .file(let url, let total) = collector.finish() else {
            Issue.record("mong đợi .file"); return
        }
        #expect(total == 120)
        let written = try Data(contentsOf: url)
        #expect(written.count == 120)
        #expect(written.prefix(60).allSatisfy { $0 == 0x41 })
        #expect(written.suffix(60).allSatisfy { $0 == 0x42 })
    }

    @Test("Ghi đĩa thất bại thì rơi về .truncated nhưng vẫn báo đúng tổng byte")
    func spillFailureFallsBackToTruncated() {
        // Thư mục không tồn tại và không tạo được -> mọi lần ghi đều lỗi.
        let unwritable = URL(fileURLWithPath: "/dev/null/khong-the-tao")
        let collector = BodyCollector(limit: 100, spillDirectory: unwritable)
        collector.append(Data(repeating: 0x41, count: 60))
        collector.append(Data(repeating: 0x42, count: 60))

        guard case .truncated(let data, let total) = collector.finish() else {
            Issue.record("mong đợi .truncated"); return
        }
        #expect(total == 120)
        #expect(data.count <= 100)
    }
}
