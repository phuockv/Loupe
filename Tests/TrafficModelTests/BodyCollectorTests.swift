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

    @Test("Ghi giữa chừng thất bại (đĩa đầy) thì xoá file dở, trả .truncated rỗng nhưng tổng byte đúng")
    func midStreamWriteFailureDeletesPartialFileAndReturnsEmptyTruncated() {
        let collector = BodyCollector(limit: 100, spillDirectory: tempDir())

        // Seam nội bộ (internal, chỉ thấy được nhờ @testable): thay handle ghi thật
        // bằng bản giả. Hai lần ghi đầu (buffer sẵn có + chunk kích hoạt spill) thành
        // công như bình thường; lần ghi thứ ba (chunk kế tiếp, đã đang spill) mô
        // phỏng lỗi giữa chừng thật sự, ví dụ đĩa đầy.
        var capturedURL: URL?
        var writeCount = 0
        collector.openWriteHandle = { url in
            capturedURL = url
            return BodyCollectorWriteHandle(
                write: { _ in
                    writeCount += 1
                    if writeCount >= 3 {
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                },
                close: {}
            )
        }

        collector.append(Data(repeating: 0x41, count: 60))   // vào buffer, chưa spill
        collector.append(Data(repeating: 0x42, count: 60))   // vượt ngưỡng -> startSpilling, 2 lần ghi đầu OK
        collector.append(Data(repeating: 0x43, count: 10))   // đã đang spill -> write(_:), ghi thứ 3 lỗi
        // Sau khi đã hỏng, chunk tiếp theo phải chỉ được ĐẾM chứ không được lọt
        // vào buffer rồi bị trả về như thể là "phần đầu" (nó là phần ĐUÔI thật sự).
        collector.append(Data(repeating: 0x44, count: 5))

        guard let url = capturedURL else {
            Issue.record("mong đợi openWriteHandle được gọi"); return
        }
        // File dở tạo bởi FileManager.createFile ở startSpilling phải bị xoá,
        // không được mồ côi lại trên đĩa.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        guard case .truncated(let data, let total) = collector.finish() else {
            Issue.record("mong đợi .truncated"); return
        }
        #expect(total == 135)
        #expect(data.isEmpty)   // trung thực là không còn giữ nội dung, không giả làm phần đầu bằng phần đuôi
    }
}
