import Foundation

public enum Scheme: String, Sendable, Hashable {
    case http, https
}

public enum BodyPayload: Sendable {
    case none
    /// <= ngưỡng, giữ nguyên trong RAM.
    case inMemory(Data)
    /// > ngưỡng, đã spill trọn vẹn ra đĩa.
    case file(URL, totalBytes: Int)
    /// Chỉ khi spill thất bại: giữ phần đầu, nhưng `totalBytes` vẫn là con số thật.
    case truncated(Data, totalBytes: Int)

    public var totalBytes: Int {
        switch self {
        case .none: 0
        case .inMemory(let data): data.count
        case .file(_, let total), .truncated(_, let total): total
        }
    }
}

public struct RequestModel: Sendable {
    public var method: String
    public let url: URL
    public var httpVersion: String
    /// Mảng cặp chứ không phải Dictionary: HTTP cho phép header lặp
    /// (`Set-Cookie`) và inspector phải hiện đúng thứ tự gốc.
    public var headers: [(name: String, value: String)]
    public var body: BodyPayload
    /// Suy ra từ `url` lúc dựng, không cho set riêng — tránh hai nguồn sự thật.
    public private(set) var queryItems: [URLQueryItem]

    public init(
        method: String,
        url: URL,
        httpVersion: String = "HTTP/1.1",
        headers: [(name: String, value: String)] = [],
        body: BodyPayload = .none
    ) {
        self.method = method
        self.url = url
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }
}

public struct ResponseModel: Sendable {
    public var statusCode: Int
    public var reasonPhrase: String
    public var headers: [(name: String, value: String)]
    public var body: BodyPayload

    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [(name: String, value: String)] = [],
        body: BodyPayload = .none
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }
}

public enum TransactionState: Sendable {
    case pending
    case completed
    case failed(reason: String)
    /// CONNECT nằm trong bypass list: chỉ relay byte, không giải mã.
    case tunnelled
}

public struct Transaction: Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var scheme: Scheme
    public var host: String
    public var port: Int
    public var request: RequestModel
    public var response: ResponseModel?
    public var state: TransactionState
    public var bytesSent: Int
    public var bytesReceived: Int

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        scheme: Scheme,
        host: String,
        port: Int,
        request: RequestModel,
        state: TransactionState = .pending
    ) {
        self.id = id
        self.startedAt = startedAt
        self.scheme = scheme
        self.host = host
        self.port = port
        self.request = request
        self.response = nil
        self.state = state
        self.bytesSent = 0
        self.bytesReceived = 0
    }
}
