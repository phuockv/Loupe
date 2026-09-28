# Loupe — Thiết kế MVP

Ngày: 2026-09-05
Trạng thái: đã duyệt, sẵn sàng lập implementation plan

## 1. Mục tiêu

Ứng dụng macOS native bắt, kiểm tra và (về sau) chỉnh sửa lưu lượng HTTP/HTTPS,
tương tự Proxyman/Charles. MVP phải chứng minh được đường xương sống:

- Local proxy server nghe ở `127.0.0.1:9090`.
- Bắt HTTP plaintext (absolute-form URI).
- Bắt HTTPS bằng MitM: tự sinh Root CA, mint leaf cert theo host, giải mã, forward
  tới origin thật, mã hoá lại chiều về.
- Hiển thị danh sách transaction dạng bảng + inspector chi tiết Request/Response.
- Tìm kiếm/lọc theo URL và method.

### Phi mục tiêu của MVP

Nằm ngoài phạm vi, ghi ra để tránh scope creep:

- HTTP/2 và HTTP/3. Ta ép client xuống HTTP/1.1 bằng ALPN (mục 5.3).
- WebSocket. Kiến trúc chừa chỗ (mục 12) nhưng không implement ở lát cắt này.
- Sửa/replay request (Breakpoint, Map Local, Compose).
- Network Extension / transparent proxy. MVP chỉ dùng explicit proxy.
- Lưu trữ bền vững (SQLite). MVP giữ trong RAM + spill body lớn ra file tạm.
- Code signing, notarization, sandbox. Xem mục 10.

## 2. Các quyết định kiến trúc và lý do

### 2.1 Engine: SwiftNIO + NIOSSL, không dùng Network.framework

Đã cân nhắc Network.framework (đề bài gốc) và loại vì phần MitM:
Security.framework **không có API public để tạo X.509 certificate**, và
`NWProtocolTLS` phía server đòi `sec_identity_t`. Đường đi buộc phải là: sinh key
vào Keychain, tự dựng DER, `SecIdentityCreateWithCertificate`, và ghi **mỗi leaf
cert** vào Keychain — chậm, bẩn, khó gỡ. Cộng thêm phải tự viết HTTP/1.1 parser.

NIOSSL nạp cert/key thẳng từ DER/PEM in-memory, không đụng Keychain một dòng nào,
và `NIOHTTP1` cho sẵn parser đã chịu tải production. Đánh đổi: thêm SPM dependency
(BoringSSL vendored) và phải theo mô hình ChannelHandler pipeline.

### 2.2 UI: SwiftUI Table

`Table` trên macOS có sẵn cột sortable/resizable. Đủ mượt tới ~10–20k dòng **với
điều kiện** có ring buffer giới hạn và coalescing update (mục 7.2). Yếu tố quyết
định performance là coalescing, không phải chọn Table hay NSTableView — nên ta
chọn thứ dựng nhanh hơn và giữ `TrafficStore` tách khỏi view để swap sang
NSTableView sau này là thay một file.

### 2.3 Giao tiếp engine → UI: AsyncStream của value type bất biến

`ProxyCore` không giữ tham chiếu tới store hay UI. Nó phát `TrafficEvent` — struct
`Sendable` bất biến — qua `AsyncStream`. Event loop của NIO không phải MainActor;
gửi giá trị bất biến qua stream làm Swift 6 strict concurrency thoả mãn mà không
cần lock nào.

## 3. Cấu trúc module

```
Loupe/
├── Package.swift
├── Sources/
│   ├── TrafficModel/      value type thuần, Sendable, KHÔNG import NIO
│   ├── CertKit/           Root CA, leaf minting, cài trust store
│   ├── ProxyCore/         engine NIO, KHÔNG import SwiftUI
│   └── LoupeApp/  SwiftUI (executableTarget)
├── Tests/
│   ├── CertKitTests/
│   └── ProxyCoreTests/
└── docs/superpowers/specs/
```

Quy tắc phụ thuộc, một chiều:
`TrafficModel` ← `CertKit`, `ProxyCore` ← `LoupeApp`.
`TrafficModel` không phụ thuộc gì. Vi phạm chiều này là dấu hiệu sai thiết kế.

