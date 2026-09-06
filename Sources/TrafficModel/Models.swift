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

/// VÒNG ĐỜI của một transaction, và CHỈ vòng đời.
///
/// `.tunnelled` từng nằm ở đây và đã được tách ra thành `Transaction.isTunnelled`.
/// Lý do: nó mô tả CÁCH XỬ LÝ ("không giải mã"), một sự thật cố định từ lúc
/// `.started`, trong khi ba case còn lại mô tả transaction đang ở đâu trong vòng
/// đời. Nhét cả hai vào một ô nghĩa là bất kỳ ai xử lý event `.completed` —
/// thứ mà một tunnel mù bây giờ CÓ phát khi nó đóng sạch — cũng xoá mất tín
/// hiệu "kết nối này chưa từng bị giải mã". Đúng cái tín hiệu mà người dùng
/// thêm host vào bypass list để có (ngân hàng, app pin cert), và nó sẽ biến
/// thành một dòng "completed" trông y hệt mọi dòng khác.
public enum TransactionState: Sendable {
    case pending
    case completed
    case failed(reason: String)
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
    /// CONNECT nằm trong bypass list: proxy chỉ relay byte thô, KHÔNG giải mã.
    ///
    /// Cố định từ lúc `.started` và độc lập với `state` — xem `TransactionState`.
    /// Một transaction có thể vừa `isTunnelled` vừa `.completed`: tunnel đã chạy
    /// xong và đóng sạch, mà nội dung thì proxy chưa từng đọc được.
    public let isTunnelled: Bool
    /// Byte THÔ đã relay qua tunnel, hai chiều: `bytesSent` là client → origin,
    /// `bytesReceived` là origin → client.
    ///
    /// GIỚI HẠN, và nó là một phần của hợp đồng chứ không phải thiếu sót tạm
    /// thời: CHỈ transaction `isTunnelled` mới được ghi hai trường này (xem
    /// `TrafficEvent.bytesRelayed`). Với một transaction đã giải mã, kích
    /// thước nằm ở `request.body`/`response.body` và hai trường này ở nguyên
    /// 0 — đừng đọc chúng như "phiên này không chở byte nào".
    ///
    /// Con số đếm phần peer channel đã CHẤP NHẬN vào hàng đợi ghi, KHÔNG phải
    /// phần chắc chắn đã ra tới dây: một lần đóng huỷ phần chưa flush vẫn có
    /// thể vứt phần đuôi. Nó được cộng dồn SAU mỗi lần ghi được chấp nhận, nên
    /// nó không bao giờ nói QUÁ những gì proxy đã chuyển đi được — với một
    /// tunnel mù thì đây là con số duy nhất proxy biết chắc.
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
        state: TransactionState = .pending,
        isTunnelled: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.scheme = scheme
        self.host = host
        self.port = port
        self.request = request
        self.response = nil
        self.state = state
        self.isTunnelled = isTunnelled
        self.bytesSent = 0
        self.bytesReceived = 0
    }
}
