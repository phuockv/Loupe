import Foundation
import NIOCore
import TrafficModel

/// Trạng thái chia sẻ giữa handler phía client và handler phía upstream
/// của cùng một kết nối.
///
/// Không khoá, không actor: hai channel được ghim vào CÙNG event loop
/// (xem `HTTPProxyHandler.connectUpstream`), nên chúng không bao giờ chạy
/// song song. Bỏ ràng buộc ghim event loop đó là tự tạo data race.
final class SessionState {
    /// FIFO id transaction đang chờ response. HTTP/1.1 trả response đúng
    /// thứ tự request, kể cả khi client pipeline.
    var pendingIDs: [UUID] = []
    var transactions: [UUID: Transaction] = [:]

    func enqueue(_ transaction: Transaction) {
        pendingIDs.append(transaction.id)
        transactions[transaction.id] = transaction
    }

    func dequeue() -> Transaction? {
        guard !pendingIDs.isEmpty else { return nil }
        return transactions[pendingIDs.removeFirst()]
    }
}