## 4. Data model (`TrafficModel`)

```swift
public enum Scheme: String, Sendable { case http, https }

public enum BodyPayload: Sendable {
    case none
    case inMemory(Data)                     // <= maxInMemoryBodyBytes
    case file(URL, totalBytes: Int)         // > ngưỡng, đã spill trọn vẹn ra đĩa
    case truncated(Data, totalBytes: Int)   // CHỈ khi spill thất bại (hết đĩa, lỗi ghi)
}

public struct RequestModel: Sendable {
    public var method: String
    public var url: URL
    public var httpVersion: String
    public var headers: [(name: String, value: String)]
    public var body: BodyPayload
    /// Suy ra từ `url` lúc dựng, không cho set riêng — tránh hai nguồn sự thật lệch nhau.
    public private(set) var queryItems: [URLQueryItem]
}

public struct ResponseModel: Sendable {
    public var statusCode: Int
    public var reasonPhrase: String
    public var headers: [(name: String, value: String)]
    public var body: BodyPayload
}

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
    public var bytesSent: Int
    public var bytesReceived: Int
    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}
```

Headers giữ dạng mảng cặp, không phải Dictionary: HTTP cho phép header lặp
(`Set-Cookie`) và inspector phải hiện đúng thứ tự gốc.

Kênh engine → UI:

```swift
public enum TrafficEvent: Sendable {
    case started(Transaction)
    case responseHead(id: UUID, ResponseModel)
    case completed(id: UUID, ResponseModel, endedAt: Date)
    case failed(id: UUID, message: String, endedAt: Date)
}
```

Ngưỡng cụ thể: body <= **2 MB** giữ trong RAM (`.inMemory`). Vượt ngưỡng thì ghi
trọn vẹn ra `FileManager.default.temporaryDirectory/Loupe/<uuid>` và dùng
`.file`. `.truncated` là đường thoát hiểm duy nhất khi ghi đĩa thất bại — giữ 2 MB
đầu nhưng vẫn ghi `totalBytes` thật để inspector báo đúng cho người dùng.
Không có cơ chế spill này, bắt một lần tải video là app phình vài GB.

## 5. `ProxyCore`

### 5.1 Cấu hình

```swift
public struct ProxyConfiguration: Sendable {
    public var listenHost: String = "127.0.0.1"
    public var listenPort: Int = 9090
    /// Host trong tập này chỉ được tunnel byte thô, không MitM.
    /// Mặc định là các domain pin cert, sẽ hỏng ngay nếu bị chặn.
    public var bypassedHosts: Set<String> = [
        "apple.com", "icloud.com", "itunes.apple.com",
        "mzstatic.com", "push.apple.com",
    ]
    public var maxInMemoryBodyBytes: Int = 2 * 1024 * 1024
}
```

### 5.2 Pipeline khi accept một client connection

1. `HTTPRequestDecoder` + `HTTPResponseEncoder` → `ProxyEntryHandler` đọc dòng đầu.
2. Rẽ nhánh theo dạng request-target:
   - **`CONNECT host:port`** → trả `200 Connection Established`, gỡ HTTP codec, rồi:
     - host khớp `bypassedHosts` → `ConnectTunnelHandler`: relay byte thô hai
       chiều, không decrypt. Transaction ghi `host`, `port`, `scheme: .https`,
       `bytesSent`/`bytesReceived`, `state`, và `request.method = "CONNECT"`;
       `response` để `nil`. UI hiện dòng này với nhãn "tunnelled (not decrypted)"
       để người dùng hiểu vì sao không có body.
     - ngược lại → `MITMUpgradeHandler`: mint leaf cho `host`, gắn
       `NIOSSLServerHandler`, rồi **gắn lại** HTTP codec + `HTTPProxyHandler`
       lên trên lớp TLS.
   - **URI absolute-form** (`GET http://…`) → thẳng `HTTPProxyHandler`.
