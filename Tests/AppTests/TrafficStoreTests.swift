import Testing
import Foundation
import TrafficModel
@testable import AppCore

@MainActor
@Suite("TrafficStore")
struct TrafficStoreTests {

    private func makeTransaction(method: String = "GET",
                                 urlString: String = "https://example.com/a",
                                 isTunnelled: Bool = false) -> Transaction {
        Transaction(
            scheme: .https, host: "example.com", port: 443,
            request: RequestModel(method: method, url: URL(string: urlString)!),
            isTunnelled: isTunnelled
        )
    }

    @Test("Event chưa flush thì chưa lộ ra ngoài — đây là toàn bộ ý nghĩa coalescing")
    func doesNotApplyEventsUntilFlush() {
        let store = TrafficStore(capacity: 10)
        store.enqueue(.started(makeTransaction()))
        #expect(store.transactions.isEmpty)
        store.flushNow()
        #expect(store.transactions.count == 1)
    }

    @Test("Một lần flush gom được nhiều event")
    func coalescesManyEvents() {
        let store = TrafficStore(capacity: 100)
        for _ in 0..<50 { store.enqueue(.started(makeTransaction())) }
        #expect(store.transactions.isEmpty)
        store.flushNow()
        #expect(store.transactions.count == 50)
    }

    @Test(".completed cập nhật đúng transaction đang có")
    func completedUpdatesExistingTransaction() {
        let store = TrafficStore(capacity: 10)
        let transaction = makeTransaction()
        store.enqueue(.started(transaction))
        store.enqueue(.completed(
            id: transaction.id,
            ResponseModel(statusCode: 204, reasonPhrase: "No Content"),
            endedAt: Date()
        ))
        store.flushNow()

        #expect(store.transactions.count == 1)
        #expect(store.transactions[0].response?.statusCode == 204)
        #expect(store.transactions[0].duration != nil)
        if case .completed = store.transactions[0].state {} else {
            Issue.record("state phải là .completed")
        }
    }

    @Test(".failed ghi lý do đọc được")
    func failedRecordsReason() {
        let store = TrafficStore(capacity: 10)
        let transaction = makeTransaction()
        store.enqueue(.started(transaction))
        store.enqueue(.failed(id: transaction.id, message: "nghi cert pinning", endedAt: Date()))
        store.flushNow()

        guard case .failed(let reason) = store.transactions[0].state else {
            Issue.record("state phải là .failed"); return
        }
        #expect(reason == "nghi cert pinning")
    }

    @Test(".requestBody gán body vào request của đúng transaction đang chờ")
    func requestBodySetsRequestBody() {
        let store = TrafficStore(capacity: 10)
        let transaction = makeTransaction()
        store.enqueue(.started(transaction))
        store.enqueue(.requestBody(id: transaction.id, .inMemory(Data("hello".utf8))))
        store.flushNow()

        guard case .inMemory(let data) = store.transactions[0].request.body else {
            Issue.record("mong đợi .inMemory"); return
        }
        #expect(data == Data("hello".utf8))
    }

    @Test("isTunnelled sống sót qua .completed vì nó là let cố định từ .started, không nằm trong TransactionState")
    func isTunnelledSurvivesCompletion() {
        let store = TrafficStore(capacity: 10)
        let transaction = makeTransaction(isTunnelled: true)
        store.enqueue(.started(transaction))
        store.enqueue(.completed(
            id: transaction.id, ResponseModel(statusCode: 200, reasonPhrase: "OK"), endedAt: Date()
        ))
        store.flushNow()

        #expect(store.transactions[0].isTunnelled)
        if case .completed = store.transactions[0].state {} else {
            Issue.record("state phải là .completed")
        }
    }

    @Test("Terminal event cho id chưa từng thấy (bị bufferingNewest rơi mất .started) bị bỏ qua, không tạo transaction giả")
    func ignoresTerminalEventForUnknownID() {
        let store = TrafficStore(capacity: 10)
        store.enqueue(.completed(id: UUID(), ResponseModel(statusCode: 200, reasonPhrase: "OK"), endedAt: Date()))
        store.enqueue(.failed(id: UUID(), message: "unknown", endedAt: Date()))
        store.enqueue(.requestBody(id: UUID(), .none))
        store.flushNow()
        #expect(store.transactions.isEmpty)
    }

    @Test("Vượt capacity thì transaction cũ nhất bị đẩy ra và index vẫn đúng")
    func evictsOldestBeyondCapacity() {
        let store = TrafficStore(capacity: 4)
        var ids: [UUID] = []
        for _ in 0..<10 {
            let transaction = makeTransaction()
            ids.append(transaction.id)
            store.enqueue(.started(transaction))
        }
        store.flushNow()
        #expect(store.transactions.count <= 4)

        // Cập nhật transaction mới nhất vẫn phải trúng sau khi reindex.
        let newest = ids.last!
        store.enqueue(.completed(
            id: newest, ResponseModel(statusCode: 200, reasonPhrase: "OK"), endedAt: Date()
        ))
        store.flushNow()
        #expect(store.transactions.last?.response?.statusCode == 200)
    }

    @Test("Lọc theo URL, không phân biệt hoa thường")
    func filtersByURL() {
        let store = TrafficStore(capacity: 10)
        store.enqueue(.started(makeTransaction(urlString: "https://example.com/users")))
        store.enqueue(.started(makeTransaction(urlString: "https://example.com/orders")))
        store.flushNow()

        store.searchText = "USER"
        #expect(store.filtered.count == 1)
        #expect(store.filtered[0].request.url.path == "/users")
    }

    @Test("Lọc theo method kết hợp với search")
    func filtersByMethodAndSearch() {
        let store = TrafficStore(capacity: 10)
        store.enqueue(.started(makeTransaction(method: "GET", urlString: "https://example.com/a")))
        store.enqueue(.started(makeTransaction(method: "POST", urlString: "https://example.com/a")))
        store.enqueue(.started(makeTransaction(method: "POST", urlString: "https://example.com/b")))
        store.flushNow()

        store.methodFilter = "POST"
        store.searchText = "/a"
        #expect(store.filtered.count == 1)
    }

    @Test("Transaction bị evict thì file body tạm cũng bị xoá")
    func deletesSpilledBodyOnEviction() throws {
        let store = TrafficStore(capacity: 1)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spill = directory.appendingPathComponent("body.bin")
        try Data("payload".utf8).write(to: spill)

        var first = makeTransaction()
        first.response = ResponseModel(
            statusCode: 200, reasonPhrase: "OK", body: .file(spill, totalBytes: 7)
        )
        store.enqueue(.started(first))
        store.flushNow()
        store.enqueue(.started(makeTransaction()))   // đẩy `first` ra
        store.flushNow()

        #expect(FileManager.default.fileExists(atPath: spill.path) == false)
    }

    @Test("clear() cũng xoá file body tạm, không chỉ eviction")
    func clearDeletesSpilledBodies() throws {
        let store = TrafficStore(capacity: 10)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spill = directory.appendingPathComponent("body.bin")
        try Data("payload".utf8).write(to: spill)

        var transaction = makeTransaction()
        transaction.response = ResponseModel(
            statusCode: 200, reasonPhrase: "OK", body: .file(spill, totalBytes: 7)
        )
        store.enqueue(.started(transaction))
        store.flushNow()
        store.clear()

        #expect(FileManager.default.fileExists(atPath: spill.path) == false)
        #expect(store.transactions.isEmpty)
    }
}
