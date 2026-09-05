import Foundation

/// Kênh một chiều engine -> UI. Toàn value type bất biến, nên event loop
/// của NIO không bao giờ phải chạm MainActor và không cần lock nào.
public enum TrafficEvent: Sendable {
    case started(Transaction)
    case responseHead(id: UUID, ResponseModel)
    case requestBody(id: UUID, BodyPayload)
    case completed(id: UUID, ResponseModel, endedAt: Date)
    case failed(id: UUID, message: String, endedAt: Date)
}