3. `HTTPProxyHandler` mở upstream channel tới `(host, port)`; nếu https thì thêm
   `NIOSSLClientHandler` verify bằng system trust store. Rewrite request-target về
   origin-form, gỡ hop-by-hop headers (`Connection`, `Proxy-Connection`,
   `Keep-Alive`, `Transfer-Encoding`, `Upgrade`, `TE`, `Trailer`,
   `Proxy-Authenticate`, `Proxy-Authorization`), forward, và glue hai channel.
   Riêng `Transfer-Encoding`: gỡ header gốc và để `HTTPRequestEncoder` của NIO tự
   dựng lại framing theo body thực tế — forward thẳng header này sẽ sinh framing kép.
4. `TransactionRecorder` tích luỹ head + body rồi phát `TrafficEvent`.

### 5.3 Ba đơn giản hoá có chủ đích

- **Không cần SNI callback.** Dòng `CONNECT` đã cho hostname *trước* handshake,
  nên ta mint leaf ngay tại đó. SNI callback chỉ cần khi CONNECT trỏ tới IP trần;
  trường hợp đó MVP trả `502` kèm thông báo rõ, không cố đoán.
- **ALPN chỉ `["http/1.1"]`** ở cả hai chiều ⇒ không phải implement HTTP/2 framing.
- **Một upstream channel cho mỗi client connection**, tôn trọng keep-alive trong
  phạm vi đó, không có connection pool toàn cục. Pool là nguồn bug lớn nhất trong
  proxy và MVP không cần.

## 6. `CertKit`

### 6.1 Root CA

swift-certificates + swift-crypto. Khoá P-256, hạn 10 năm, `basicConstraints: CA`
(critical), `keyUsage: keyCertSign, cRLSign`, có Subject Key Identifier.
Lưu PEM tại `~/Library/Application Support/Loupe/ca/` với quyền `0600`.
Sinh một lần, load lại nếu đã tồn tại.

### 6.2 Leaf certificate

- **Dùng chung một khoá P-256 cho mọi leaf.** Nhanh hơn nhiều và không giảm an
  toàn trong bối cảnh này (khoá vốn nằm cùng process với CA).
- SAN `dNSName` = đúng host được CONNECT tới. Không wildcard.
- EKU `serverAuth`, hạn 1 năm, `notBefore` lùi 1 giờ để chịu lệch đồng hồ.
- Cache trong actor, LRU tối đa **512** host.
- Nạp vào NIOSSL bằng `NIOSSLCertificate(bytes:format: .der)` và
  `NIOSSLPrivateKey(bytes:format: .der)`. **Không đụng Keychain.**

### 6.3 Cài trust

```swift
public protocol TrustStoreInstaller: Sendable {
    func isInstalled(caCertificateDER: Data) async throws -> Bool
    func install(caCertificatePEMPath: URL) async throws
}
```

Impl MVP `AdminScriptInstaller` chạy qua osascript với quyền administrator:
`security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <pem>`.

Toàn bộ thao tác cần quyền admin nằm sau protocol này. Khi chốt hướng ký/phân phối
(mục 10), chỉ cần thêm impl mới — engine không đổi.

## 7. Store và UI

### 7.1 `TrafficStore`

`@MainActor @Observable final class TrafficStore`, tiêu thụ `AsyncStream<TrafficEvent>`:

- Ring buffer giới hạn **5.000** transaction, cộng `[UUID: Int]` index để update O(1).
- Transaction bị đẩy khỏi buffer phải xoá file body tạm kèm theo.

### 7.2 Coalescing — điểm quyết định performance

Event được gom vào buffer chờ và chỉ flush vào mảng observable **tối đa
100ms/lần**. Không có bước này, một trang web nặng đẩy vài trăm update mỗi giây và
UI đứng hình bất kể dùng Table hay NSTableView.

### 7.3 View

`NavigationSplitView`:
- Trái: `Table` với cột Method, Status, Host, Path, Duration, Size, Time; sortable.
- Phải: `TabView` Request/Response; mỗi tab có mục Headers, Query Parameters, Body.
  Body JSON render bằng `OutlineGroup` dạng cây; fallback plain text.
- Toolbar: nút Start/Stop proxy, ô search, picker lọc method.

