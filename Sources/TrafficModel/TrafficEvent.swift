import Foundation

/// Kênh một chiều engine -> UI. Toàn value type bất biến, nên event loop
/// của NIO không bao giờ phải chạm MainActor và không cần lock nào.
public enum TrafficEvent: Sendable {
    case started(Transaction)
    case responseHead(id: UUID, ResponseModel)
    case requestBody(id: UUID, BodyPayload)
    /// Số byte THÔ đã relay qua một tunnel mù, phát ĐÚNG MỘT LẦN lúc chân
    /// cuối cùng của tunnel đóng — kể cả khi tunnel đó đã bị báo `.failed`
    /// trước đó (một tunnel hỏng vẫn đã chở byte, và con số đó thường là thứ
    /// cần nhất để hiểu nó hỏng ở đâu).
    ///
    /// CHỈ nhánh CONNECT bypass (`ConnectTunnelHandler`/`TunnelRelayHandler`)
    /// phát event này. Đường HTTP đã giải mã — kể cả các request bên trong
    /// một phiên MitM — KHÔNG phát: kích thước ở đó nằm trong
    /// `request.body`/`response.body`, và đếm thêm một lần nữa ở tầng byte
    /// chỉ tạo ra hai con số cãi nhau về cùng một thứ. Xem
    /// `Transaction.bytesSent`.
    case bytesRelayed(id: UUID, sent: Int, received: Int)
    case completed(id: UUID, ResponseModel, endedAt: Date)
    case failed(id: UUID, message: String, endedAt: Date)
}
