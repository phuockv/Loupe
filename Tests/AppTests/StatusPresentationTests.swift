import Testing
import Foundation
import TrafficModel
@testable import AppCore

/// `StatusPresentation` là chỗ DUY NHẤT `StatusCell` (và test) suy luận
/// những gì hiện ra từ một `Transaction` — xem doc comment của nó trong
/// `ContentView.swift`. Test ở đây khẳng định đúng bất biến mà cả module
/// `TransactionState`/`Transaction.isTunnelled` được tách ra để bảo vệ:
/// isTunnelled và state là hai tín hiệu độc lập, cả hai phải cùng lộ ra.
@Suite("StatusPresentation")
struct StatusPresentationTests {

    private func makeTransaction(
        state: TransactionState, isTunnelled: Bool, statusCode: Int? = nil
    ) -> Transaction {
        var transaction = Transaction(
            scheme: .https, host: "example.com", port: 443,
            request: RequestModel(method: "GET", url: URL(string: "https://example.com/")!),
            state: state,
            isTunnelled: isTunnelled
        )
        if let statusCode {
            transaction.response = ResponseModel(statusCode: statusCode, reasonPhrase: "OK")
        }
        return transaction
    }

    @Test("Bypass connection completed: isTunnelled VÀ completed cùng lộ ra, không cái nào bị nuốt")
    func tunnelledAndCompletedBothSurface() {
        let transaction = makeTransaction(state: .completed, isTunnelled: true, statusCode: 200)
        let presentation = StatusPresentation(transaction: transaction)
        #expect(presentation.isTunnelled == true)
        #expect(presentation.kind == .completed(code: 200))
    }

    @Test("Kết nối MitM bình thường: không tunnelled, completed với đúng status code")
    func decryptedCompletedConnection() {
        let transaction = makeTransaction(state: .completed, isTunnelled: false, statusCode: 204)
        let presentation = StatusPresentation(transaction: transaction)
        #expect(presentation.isTunnelled == false)
        #expect(presentation.kind == .completed(code: 204))
    }

    @Test("failed giữ nguyên toàn bộ message làm reason, không cắt bớt")
    func failedKeepsFullReason() {
        let longReason = String(repeating: "cert pinning nghi ngờ, thêm host vào bypass list. ", count: 5)
        let transaction = makeTransaction(state: .failed(reason: longReason), isTunnelled: false)
        let presentation = StatusPresentation(transaction: transaction)
        guard case .failed(let reason) = presentation.kind else {
            Issue.record("mong đợi .failed"); return
        }
        #expect(reason == longReason)
    }

    @Test("pending chưa có response vẫn không crash, kind là .pending")
    func pendingHasNoCode() {
        let transaction = makeTransaction(state: .pending, isTunnelled: false)
        let presentation = StatusPresentation(transaction: transaction)
        #expect(presentation.kind == .pending)
    }

    @Test("Tunnel còn pending (chưa đóng) vẫn hiện isTunnelled ngay, không đợi tới completed")
    func tunnelledPendingShowsIndicatorImmediately() {
        let transaction = makeTransaction(state: .pending, isTunnelled: true)
        let presentation = StatusPresentation(transaction: transaction)
        #expect(presentation.isTunnelled == true)
        #expect(presentation.kind == .pending)
    }

    @Test("Tunnel bị lỗi (hỏng bắt tay TLS): isTunnelled VÀ failed cùng lộ ra")
    func tunnelledAndFailedBothSurface() {
        let transaction = makeTransaction(
            state: .failed(reason: "bắt tay TLS với client hỏng"), isTunnelled: true
        )
        let presentation = StatusPresentation(transaction: transaction)
        #expect(presentation.isTunnelled == true)
        guard case .failed = presentation.kind else {
            Issue.record("mong đợi .failed"); return
        }
    }
}