Filter tuyến tính trên ≤5.000 dòng (<1ms), chưa cần index ngược.

## 8. Xử lý lỗi

| Tình huống | Hành vi |
|---|---|
| Verify TLS upstream thất bại | Transaction `.failed`, trả `502` kèm lý do đọc được. **Không bao giờ đặt `certificateVerification = .none`** — làm vậy biến app thành lỗ hổng thật cho mọi traffic đi qua. |
| Client gửi TLS alert `certificate_unknown` khi ta handshake | Ghi transaction `.failed` với gợi ý "nghi cert pinning, cân nhắc thêm vào bypass list". Đây là lỗi gặp nhiều nhất khi bắt app thật. |
| Client abort giữa body / unclean shutdown | Mark `.failed`, đóng cả hai channel, không để chết event loop. |
| CONNECT tới IP trần | Trả `502` với thông báo rõ là MVP chưa hỗ trợ. |
| Không resolve được host | Transaction `.failed`, trả `502`. |

## 9. Chiến lược test

- **Handler unit test** bằng `NIOEmbedded.EmbeddedChannel` — không mở socket thật,
  chạy nhanh, deterministic. Phủ: parse CONNECT, parse absolute-form, gỡ
  hop-by-hop headers, rẽ nhánh bypass list.
- **Integration test**: dựng server NIOHTTP1 thật + proxy, drive bằng `URLSession`
  cấu hình `connectionProxyDictionary`. Assert status, body nguyên vẹn,
  transaction ghi đúng. Có case HTTP và case HTTPS qua MitM.
- **CertKitTests**: leaf chain tới CA đúng (`X509.Verifier`), SAN đúng host, cửa
  sổ hiệu lực hợp lệ, cache trả cùng instance cho cùng host.
- **TrafficStore**: ring buffer evict đúng, coalescing gộp đúng số lần flush.

## 10. Dependencies và nền tảng

| Package | Ràng buộc |
|---|---|
| apple/swift-nio | from 2.65.0 |
| apple/swift-nio-ssl | from 2.26.0 |
| apple/swift-certificates | from 1.5.0 |
| apple/swift-crypto | transitively |

Platform: macOS 14.0+ (cần `@Observable` và `Table`). Toolchain Swift 6.3 / Xcode 26.6.

**Vỏ app**: MVP dùng `executableTarget` của SPM, chạy bằng `swift run
LoupeApp`, gọi `NSApplication.shared.setActivationPolicy(.regular)` trong
`init()` để cửa sổ focus đúng. Đổi sang Xcode app target khi cần code signing,
Info.plist và notarization — quyết định đó còn treo (xem 11.2).

## 11. Rủi ro

### 11.1 NIOSSL có nhận DER do swift-certificates sinh ra không

Giả định rủi ro nhất của cả thiết kế. Nếu sai, `CertKit` phải đổi cách xuất khoá
(PKCS#8 → PEM). **Bước implement đầu tiên phải là một test chứng minh điều này**,
trước khi viết bất kỳ dòng engine nào — biết sớm thì sửa rẻ.

### 11.2 Hướng ký/phân phối chưa chốt

Ảnh hưởng cách cài Root CA và sửa system proxy. Đã cô lập sau
`TrustStoreInstaller` nên không chặn MVP, nhưng phải chốt trước khi phát hành.

### 11.3 Cert pinning

Nhiều app sẽ từ chối MitM. Bypass list là cách xử lý duy nhất ở MVP; đã đưa vào
`ProxyConfiguration` từ đầu chứ không thêm sau.

## 12. Sau MVP

Theo thứ tự ưu tiên, mỗi mục là một chu kỳ spec → plan riêng:

1. WebSocket: khi upstream trả `101`, chuyển pipeline hai chiều sang WebSocket
   frame codec, log frame gắn vào transaction cha dạng stream.
2. Breakpoint / sửa request trước khi forward.
3. HTTP/2 (bỏ giới hạn ALPN).
4. Lưu trữ SQLite + session save/load.
5. Cấu hình system proxy tự động (`networksetup` / SCPreferences).
