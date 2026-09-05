# ProxyManClone MVP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dựng proxy macOS bắt được HTTP và HTTPS (qua MitM), hiển thị transaction trong bảng có inspector chi tiết.

**Architecture:** SwiftNIO làm engine; `CertKit` sinh Root CA và mint leaf cert theo host rồi nạp thẳng vào NIOSSL không qua Keychain; `ProxyCore` phát `TrafficEvent` bất biến qua `AsyncStream` cho tầng SwiftUI, nên event loop của NIO không bao giờ chạm MainActor.

**Tech Stack:** Swift 6.3, SwiftNIO 2.65+, NIOSSL 2.26+, swift-certificates 1.5+, SwiftUI (macOS 14+), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-05-proxyman-clone-design.md`

## Global Constraints

- Platform tối thiểu **macOS 14.0**. Toolchain Swift 6.3 / Xcode 26.6.
- Swift 6 language mode, strict concurrency. Mọi type qua ranh giới module phải `Sendable`.
- **Chiều phụ thuộc một chiều:** `TrafficModel` ← `CertKit`, `ProxyCore` ← `ProxyManCloneApp`. `TrafficModel` không import gì ngoài Foundation. `ProxyCore` không import SwiftUI. Vi phạm là lỗi thiết kế, không phải lỗi style.
- **Không bao giờ đặt `certificateVerification = .none`** ở đường upstream. Làm vậy biến app thành lỗ hổng thật cho mọi traffic đi qua nó.
- ALPN chỉ `["http/1.1"]` ở cả hai chiều.
- Body <= **2 MB** giữ RAM; vượt thì spill trọn ra `temporaryDirectory/ProxyManClone/<uuid>`.
- Ring buffer UI **5.000** transaction; LRU leaf cert **512** host; coalescing UI **100 ms**.
- Port mặc định **9090**, bind `127.0.0.1`.
- Test dùng framework `Testing` (không XCTest). Test không được gọi ra mạng ngoài; mọi server trong test bind `127.0.0.1:0`.

## File Structure

| File | Trách nhiệm |
|---|---|
| `Package.swift` | Khai báo 4 target + dependency |
| `Sources/TrafficModel/Models.swift` | `Scheme`, `BodyPayload`, `RequestModel`, `ResponseModel`, `TransactionState`, `Transaction` |
| `Sources/TrafficModel/TrafficEvent.swift` | Enum event engine → UI |
| `Sources/TrafficModel/BodyCollector.swift` | Tích luỹ byte, spill ra đĩa khi vượt ngưỡng |
| `Sources/CertKit/CertificateAuthority.swift` | Sinh/nạp Root CA, persist PEM 0600 |
| `Sources/CertKit/LeafCertificateCache.swift` | Mint leaf theo host, LRU, trả `TLSIdentity` |
| `Sources/CertKit/TrustStoreInstaller.swift` | Protocol + impl chạy `security` qua quyền admin |
| `Sources/ProxyCore/ProxyConfiguration.swift` | Cấu hình port, bypass list, ngưỡng body |
| `Sources/ProxyCore/HeaderSanitizer.swift` | Hàm thuần: gỡ hop-by-hop, rewrite request-target |
| `Sources/ProxyCore/ProxyServer.swift` | Bootstrap, start/stop, sở hữu `AsyncStream` |
| `Sources/ProxyCore/Handlers/ProxyEntryHandler.swift` | Đọc dòng đầu, rẽ nhánh CONNECT / absolute-form |
| `Sources/ProxyCore/Handlers/HTTPProxyHandler.swift` | Glue client ↔ upstream, ghi transaction |
| `Sources/ProxyCore/Handlers/ConnectTunnelHandler.swift` | Relay byte thô cho bypass list |
| `Sources/ProxyCore/Handlers/MITMUpgradeHandler.swift` | Gắn TLS server + dựng lại HTTP codec |
| `Sources/ProxyManCloneApp/App.swift` | `@main`, activation policy |
| `Sources/ProxyManCloneApp/TrafficStore.swift` | Ring buffer + coalescing 100 ms |
| `Sources/ProxyManCloneApp/ContentView.swift` | `NavigationSplitView` + `Table` + toolbar |
| `Sources/ProxyManCloneApp/InspectorView.swift` | Tab Request/Response, headers, query, JSON tree |

---

### Task 1: Scaffold package và chứng minh rủi ro 11.1

Mục 11.1 của spec: giả định rủi ro nhất là **NIOSSL nạp được vật liệu do swift-certificates sinh ra**. Task này phải xong trước khi viết bất kỳ dòng engine nào. Nếu đỏ, chỉ `CertKit` đổi, engine không đụng tới.

**Files:**
- Create: `Package.swift`
- Create: `Sources/TrafficModel/Placeholder.swift`
- Create: `Sources/CertKit/Placeholder.swift`
- Create: `Sources/ProxyCore/Placeholder.swift`
- Create: `Sources/ProxyManCloneApp/App.swift`
- Test: `Tests/CertKitTests/NIOSSLInteropTests.swift`

**Interfaces:**
- Consumes: không có, đây là task đầu.
- Produces: cây target build được; kết luận dùng `.der` hay `.pem` cho `NIOSSLPrivateKey` — Task 4 phụ thuộc kết luận này.

- [ ] **Step 1: Tạo `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProxyManClone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrafficModel", targets: ["TrafficModel"]),
        .library(name: "CertKit", targets: ["CertKit"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
        .executable(name: "ProxyManCloneApp", targets: ["ProxyManCloneApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "TrafficModel"),
        .target(name: "CertKit", dependencies: [
            "TrafficModel",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "ProxyCore", dependencies: [
            "TrafficModel", "CertKit",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .executableTarget(name: "ProxyManCloneApp", dependencies: [
            "TrafficModel", "CertKit", "ProxyCore",
        ]),
        .testTarget(name: "TrafficModelTests", dependencies: ["TrafficModel"]),
        .testTarget(name: "CertKitTests", dependencies: [
            "CertKit",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .testTarget(name: "ProxyCoreTests", dependencies: [
            "ProxyCore",
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
    ]
)
```

- [ ] **Step 2: Tạo file giữ chỗ để 4 target build được**

Mỗi target cần ít nhất một file nguồn. Nội dung y hệt nhau, chỉ khác tên type:

```swift
// Sources/TrafficModel/Placeholder.swift
enum TrafficModelPlaceholder {}
```

```swift
// Sources/CertKit/Placeholder.swift
enum CertKitPlaceholder {}
```

```swift
// Sources/ProxyCore/Placeholder.swift
enum ProxyCorePlaceholder {}
```

```swift
// Sources/ProxyManCloneApp/App.swift
import SwiftUI

@main
struct ProxyManCloneApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("ProxyManClone") {
            Text("ProxyManClone")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
```

Ba file `Placeholder.swift` bị xoá ở Task 2, 3, 5 khi target đó có code thật.

- [ ] **Step 3: Resolve dependency và build**

Run: `swift build`
Expected: PASS. Nếu resolve thất bại, ghim version cụ thể thay vì `from:` rồi thử lại.

- [ ] **Step 4: Viết test spike — nạp DER vào NIOSSL**

Đây là test quyết định. Tạo `Tests/CertKitTests/NIOSSLInteropTests.swift`:

```swift
import Testing
import Foundation
import Crypto
import SwiftASN1
import X509
import NIOSSL

/// Chứng minh rủi ro 11.1 của spec: NIOSSL có nạp được vật liệu
/// do swift-certificates + swift-crypto sinh ra hay không.
@Suite("NIOSSL interop với swift-certificates")
struct NIOSSLInteropTests {

    /// Sinh một self-signed CA dùng chung cho các test bên dưới.
    static func makeSelfSigned() throws -> (Certificate, P256.Signing.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("spike") }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            },
            issuerPrivateKey: certKey
        )
        return (cert, key)
    }

    @Test("Cert DER nạp được vào NIOSSLCertificate")
    func certificateLoadsFromDER() throws {
        let (cert, _) = try Self.makeSelfSigned()
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        // Không throw là đủ: NIOSSL parse được DER của swift-certificates.
        _ = try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
    }

    @Test("Private key nạp được vào NIOSSLPrivateKey ở dạng DER hoặc PEM")
    func privateKeyLoadsFromDEROrPEM() throws {
        let (_, key) = try Self.makeSelfSigned()

        // Đường ưu tiên của spec: PKCS#8 DER.
        let derWorks = (try? NIOSSLPrivateKey(bytes: Array(key.derRepresentation), format: .der)) != nil

        // Đường lui: PKCS#8 PEM. BoringSSL parse PEM "PRIVATE KEY" rất chắc.
        let pemWorks = (try? NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)) != nil

        // Ít nhất một đường phải chạy, nếu không CertKit không khả thi như thiết kế.
        #expect(derWorks || pemWorks)

        // Ghi kết luận ra log để Task 4 chọn đúng đường.
        print("SPIKE KẾT LUẬN — DER: \(derWorks), PEM: \(pemWorks)")
    }
}
```

- [ ] **Step 5: Chạy test spike**

Run: `swift test --filter NIOSSLInteropTests`
Expected: PASS. Đọc dòng `SPIKE KẾT LUẬN` trong output và ghi lại: nếu `DER: true` thì Task 4 dùng `.der`, ngược lại dùng `.pem`.

Nếu **cả hai** đều false, dừng lại — thiết kế `CertKit` phải sửa và cần quay lại spec trước khi đi tiếp.

- [ ] **Step 6: Viết test handshake thật để chốt spike**

Nạp được vào type chưa chứng minh handshake chạy. Thêm vào cùng file:

```swift
import NIOCore
import NIOPosix

extension NIOSSLInteropTests {

    @Test("TLS handshake thật giữa server dùng cert đó và client tin cert đó")
    func performsRealHandshake() async throws {
        let (cert, key) = try Self.makeSelfSigned()
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let nioCert = try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
        let nioKey = try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioCert)],
            privateKey: .privateKey(nioKey)
        )
        serverConfig.applicationProtocols = ["http/1.1"]
        let serverContext = try NIOSSLContext(configuration: serverConfig)

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([nioCert])
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.applicationProtocols = ["http/1.1"]
        let clientContext = try NIOSSLContext(configuration: clientConfig)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: serverContext))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { try? server.close().wait() }

        let port = server.localAddress!.port!
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                do {
                    let tls = try NIOSSLClientHandler(context: clientContext, serverHostname: nil)
                    return channel.pipeline.addHandler(tls)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()

        // Kết nối lên được nghĩa là handshake đã xong.
        #expect(client.isActive)
        try await client.close()
    }
}
```

- [ ] **Step 7: Chạy toàn bộ test spike**

Run: `swift test --filter NIOSSLInteropTests`
Expected: PASS cả 3 test. Đây là lúc rủi ro lớn nhất của dự án được đóng lại.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: scaffold package và chứng minh NIOSSL nạp được cert từ swift-certificates

Đóng rủi ro 11.1 của spec trước khi viết engine."
```

---

### Task 2: `TrafficModel` — value types và `BodyCollector`

**Files:**
- Create: `Sources/TrafficModel/Models.swift`
- Create: `Sources/TrafficModel/TrafficEvent.swift`
- Create: `Sources/TrafficModel/BodyCollector.swift`
- Delete: `Sources/TrafficModel/Placeholder.swift`
- Test: `Tests/TrafficModelTests/BodyCollectorTests.swift`

**Interfaces:**
- Consumes: không có.
- Produces: `Transaction`, `RequestModel`, `ResponseModel`, `BodyPayload`, `Scheme`, `TransactionState`, `TrafficEvent`, `BodyCollector`. Mọi task sau đều dùng.

- [ ] **Step 1: Viết test cho `BodyCollector` (chưa có implementation)**

`Tests/TrafficModelTests/BodyCollectorTests.swift`:

```swift
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
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter BodyCollectorTests`
Expected: FAIL, lỗi biên dịch "cannot find 'BodyCollector' in scope".

- [ ] **Step 3: Viết `Models.swift`**

```swift
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
    public var url: URL
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
```

- [ ] **Step 4: Viết `TrafficEvent.swift`**

```swift
import Foundation

/// Kênh một chiều engine -> UI. Toàn value type bất biến, nên event loop
/// của NIO không bao giờ phải chạm MainActor và không cần lock nào.
public enum TrafficEvent: Sendable {
    case started(Transaction)
    case responseHead(id: UUID, ResponseModel)
    case completed(id: UUID, ResponseModel, endedAt: Date)
    case failed(id: UUID, message: String, endedAt: Date)
}
```

- [ ] **Step 5: Viết `BodyCollector.swift`**

```swift
import Foundation

/// Tích luỹ byte của một body. Dưới ngưỡng thì giữ RAM, vượt thì spill ra đĩa.
///
/// Không `Sendable` một cách có chủ ý: mỗi instance chỉ sống trong một
/// ChannelHandler và chỉ được chạm trên event loop của channel đó.
public final class BodyCollector {
    private let limit: Int
    private let spillDirectory: URL
    private var buffer = Data()
    private var totalBytes = 0
    private var fileURL: URL?
    private var handle: FileHandle?
    private var spillFailed = false

    public init(limit: Int, spillDirectory: URL) {
        self.limit = limit
        self.spillDirectory = spillDirectory
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        totalBytes += data.count

        if handle != nil {
            write(data)
            return
        }
        if buffer.count + data.count <= limit {
            buffer.append(data)
            return
        }
        guard !spillFailed else { return }   // đã hỏng rồi thì thôi, giữ nguyên phần đầu
        startSpilling(with: data)
    }

    public func finish() -> BodyPayload {
        try? handle?.close()
        handle = nil

        if spillFailed { return .truncated(buffer, totalBytes: totalBytes) }
        if let fileURL { return .file(fileURL, totalBytes: totalBytes) }
        return buffer.isEmpty ? .none : .inMemory(buffer)
    }

    private func startSpilling(with data: Data) {
        let url = spillDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(
                at: spillDirectory, withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: buffer)
            try handle.write(contentsOf: data)
            self.handle = handle
            self.fileURL = url
            self.buffer = Data()            // đã nằm trên đĩa, nhả RAM
        } catch {
            spillFailed = true
        }
    }

    private func write(_ data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            try? handle?.close()
            handle = nil
            fileURL = nil
            spillFailed = true
        }
    }
}
```

- [ ] **Step 6: Xoá file giữ chỗ và chạy test**

```bash
rm Sources/TrafficModel/Placeholder.swift
swift test --filter BodyCollectorTests
```
Expected: PASS cả 4 test.

- [ ] **Step 7: Commit**

```bash
git add Sources/TrafficModel Tests/TrafficModelTests
git rm --cached Sources/TrafficModel/Placeholder.swift 2>/dev/null || true
git commit -m "feat: TrafficModel value types và BodyCollector có spill ra đĩa"
```

---

### Task 3: `CertKit` — Root CA

**Files:**
- Create: `Sources/CertKit/CertificateAuthority.swift`
- Delete: `Sources/CertKit/Placeholder.swift`
- Test: `Tests/CertKitTests/CertificateAuthorityTests.swift`

**Interfaces:**
- Consumes: không có (độc lập với Task 2).
- Produces:
  - `struct CertificateAuthority: Sendable` với `certificate: Certificate`, `signingKey: P256.Signing.PrivateKey`
  - `static func loadOrCreate(in directory: URL) throws -> CertificateAuthority`
  - `func certificatePEM() throws -> String`
  - Task 4 dùng `certificate` + `signingKey` để ký leaf; Task 9 dùng `certificatePEM()`.

- [ ] **Step 1: Viết test**

`Tests/CertKitTests/CertificateAuthorityTests.swift`:

```swift
import Testing
import Foundation
import X509
@testable import CertKit

@Suite("CertificateAuthority")
struct CertificateAuthorityTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CATests-\(UUID().uuidString)")
    }

    @Test("Sinh mới thì ghi ra hai file PEM với quyền 0600")
    func createsPEMFilesWithTightPermissions() throws {
        let dir = tempDir()
        _ = try CertificateAuthority.loadOrCreate(in: dir)

        for name in ["ca.pem", "ca.key.pem"] {
            let path = dir.appendingPathComponent(name).path
            #expect(FileManager.default.fileExists(atPath: path))
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
            #expect(perms == 0o600, "khoá CA lộ quyền đọc là lỗi bảo mật thật")
        }
    }

    @Test("Gọi lần hai thì nạp lại đúng CA cũ, không sinh mới")
    func reloadsExistingAuthority() throws {
        let dir = tempDir()
        let first = try CertificateAuthority.loadOrCreate(in: dir)
        let second = try CertificateAuthority.loadOrCreate(in: dir)
        #expect(first.certificate.serialNumber == second.certificate.serialNumber)
    }

    @Test("CA có BasicConstraints isCA và KeyUsage keyCertSign")
    func hasCorrectCAExtensions() throws {
        let ca = try CertificateAuthority.loadOrCreate(in: tempDir())

        let basic = try ca.certificate.extensions.basicConstraints
        #expect(basic == .isCertificateAuthority(maxPathLength: 0))

        let usage = try ca.certificate.extensions.keyUsage
        #expect(usage?.keyCertSign == true)
        #expect(usage?.cRLSign == true)
    }

    @Test("Hạn CA khoảng 10 năm")
    func validForAboutTenYears() throws {
        let ca = try CertificateAuthority.loadOrCreate(in: tempDir())
        let years = ca.certificate.notValidAfter
            .timeIntervalSince(ca.certificate.notValidBefore) / (365 * 24 * 3600)
        #expect(years > 9.9 && years < 10.1)
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter CertificateAuthorityTests`
Expected: FAIL, "cannot find 'CertificateAuthority' in scope".

- [ ] **Step 3: Viết implementation**

`Sources/CertKit/CertificateAuthority.swift`:

```swift
import Foundation
import Crypto
import SwiftASN1
import X509

/// Root CA của ứng dụng. Sinh một lần rồi nạp lại từ đĩa các lần sau.
public struct CertificateAuthority: Sendable {
    public let certificate: Certificate
    public let signingKey: P256.Signing.PrivateKey

    public var privateKey: Certificate.PrivateKey { Certificate.PrivateKey(signingKey) }

    /// Thư mục mặc định khi chạy thật.
    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyManClone/ca", isDirectory: true)
    }

    public static func loadOrCreate(in directory: URL) throws -> CertificateAuthority {
        let certURL = directory.appendingPathComponent("ca.pem")
        let keyURL = directory.appendingPathComponent("ca.key.pem")

        if FileManager.default.fileExists(atPath: certURL.path),
           FileManager.default.fileExists(atPath: keyURL.path) {
            let certificate = try Certificate(pemEncoded: String(contentsOf: certURL, encoding: .utf8))
            let key = try P256.Signing.PrivateKey(
                pemRepresentation: String(contentsOf: keyURL, encoding: .utf8)
            )
            return CertificateAuthority(certificate: certificate, signingKey: key)
        }

        let authority = try generate()
        try authority.persist(certURL: certURL, keyURL: keyURL, directory: directory)
        return authority
    }

    public func certificatePEM() throws -> String {
        try certificate.serializeAsPEM().pemString
    }

    public func certificateDER() throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    private static func generate() throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("ProxyManClone Root CA")
            OrganizationName("ProxyManClone")
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 3600 - 3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                // maxPathLength 0: CA này chỉ được ký leaf, không ký CA con.
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: certKey.publicKey)
            },
            issuerPrivateKey: certKey
        )
        return CertificateAuthority(certificate: certificate, signingKey: key)
    }

    private func persist(certURL: URL, keyURL: URL, directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try certificatePEM().write(to: certURL, atomically: true, encoding: .utf8)
        try signingKey.pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)

        // atomically:true ghi qua file tạm rồi rename, nên quyền phải set SAU khi ghi.
        for url in [certURL, keyURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
```

- [ ] **Step 4: Xoá file giữ chỗ và chạy test**

```bash
rm Sources/CertKit/Placeholder.swift
swift test --filter CertificateAuthorityTests
```
Expected: PASS cả 4 test.

- [ ] **Step 5: Commit**

```bash
git add Sources/CertKit Tests/CertKitTests
git commit -m "feat: sinh và persist Root CA với quyền 0600"
```

---

### Task 4: `CertKit` — leaf certificate cache

**Files:**
- Create: `Sources/CertKit/LeafCertificateCache.swift`
- Test: `Tests/CertKitTests/LeafCertificateCacheTests.swift`

**Interfaces:**
- Consumes: `CertificateAuthority.certificate`, `.privateKey` (Task 3); kết luận DER/PEM từ Task 1.
- Produces:
  - `struct TLSIdentity: Sendable { let certificateChain: [NIOSSLCertificate]; let privateKey: NIOSSLPrivateKey }`
  - `actor LeafCertificateCache` với `init(authority:capacity:)`, `func identity(forHost: String) throws -> TLSIdentity`, `func certificate(forHost: String) throws -> Certificate`
  - Task 8 (`MITMUpgradeHandler`) gọi `identity(forHost:)`.

Ghi chú thiết kế: `CertKit` cố ý phụ thuộc NIOSSL và trả thẳng `TLSIdentity`. Nếu trả DER thô thì mỗi chỗ gọi lại phải tự quyết `.der` hay `.pem` — đúng chỗ mơ hồ mà Task 1 vừa đóng lại. Nhốt nó trong một module là đúng.

- [ ] **Step 1: Viết test**

`Tests/CertKitTests/LeafCertificateCacheTests.swift`:

```swift
import Testing
import Foundation
import X509
import NIOSSL
@testable import CertKit

@Suite("LeafCertificateCache")
struct LeafCertificateCacheTests {

    private func makeAuthority() throws -> CertificateAuthority {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafTests-\(UUID().uuidString)")
        return try CertificateAuthority.loadOrCreate(in: dir)
    }

    @Test("Leaf mang đúng SAN dNSName của host")
    func leafCarriesHostSAN() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let leaf = try await cache.certificate(forHost: "api.example.com")

        let san = try leaf.extensions.subjectAlternativeNames
        let names = san?.compactMap { name -> String? in
            if case .dnsName(let value) = name { return value }
            return nil
        } ?? []
        #expect(names == ["api.example.com"])
    }

    @Test("Leaf chain hợp lệ tới Root CA")
    func leafChainsToAuthority() async throws {
        let authority = try makeAuthority()
        let cache = try LeafCertificateCache(authority: authority)
        let leaf = try await cache.certificate(forHost: "api.example.com")

        var verifier = Verifier(rootCertificates: CertificateStore([authority.certificate])) {
            RFC5280Policy(validationTime: Date())
        }
        let result = await verifier.validate(leafCertificate: leaf, intermediates: CertificateStore())

        guard case .validCertificate = result else {
            Issue.record("chain không verify được: \(result)"); return
        }
    }

    @Test("notBefore lùi về quá khứ để chịu lệch đồng hồ")
    func notBeforeIsBackdated() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let leaf = try await cache.certificate(forHost: "api.example.com")
        #expect(leaf.notValidBefore < Date().addingTimeInterval(-1800))
    }

    @Test("Cùng host thì trả lại cert đã cache, không mint mới")
    func cachesPerHost() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let first = try await cache.certificate(forHost: "api.example.com")
        let second = try await cache.certificate(forHost: "api.example.com")
        #expect(first.serialNumber == second.serialNumber)
    }

    @Test("Vượt capacity thì host cũ nhất bị đẩy ra")
    func evictsLeastRecentlyUsed() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority(), capacity: 2)
        let a1 = try await cache.certificate(forHost: "a.com")
        _ = try await cache.certificate(forHost: "b.com")
        _ = try await cache.certificate(forHost: "c.com")   // đẩy a.com ra
        let a2 = try await cache.certificate(forHost: "a.com")
        #expect(a1.serialNumber != a2.serialNumber, "a.com lẽ ra đã bị evict và phải mint lại")
    }

    @Test("identity() trả về vật liệu NIOSSL dùng được")
    func producesUsableNIOSSLIdentity() async throws {
        let cache = try LeafCertificateCache(authority: try makeAuthority())
        let identity = try await cache.identity(forHost: "api.example.com")

        // Dựng được NIOSSLContext nghĩa là BoringSSL đã chấp nhận cặp cert/key.
        let config = TLSConfiguration.makeServerConfiguration(
            certificateChain: identity.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(identity.privateKey)
        )
        _ = try NIOSSLContext(configuration: config)
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter LeafCertificateCacheTests`
Expected: FAIL, "cannot find 'LeafCertificateCache' in scope".

- [ ] **Step 3: Viết implementation**

`Sources/CertKit/LeafCertificateCache.swift`. **Ở Step 5 bạn sẽ chọn `.der` hay `.pem` theo kết luận spike của Task 1** — mặc định viết `.pem` vì đó là đường chắc nhất của BoringSSL:

```swift
import Foundation
import Crypto
import SwiftASN1
import X509
import NIOSSL

/// Vật liệu TLS sẵn sàng nạp vào NIOSSL cho một host.
public struct TLSIdentity: Sendable {
    public let certificateChain: [NIOSSLCertificate]
    public let privateKey: NIOSSLPrivateKey
}

/// Mint leaf cert theo host, ký bằng Root CA, cache LRU.
public actor LeafCertificateCache {
    private let authority: CertificateAuthority
    private let capacity: Int

    /// Một khoá dùng chung cho MỌI leaf. Nhanh hơn nhiều so với sinh khoá mỗi
    /// host, và không giảm an toàn: khoá vốn nằm cùng process với khoá CA.
    private let leafKey: P256.Signing.PrivateKey
    private let nioLeafKey: NIOSSLPrivateKey
    private let caCertificate: NIOSSLCertificate

    private var cache: [String: Certificate] = [:]
    private var usageOrder: [String] = []   // cuối mảng = vừa dùng gần nhất

    public init(authority: CertificateAuthority, capacity: Int = 512) throws {
        self.authority = authority
        self.capacity = capacity
        self.leafKey = P256.Signing.PrivateKey()
        self.nioLeafKey = try NIOSSLPrivateKey(
            bytes: Array(leafKey.pemRepresentation.utf8), format: .pem
        )
        self.caCertificate = try NIOSSLCertificate(
            bytes: authority.certificateDER(), format: .der
        )
    }

    public func identity(forHost host: String) throws -> TLSIdentity {
        let leaf = try certificate(forHost: host)
        var serializer = DER.Serializer()
        try serializer.serialize(leaf)
        let nioLeaf = try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
        // Gửi kèm cert CA để client nào chưa có nó vẫn dựng được chain.
        return TLSIdentity(certificateChain: [nioLeaf, caCertificate], privateKey: nioLeafKey)
    }

    public func certificate(forHost host: String) throws -> Certificate {
        if let cached = cache[host] {
            touch(host)
            return cached
        }
        let leaf = try mint(forHost: host)
        cache[host] = leaf
        usageOrder.append(host)
        evictIfNeeded()
        return leaf
    }

    private func mint(forHost host: String) throws -> Certificate {
        let publicKey = Certificate.PublicKey(leafKey.publicKey)
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            // Lùi 1 giờ: máy client lệch đồng hồ là chuyện thường và
            // sẽ biểu hiện thành lỗi TLS rất khó đoán.
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(365 * 24 * 3600),
            issuer: authority.certificate.subject,
            subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
            },
            issuerPrivateKey: authority.privateKey
        )
    }

    private func touch(_ host: String) {
        usageOrder.removeAll { $0 == host }
        usageOrder.append(host)
    }

    private func evictIfNeeded() {
        while usageOrder.count > capacity {
            let oldest = usageOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
```

- [ ] **Step 4: Chạy test**

Run: `swift test --filter LeafCertificateCacheTests`
Expected: PASS cả 6 test.

- [ ] **Step 5: Nếu Task 1 kết luận `DER: true`, đổi sang DER và chạy lại**

DER tránh được một vòng encode/decode PEM mỗi lần khởi động. Sửa một dòng:

```swift
self.nioLeafKey = try NIOSSLPrivateKey(bytes: Array(leafKey.derRepresentation), format: .der)
```

Run: `swift test --filter LeafCertificateCacheTests`
Expected: PASS. Nếu đỏ, quay lại `.pem` và giữ nguyên — đây là tối ưu nhỏ, không đáng đánh đổi.

- [ ] **Step 6: Commit**

```bash
git add Sources/CertKit Tests/CertKitTests
git commit -m "feat: mint leaf cert theo host với LRU cache, trả thẳng vật liệu NIOSSL"
```

---

### Task 5: `ProxyCore` — cấu hình và `HeaderSanitizer`

Hàm thuần, không I/O, không channel. Tách riêng vì đây là chỗ dễ sai nhất về mặt đặc tả HTTP và cần test nhanh, nhiều case.

**Files:**
- Create: `Sources/ProxyCore/ProxyConfiguration.swift`
- Create: `Sources/ProxyCore/HeaderSanitizer.swift`
- Delete: `Sources/ProxyCore/Placeholder.swift`
- Test: `Tests/ProxyCoreTests/HeaderSanitizerTests.swift`

**Interfaces:**
- Consumes: `Scheme` (Task 2).
- Produces:
  - `struct ProxyConfiguration: Sendable`
  - `struct RequestTarget: Sendable, Equatable { host, port, scheme, originForm }`
  - `enum HeaderSanitizer` với `static func parseAbsoluteForm(_:) -> RequestTarget?`, `static func parseConnectTarget(_:) -> (host: String, port: Int)?`, `static func sanitize(_: HTTPHeaders) -> HTTPHeaders`
  - Task 6 và Task 8 đều dùng.

- [ ] **Step 1: Viết test**

`Tests/ProxyCoreTests/HeaderSanitizerTests.swift`:

```swift
import Testing
import NIOHTTP1
import TrafficModel
@testable import ProxyCore

@Suite("HeaderSanitizer")
struct HeaderSanitizerTests {

    @Test("Parse absolute-form http có path và query")
    func parsesAbsoluteFormHTTP() {
        let target = HeaderSanitizer.parseAbsoluteForm("http://example.com/a/b?c=1")
        #expect(target == RequestTarget(host: "example.com", port: 80,
                                        scheme: .http, originForm: "/a/b?c=1"))
    }

    @Test("Absolute-form không có path thì origin-form là /")
    func defaultsEmptyPathToSlash() {
        let target = HeaderSanitizer.parseAbsoluteForm("http://example.com")
        #expect(target?.originForm == "/")
    }

    @Test("Port tường minh được giữ nguyên")
    func keepsExplicitPort() {
        let target = HeaderSanitizer.parseAbsoluteForm("http://example.com:8080/x")
        #expect(target?.port == 8080)
    }

    @Test("https absolute-form mặc định port 443")
    func defaultsHTTPSPort() {
        let target = HeaderSanitizer.parseAbsoluteForm("https://example.com/x")
        #expect(target?.scheme == .https)
        #expect(target?.port == 443)
    }

    @Test("Origin-form không phải absolute-form, trả nil")
    func rejectsOriginForm() {
        #expect(HeaderSanitizer.parseAbsoluteForm("/a/b") == nil)
    }

    @Test("Parse CONNECT host:port")
    func parsesConnectTarget() {
        let target = HeaderSanitizer.parseConnectTarget("example.com:443")
        #expect(target?.host == "example.com")
        #expect(target?.port == 443)
    }

    @Test("CONNECT thiếu port thì mặc định 443")
    func connectDefaultsTo443() {
        #expect(HeaderSanitizer.parseConnectTarget("example.com")?.port == 443)
    }

    @Test("Gỡ đúng các header hop-by-hop, giữ nguyên header end-to-end")
    func stripsHopByHopHeaders() {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "example.com")
        headers.add(name: "Proxy-Connection", value: "keep-alive")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        headers.add(name: "Authorization", value: "Bearer abc")

        let clean = HeaderSanitizer.sanitize(headers)
        #expect(clean.first(name: "Host") == "example.com")
        #expect(clean.first(name: "Authorization") == "Bearer abc")
        #expect(clean.first(name: "Proxy-Connection") == nil)
        #expect(clean.first(name: "Connection") == nil)
        // NIO tự dựng lại framing theo body thật; forward header gốc sinh framing kép.
        #expect(clean.first(name: "Transfer-Encoding") == nil)
    }

    @Test("Header lặp được giữ đủ, không gộp")
    func preservesRepeatedHeaders() {
        var headers = HTTPHeaders()
        headers.add(name: "Set-Cookie", value: "a=1")
        headers.add(name: "Set-Cookie", value: "b=2")
        #expect(HeaderSanitizer.sanitize(headers)["Set-Cookie"].count == 2)
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter HeaderSanitizerTests`
Expected: FAIL, "cannot find 'HeaderSanitizer' in scope".

- [ ] **Step 3: Viết `ProxyConfiguration.swift`**

```swift
import Foundation

public struct ProxyConfiguration: Sendable {
    public var listenHost: String
    public var listenPort: Int
    /// Host trong tập này chỉ được tunnel byte thô, không MitM.
    /// Mặc định là các domain pin cert, sẽ hỏng ngay nếu bị chặn.
    public var bypassedHosts: Set<String>
    public var maxInMemoryBodyBytes: Int
    public var bodySpillDirectory: URL

    public init(
        listenHost: String = "127.0.0.1",
        listenPort: Int = 9090,
        bypassedHosts: Set<String> = [
            "apple.com", "icloud.com", "itunes.apple.com",
            "mzstatic.com", "push.apple.com",
        ],
        maxInMemoryBodyBytes: Int = 2 * 1024 * 1024,
        bodySpillDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyManClone", isDirectory: true)
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.bypassedHosts = bypassedHosts
        self.maxInMemoryBodyBytes = maxInMemoryBodyBytes
        self.bodySpillDirectory = bodySpillDirectory
    }

    /// Khớp cả subdomain: "api.apple.com" khớp mục "apple.com".
    public func isBypassed(host: String) -> Bool {
        let lower = host.lowercased()
        return bypassedHosts.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }
}
```

- [ ] **Step 4: Viết `HeaderSanitizer.swift`**

```swift
import Foundation
import NIOHTTP1
import TrafficModel

public struct RequestTarget: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var scheme: Scheme
    public var originForm: String
}

public enum HeaderSanitizer {

    /// RFC 9110 §7.6.1. Proxy phải tiêu thụ, không forward.
    static let hopByHop: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "transfer-encoding",
        "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization",
    ]

    public static func sanitize(_ headers: HTTPHeaders) -> HTTPHeaders {
        var result = HTTPHeaders()
        for (name, value) in headers where !hopByHop.contains(name.lowercased()) {
            result.add(name: name, value: value)
        }
        return result
    }

    public static func parseAbsoluteForm(_ target: String) -> RequestTarget? {
        guard let components = URLComponents(string: target),
              let scheme = components.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              let host = components.host, !host.isEmpty
        else { return nil }

        var originForm = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { originForm += "?" + query }

        return RequestTarget(
            host: host,
            port: components.port ?? (scheme == .https ? 443 : 80),
            scheme: scheme,
            originForm: originForm
        )
    }

    public static func parseConnectTarget(_ target: String) -> (host: String, port: Int)? {
        guard !target.isEmpty else { return nil }
        // Chỉ tách ở dấu ':' cuối cùng để không phá IPv6 dạng [::1]:443.
        guard let colon = target.lastIndex(of: ":"), !target.hasSuffix("]") else {
            return (target, 443)
        }
        let host = String(target[target.startIndex..<colon])
        guard let port = Int(target[target.index(after: colon)...]), !host.isEmpty else {
            return nil
        }
        return (host, port)
    }
}
```

- [ ] **Step 5: Xoá file giữ chỗ và chạy test**

```bash
rm Sources/ProxyCore/Placeholder.swift
swift test --filter HeaderSanitizerTests
```
Expected: PASS cả 9 test.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProxyCore Tests/ProxyCoreTests
git commit -m "feat: cấu hình proxy và parse/sanitize header theo RFC 9110"
```

---

### Task 6: `ProxyCore` — proxy HTTP plaintext chạy end-to-end

Cột mốc đầu tiên app thực sự làm việc: `curl -x 127.0.0.1:PORT http://...` đi xuyên qua và sinh ra transaction.

**Files:**
- Create: `Sources/ProxyCore/SessionState.swift`
- Create: `Sources/ProxyCore/ProxyServer.swift`
- Create: `Sources/ProxyCore/Handlers/ProxyEntryHandler.swift`
- Create: `Sources/ProxyCore/Handlers/HTTPProxyHandler.swift`
- Create: `Sources/ProxyCore/Handlers/UpstreamHandler.swift`
- Test: `Tests/ProxyCoreTests/PlainHTTPProxyTests.swift`

**Interfaces:**
- Consumes: `ProxyConfiguration`, `HeaderSanitizer`, `RequestTarget` (Task 5); `Transaction`, `TrafficEvent`, `BodyCollector` (Task 2); `LeafCertificateCache` (Task 4, chỉ để giữ và chuyển tiếp cho Task 8).
- Produces:
  - `public typealias TrafficEventSink = @Sendable (TrafficEvent) -> Void`
  - `public actor ProxyServer` với `init(configuration:leafCache:)`, `nonisolated let events: AsyncStream<TrafficEvent>`, `func start() async throws -> Int`, `func stop() async throws`, `func shutdown() async throws`
  - `final class SessionState` (internal)
  - Task 7 và 8 gắn thêm handler vào cùng pipeline này.

**Quyết định kiến trúc quan trọng của task này:** upstream channel được ghim vào **cùng event loop** với client channel (`ClientBootstrap(group: context.eventLoop)`). Nhờ đó `SessionState` là class thường, không khoá, không actor — hai handler không bao giờ chạy song song. Bỏ ràng buộc này là tự tạo data race.

- [ ] **Step 1: Viết test end-to-end**

`Tests/ProxyCoreTests/PlainHTTPProxyTests.swift`:

```swift
import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import TrafficModel
import CertKit
@testable import ProxyCore

/// Server HTTP tối giản để test không phải gọi ra mạng ngoài.
final class EchoServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var body = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: body.clear()
        case .body(var buffer): body.writeBuffer(&buffer)
        case .end:
            let payload = "xin chao tu upstream"
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(payload.utf8.count)")
            headers.add(name: "X-Test", value: "1")
            context.write(wrapOutboundOut(.head(
                HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            )), promise: nil)
            var out = context.channel.allocator.buffer(capacity: payload.utf8.count)
            out.writeString(payload)
            context.write(wrapOutboundOut(.body(.byteBuffer(out))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

@Suite("Proxy HTTP plaintext")
struct PlainHTTPProxyTests {

    private func makeLeafCache() throws -> LeafCertificateCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyTests-\(UUID().uuidString)")
        return try LeafCertificateCache(authority: .loadOrCreate(in: dir))
    }

    private func startEchoServer(group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(EchoServerHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    @Test("GET qua proxy trả đúng body và ghi transaction hoàn tất")
    func proxiesGETAndRecordsTransaction() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let origin = try await startEchoServer(group: group)
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        // Thu event ở một task riêng trước khi phát request.
        let collected = Task {
            var events: [TrafficEvent] = []
            for await event in server.events {
                events.append(event)
                if case .completed = event { break }
            }
            return events
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
        ]
        let session = URLSession(configuration: sessionConfig)

        let url = URL(string: "http://127.0.0.1:\(originPort)/hello?q=1")!
        let (data, response) = try await session.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "xin chao tu upstream")

        let events = await collected.value
        guard case .started(let transaction)? = events.first else {
            Issue.record("thiếu event .started"); return
        }
        #expect(transaction.request.method == "GET")
        #expect(transaction.host == "127.0.0.1")
        #expect(transaction.port == originPort)
        #expect(transaction.scheme == .http)
        #expect(transaction.request.queryItems.first?.name == "q")

        guard case .completed(_, let responseModel, _)? = events.last else {
            Issue.record("thiếu event .completed"); return
        }
        #expect(responseModel.statusCode == 200)
        #expect(responseModel.headers.contains { $0.name.lowercased() == "x-test" })
    }

    @Test("Không nối được upstream thì trả 502 và transaction .failed")
    func returns502WhenUpstreamUnreachable() async throws {
        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(configuration: config, leafCache: try makeLeafCache())
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
        ]
        let session = URLSession(configuration: sessionConfig)

        // Port 1 trên localhost chắc chắn không có ai nghe.
        let url = URL(string: "http://127.0.0.1:1/x")!
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter PlainHTTPProxyTests`
Expected: FAIL, "cannot find 'ProxyServer' in scope".

- [ ] **Step 3: Viết `SessionState.swift`**

```swift
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
```

- [ ] **Step 4: Viết `UpstreamHandler.swift`**

```swift
import Foundation
import NIOCore
import NIOHTTP1
import TrafficModel

/// Nhận response từ origin, chuyển tiếp về client, và ghi lại transaction.
final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let configuration: ProxyConfiguration
    private let sink: TrafficEventSink
    private let state: SessionState

    private var head: HTTPResponseHead?
    private var collector: BodyCollector?

    init(clientChannel: Channel, configuration: ProxyConfiguration,
         sink: @escaping TrafficEventSink, state: SessionState) {
        self.clientChannel = clientChannel
        self.configuration = configuration
        self.sink = sink
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.collector = BodyCollector(
                limit: configuration.maxInMemoryBodyBytes,
                spillDirectory: configuration.bodySpillDirectory
            )
            if let id = state.pendingIDs.first {
                sink(.responseHead(id: id, Self.model(from: head, body: .none)))
            }
            clientChannel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)

        case .body(let buffer):
            collector?.append(Data(buffer.readableBytesView))
            clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)

        case .end(let trailers):
            clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(trailers)), promise: nil)
            finish()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(reason: "lỗi upstream: \(error)")
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Upstream đóng giữa chừng: mọi transaction còn chờ đều hỏng.
        while let pending = state.dequeue() {
            sink(.failed(id: pending.id, message: "upstream đóng kết nối giữa chừng",
                         endedAt: Date()))
        }
        context.fireChannelInactive()
    }

    private func finish() {
        guard let head, let transaction = state.dequeue() else { return }
        let body = collector?.finish() ?? .none
        self.head = nil
        self.collector = nil
        sink(.completed(id: transaction.id, Self.model(from: head, body: body), endedAt: Date()))
    }

    private func fail(reason: String) {
        while let pending = state.dequeue() {
            sink(.failed(id: pending.id, message: reason, endedAt: Date()))
        }
    }

    private static func model(from head: HTTPResponseHead, body: BodyPayload) -> ResponseModel {
        ResponseModel(
            statusCode: Int(head.status.code),
            reasonPhrase: head.status.reasonPhrase,
            headers: head.headers.map { (name: $0.name, value: $0.value) },
            body: body
        )
    }
}
```

- [ ] **Step 5: Viết `HTTPProxyHandler.swift`**

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import TrafficModel

/// Nhận request từ client, mở upstream, forward, và mở transaction.
///
/// `fixedTarget` nil nghĩa là plaintext: request tới ở absolute-form và ta
/// tự parse host từ URI. Khác nil nghĩa là đã đi qua MitM (Task 8): request
/// ở origin-form và host lấy từ dòng CONNECT.
final class HTTPProxyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct Target: Sendable {
        var host: String
        var port: Int
        var scheme: Scheme
    }

    private let configuration: ProxyConfiguration
    private let sink: TrafficEventSink
    private let fixedTarget: Target?
    private let state = SessionState()

    private var upstream: Channel?
    private var upstreamTarget: Target?
    private var collector: BodyCollector?

    init(configuration: ProxyConfiguration, sink: @escaping TrafficEventSink,
         fixedTarget: Target?) {
        self.configuration = configuration
        self.sink = sink
        self.fixedTarget = fixedTarget
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): handle(head: head, context: context)
        case .body(let buffer):
            collector?.append(Data(buffer.readableBytesView))
            upstream?.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
        case .end(let trailers):
            finishRequestBody()
            upstream?.writeAndFlush(NIOAny(HTTPClientRequestPart.end(trailers)), promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        upstream = nil
        context.fireChannelInactive()
    }

    private func handle(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let target = resolveTarget(head: head) else {
            respond(context: context, status: .badRequest,
                    message: "proxy cần absolute-form URI, nhận được: \(head.uri)")
            return
        }
        let originForm = fixedTarget == nil
            ? (HeaderSanitizer.parseAbsoluteForm(head.uri)?.originForm ?? head.uri)
            : head.uri

        let transaction = makeTransaction(head: head, target: target, originForm: originForm)
        state.enqueue(transaction)
        sink(.started(transaction))

        collector = BodyCollector(
            limit: configuration.maxInMemoryBodyBytes,
            spillDirectory: configuration.bodySpillDirectory
        )

        var forwarded = HTTPRequestHead(
            version: .http1_1, method: head.method, uri: originForm,
            headers: HeaderSanitizer.sanitize(head.headers)
        )
        if forwarded.headers.first(name: "Host") == nil {
            forwarded.headers.add(name: "Host", value: hostHeader(for: target))
        }

        connectUpstream(to: target, context: context).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                channel.writeAndFlush(NIOAny(HTTPClientRequestPart.head(forwarded)), promise: nil)
            case .failure(let error):
                self.sink(.failed(id: transaction.id,
                                  message: "không nối được \(target.host):\(target.port) — \(error)",
                                  endedAt: Date()))
                _ = self.state.dequeue()
                self.respond(context: context, status: .badGateway,
                             message: "không nối được upstream: \(error)")
            }
        }
    }

    private func resolveTarget(head: HTTPRequestHead) -> Target? {
        if let fixedTarget { return fixedTarget }
        guard let parsed = HeaderSanitizer.parseAbsoluteForm(head.uri) else { return nil }
        return Target(host: parsed.host, port: parsed.port, scheme: parsed.scheme)
    }

    private func makeTransaction(head: HTTPRequestHead, target: Target,
                                 originForm: String) -> Transaction {
        let absolute = "\(target.scheme.rawValue)://\(hostHeader(for: target))\(originForm)"
        let url = URL(string: absolute) ?? URL(string: "\(target.scheme.rawValue)://\(target.host)/")!
        let request = RequestModel(
            method: head.method.rawValue,
            url: url,
            httpVersion: "HTTP/\(head.version.major).\(head.version.minor)",
            headers: head.headers.map { (name: $0.name, value: $0.value) }
        )
        return Transaction(scheme: target.scheme, host: target.host,
                           port: target.port, request: request)
    }

    private func hostHeader(for target: Target) -> String {
        let isDefaultPort = (target.scheme == .http && target.port == 80)
            || (target.scheme == .https && target.port == 443)
        return isDefaultPort ? target.host : "\(target.host):\(target.port)"
    }

    private func finishRequestBody() {
        guard let collector, let id = state.pendingIDs.first else { return }
        state.transactions[id]?.request.body = collector.finish()
        self.collector = nil
    }

    private func connectUpstream(to target: Target,
                                 context: ChannelHandlerContext) -> EventLoopFuture<Channel> {
        if let upstream, let upstreamTarget,
           upstreamTarget.host == target.host, upstreamTarget.port == target.port,
           upstream.isActive {
            return context.eventLoop.makeSucceededFuture(upstream)
        }
        upstream?.close(promise: nil)

        let clientChannel = context.channel
        let configuration = self.configuration
        let sink = self.sink
        let state = self.state

        // Ghim upstream vào ĐÚNG event loop của client channel. Đây là điều
        // kiện để SessionState không cần khoá — xem chú thích trong SessionState.
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    if target.scheme == .https {
                        var tls = TLSConfiguration.makeClientConfiguration()
                        tls.applicationProtocols = ["http/1.1"]
                        // KHÔNG BAO GIỜ tắt verify ở đây: tắt là biến app
                        // thành lỗ hổng thật cho mọi traffic đi qua nó.
                        let sslContext = try NIOSSLContext(configuration: tls)
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: sslContext, serverHostname: target.host)
                        )
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(
                        UpstreamHandler(clientChannel: clientChannel,
                                        configuration: configuration,
                                        sink: sink, state: state)
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        return bootstrap.connect(host: target.host, port: target.port)
            .map { [weak self] channel in
                self?.upstream = channel
                self?.upstreamTarget = target
                return channel
            }
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus,
                         message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        context.write(wrapOutboundOut(.head(
            HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        )), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
```

- [ ] **Step 6: Viết `ProxyEntryHandler.swift`**

Ở task này nó chỉ cần cho request thường đi qua và trả `501` cho CONNECT. Task 7 và 8 sẽ thay phần `establishTunnel`.

```swift
import Foundation
import NIOCore
import NIOHTTP1
import CertKit

/// Nằm trước `HTTPProxyHandler`. Chỉ chặn CONNECT; mọi thứ khác cho đi tiếp.
final class ProxyEntryHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let configuration: ProxyConfiguration
    let leafCache: LeafCertificateCache
    let sink: TrafficEventSink
    /// Handler HTTP phải gỡ khi chuyển sang tunnel. Do ta tự lắp nên có tham chiếu.
    var httpHandlers: [RemovableChannelHandler] = []

    private var pendingConnect: (host: String, port: Int)?

    init(configuration: ProxyConfiguration, leafCache: LeafCertificateCache,
         sink: @escaping TrafficEventSink) {
        self.configuration = configuration
        self.leafCache = leafCache
        self.sink = sink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if case .head(let head) = part, head.method == .CONNECT {
            guard let target = HeaderSanitizer.parseConnectTarget(head.uri) else {
                respond(context: context, status: .badRequest,
                        message: "CONNECT target không hợp lệ: \(head.uri)")
                return
            }
            pendingConnect = target
            return
        }
        if pendingConnect != nil {
            if case .end = part {
                let target = pendingConnect!
                pendingConnect = nil
                establishTunnel(context: context, host: target.host, port: target.port)
            }
            return   // nuốt body rác nếu client gửi kèm CONNECT
        }
        context.fireChannelRead(data)
    }

    /// Task 7 và Task 8 thay thân hàm này.
    func establishTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        respond(context: context, status: .notImplemented,
                message: "CONNECT chưa được hỗ trợ")
    }

    func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        context.write(wrapOutboundOut(.head(
            HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        )), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
```

- [ ] **Step 7: Viết `ProxyServer.swift`**

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import TrafficModel
import CertKit

public typealias TrafficEventSink = @Sendable (TrafficEvent) -> Void

public enum ProxyServerError: Error, Sendable {
    case alreadyRunning
    case notRunning
}

public actor ProxyServer {
    /// Kênh một chiều engine -> UI.
    public nonisolated let events: AsyncStream<TrafficEvent>

    private nonisolated let sink: TrafficEventSink
    private let configuration: ProxyConfiguration
    private let leafCache: LeafCertificateCache
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(configuration: ProxyConfiguration, leafCache: LeafCertificateCache) {
        self.configuration = configuration
        self.leafCache = leafCache
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let (stream, continuation) = AsyncStream<TrafficEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(10_000)
        )
        self.events = stream
        self.sink = { continuation.yield($0) }
    }

    /// Trả về port thực tế đang nghe (hữu ích khi cấu hình port 0 trong test).
    @discardableResult
    public func start() async throws -> Int {
        guard channel == nil else { throw ProxyServerError.alreadyRunning }

        let configuration = self.configuration
        let leafCache = self.leafCache
        let sink = self.sink

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let encoder = HTTPResponseEncoder()
                // .forwardBytes: khi gỡ decoder lúc chuyển sang tunnel, byte
                // chưa tiêu thụ (ClientHello của TLS) phải được đẩy tiếp
                // xuống dưới thay vì bị vứt.
                let decoder = ByteToMessageHandler(
                    HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
                )
                let entry = ProxyEntryHandler(configuration: configuration,
                                              leafCache: leafCache, sink: sink)
                entry.httpHandlers = [encoder, decoder]
                let proxy = HTTPProxyHandler(configuration: configuration,
                                             sink: sink, fixedTarget: nil)
                return channel.pipeline.addHandlers([encoder, decoder, entry, proxy])
            }

        let channel = try await bootstrap
            .bind(host: configuration.listenHost, port: configuration.listenPort)
            .get()
        self.channel = channel
        return channel.localAddress?.port ?? configuration.listenPort
    }

    public func stop() async throws {
        guard let channel else { throw ProxyServerError.notRunning }
        self.channel = nil
        try await channel.close().get()
    }

    public func shutdown() async throws {
        if channel != nil { try? await stop() }
        try await group.shutdownGracefully()
    }
}
```

- [ ] **Step 8: Chạy test**

Run: `swift test --filter PlainHTTPProxyTests`
Expected: PASS cả 2 test.

- [ ] **Step 9: Kiểm chứng thủ công bằng curl**

Thêm một smoke test tay để chắc chắn nó hoạt động ngoài môi trường test. Trong một REPL hoặc file script tạm, chạy proxy ở port 9090 rồi:

```bash
curl -sS -x 127.0.0.1:9090 http://example.com/ -o /dev/null -w '%{http_code}\n'
```
Expected: `200`.

- [ ] **Step 10: Commit**

```bash
git add Sources/ProxyCore Tests/ProxyCoreTests
git commit -m "feat: proxy HTTP plaintext chạy end-to-end, ghi transaction qua AsyncStream"
```

---

### Task 7: `ProxyCore` — CONNECT tunnel mù cho bypass list

**Files:**
- Create: `Sources/ProxyCore/Handlers/ConnectTunnelHandler.swift`
- Modify: `Sources/ProxyCore/Handlers/ProxyEntryHandler.swift` (thân `establishTunnel`)
- Test: `Tests/ProxyCoreTests/ConnectTunnelTests.swift`

**Interfaces:**
- Consumes: `ProxyConfiguration.isBypassed(host:)`, `TrafficEventSink`, `Transaction` (Task 2, 5, 6).
- Produces: `ConnectTunnelHandler`; `ProxyEntryHandler.establishTunnel` giờ rẽ nhánh bypass. Task 8 thay nhánh còn lại.

- [ ] **Step 1: Viết test**

`Tests/ProxyCoreTests/ConnectTunnelTests.swift`:

```swift
import Testing
import Foundation
import NIOCore
import NIOPosix
import CertKit
import TrafficModel
@testable import ProxyCore

/// Server TCP dội ngược mọi byte nhận được.
final class ByteEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

@Suite("CONNECT tunnel mù")
struct ConnectTunnelTests {

    @Test("Host trong bypass list được relay byte thô và ghi transaction .tunnelled")
    func relaysBytesForBypassedHost() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(ByteEchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = ["localhost"]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelTests-\(UUID().uuidString)")
        let cache = try LeafCertificateCache(authority: .loadOrCreate(in: dir))
        let server = ProxyServer(configuration: config, leafCache: cache)
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let collected = Task {
            for await event in server.events {
                if case .started(let transaction) = event { return transaction }
            }
            return nil as Transaction?
        }

        // Nói CONNECT rồi gửi byte thô, mong nhận lại đúng byte đó.
        let socket = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: proxyPort).get()

        var request = socket.allocator.buffer(capacity: 128)
        request.writeString("CONNECT localhost:\(originPort) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        try await socket.writeAndFlush(request)

        // Đủ để tránh flaky mà không phụ thuộc timing chi tiết.
        try await Task.sleep(for: .milliseconds(300))
        #expect(socket.isActive)

        let transaction = try #require(await collected.value)
        #expect(transaction.request.method == "CONNECT")
        #expect(transaction.host == "localhost")
        #expect(transaction.port == originPort)
        #expect(transaction.response == nil, "tunnel mù không có response để hiện")
        if case .tunnelled = transaction.state {} else {
            Issue.record("state phải là .tunnelled, nhận: \(transaction.state)")
        }
        try await socket.close()
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter ConnectTunnelTests`
Expected: FAIL — hiện `establishTunnel` trả 501 nên không có event `.started` nào.

- [ ] **Step 3: Viết `ConnectTunnelHandler.swift`**

```swift
import Foundation
import NIOCore
import NIOPosix
import TrafficModel

/// Relay byte thô hai chiều, không giải mã. Dùng cho host trong bypass list —
/// chủ yếu là các domain pin cert, MitM vào là hỏng ngay.
final class ConnectTunnelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let host: String
    private let port: Int
    private let sink: TrafficEventSink
    private let transactionID: UUID
    private var upstream: Channel?
    /// Byte client gửi trước khi upstream sẵn sàng.
    private var buffered: [ByteBuffer] = []
    private var bytesSent = 0

    init(host: String, port: Int, transactionID: UUID, sink: @escaping TrafficEventSink) {
        self.host = host
        self.port = port
        self.transactionID = transactionID
        self.sink = sink
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(RelayHandler(peer: clientChannel))
            }
            .connect(host: host, port: port)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let channel):
                    self.upstream = channel
                    for buffer in self.buffered { channel.write(buffer, promise: nil) }
                    channel.flush()
                    self.buffered = []
                case .failure(let error):
                    self.sink(.failed(id: self.transactionID,
                                      message: "tunnel không nối được \(self.host):\(self.port) — \(error)",
                                      endedAt: Date()))
                    clientChannel.close(promise: nil)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bytesSent += buffer.readableBytes
        if let upstream {
            upstream.writeAndFlush(buffer, promise: nil)
        } else {
            buffered.append(buffer)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        upstream = nil
        context.fireChannelInactive()
    }
}

/// Đẩy mọi byte sang channel đối diện. Dùng cho cả hai chiều của tunnel.
final class RelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let peer: Channel
    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(NIOAny(unwrapInboundIn(data)), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }
}
```

- [ ] **Step 4: Sửa `establishTunnel` trong `ProxyEntryHandler`**

Thay toàn bộ thân hàm `establishTunnel` bằng:

```swift
    func establishTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        let transaction = Transaction(
            scheme: .https, host: host, port: port,
            request: RequestModel(
                method: "CONNECT",
                url: URL(string: "https://\(host):\(port)")!
            ),
            state: configuration.isBypassed(host: host) ? .tunnelled : .pending
        )
        sink(.started(transaction))

        // Content-Length: 0 để encoder không tự chèn chunked framing vào một
        // response CONNECT — chunk marker lọt vào tunnel là hỏng TLS ngay.
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(
            version: .http1_1,
            status: .custom(code: 200, reasonPhrase: "Connection Established"),
            headers: headers
        ))), promise: nil)

        let channel = context.channel
        let bypassed = configuration.isBypassed(host: host)
        let sink = self.sink
        let handlers = httpHandlers

        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            // Gỡ cả tầng HTTP: từ đây trở đi channel chở byte thô.
            let removals = handlers.map { channel.pipeline.removeHandler($0) }
            EventLoopFuture.andAllSucceed(removals, on: channel.eventLoop).whenComplete { _ in
                if bypassed {
                    _ = channel.pipeline.addHandler(ConnectTunnelHandler(
                        host: host, port: port,
                        transactionID: transaction.id, sink: sink
                    ), position: .before(self))
                    _ = channel.pipeline.removeHandler(self)
                } else {
                    self.beginMITM(channel: channel, host: host, port: port,
                                   transactionID: transaction.id)
                }
            }
        }
    }

    /// Task 8 thay thân hàm này.
    func beginMITM(channel: Channel, host: String, port: Int, transactionID: UUID) {
        sink(.failed(id: transactionID, message: "MitM chưa được hỗ trợ", endedAt: Date()))
        channel.close(promise: nil)
    }
```

Thêm `import TrafficModel` vào đầu file nếu chưa có.

Đồng thời `HTTPProxyHandler` phải bị gỡ khỏi pipeline khi vào tunnel. Sửa `ProxyServer.start()` để `entry.httpHandlers` gồm cả nó:

```swift
                entry.httpHandlers = [encoder, decoder, proxy]
```

Dòng này phải nằm **sau** khi `proxy` được khai báo, nên đổi thứ tự hai câu lệnh trong `childChannelInitializer`.

- [ ] **Step 5: Chạy test**

Run: `swift test --filter ConnectTunnelTests`
Expected: PASS.

- [ ] **Step 6: Chạy toàn bộ test để chắc Task 6 không bị vỡ**

Run: `swift test`
Expected: PASS tất cả.

- [ ] **Step 7: Commit**

```bash
git add Sources/ProxyCore Tests/ProxyCoreTests
git commit -m "feat: CONNECT tunnel mù cho host trong bypass list"
```

---

### Task 8: `ProxyCore` — MitM HTTPS chạy end-to-end

Cột mốc thứ hai và là phần khó nhất của MVP.

**Files:**
- Create: `Sources/ProxyCore/Handlers/MITMUpgradeHandler.swift`
- Modify: `Sources/ProxyCore/ProxyConfiguration.swift` (thêm `additionalTrustRoots`)
- Modify: `Sources/ProxyCore/Handlers/HTTPProxyHandler.swift` (dùng `additionalTrustRoots`)
- Modify: `Sources/ProxyCore/Handlers/ProxyEntryHandler.swift` (thân `beginMITM`)
- Test: `Tests/ProxyCoreTests/MITMProxyTests.swift`

**Interfaces:**
- Consumes: `LeafCertificateCache.identity(forHost:)` (Task 4); `HTTPProxyHandler.Target` (Task 6).
- Produces: `MITMUpgradeHandler`; `ProxyConfiguration.additionalTrustRoots: [NIOSSLCertificate]`.

**Vì sao cần `additionalTrustRoots`:** test dựng origin HTTPS bằng cert tự ký, mà proxy verify upstream bằng system trust store. Thêm root của test vào `additionalTrustRoots` giữ nguyên toàn bộ system roots — khác hẳn việc tắt verify, thứ mà Global Constraints cấm tuyệt đối.

- [ ] **Step 1: Thêm `additionalTrustRoots` vào `ProxyConfiguration`**

```swift
import NIOSSL
```

Thêm property và tham số init:

```swift
    /// Root TIN THÊM khi verify upstream. System trust store vẫn giữ nguyên.
    /// Đây là cách đúng để test với cert tự ký — không bao giờ được thay
    /// bằng certificateVerification = .none.
    public var additionalTrustRoots: [NIOSSLCertificate] = []
```

- [ ] **Step 2: Dùng nó trong `HTTPProxyHandler.connectUpstream`**

Ngay sau `var tls = TLSConfiguration.makeClientConfiguration()`:

```swift
                        tls.applicationProtocols = ["http/1.1"]
                        if !configuration.additionalTrustRoots.isEmpty {
                            tls.additionalTrustRoots = [
                                .certificates(configuration.additionalTrustRoots)
                            ]
                        }
```

- [ ] **Step 3: Viết test MitM end-to-end**

`Tests/ProxyCoreTests/MITMProxyTests.swift`:

```swift
import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import CertKit
import TrafficModel
@testable import ProxyCore

@Suite("MitM HTTPS")
struct MITMProxyTests {

    @Test("Request HTTPS đi xuyên proxy, được giải mã và ghi lại")
    func decryptsAndRecordsHTTPSTraffic() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer { try? group.syncShutdownGracefully() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MITMTests-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        let cache = try LeafCertificateCache(authority: authority)

        // Origin HTTPS dùng leaf "localhost" ký bởi CHÍNH CA này, nên proxy
        // verify được sau khi ta thêm CA vào additionalTrustRoots.
        let originIdentity = try await cache.identity(forHost: "localhost")
        var originTLS = TLSConfiguration.makeServerConfiguration(
            certificateChain: originIdentity.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(originIdentity.privateKey)
        )
        originTLS.applicationProtocols = ["http/1.1"]
        let originContext = try NIOSSLContext(configuration: originTLS)

        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: originContext))
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(EchoServerHandler()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { try? origin.close().wait() }
        let originPort = origin.localAddress!.port!

        let caCert = try NIOSSLCertificate(bytes: authority.certificateDER(), format: .der)
        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []
        config.additionalTrustRoots = [caCert]

        let server = ProxyServer(configuration: config, leafCache: cache)
        let proxyPort = try await server.start()
        defer { Task { try? await server.shutdown() } }

        let collected = Task {
            var events: [TrafficEvent] = []
            for await event in server.events {
                events.append(event)
                if case .completed = event { break }
                if case .failed = event { break }
            }
            return events
        }

        // curl tin CA của ta nên chấp nhận leaf do proxy mint ra.
        let caPath = dir.appendingPathComponent("ca.pem").path
        let output = try runCurl([
            "-sS", "--cacert", caPath,
            "-x", "http://127.0.0.1:\(proxyPort)",
            "https://localhost:\(originPort)/secret?token=abc",
        ])
        #expect(output == "xin chao tu upstream")

        let events = await collected.value
        let started = events.compactMap { event -> Transaction? in
            if case .started(let transaction) = event, transaction.request.method == "GET" {
                return transaction
            }
            return nil
        }
        let request = try #require(started.first, "không thấy request GET đã giải mã")
        #expect(request.scheme == .https)
        #expect(request.host == "localhost")
        #expect(request.request.url.path == "/secret")
        #expect(request.request.queryItems.first?.value == "abc")

        guard case .completed(_, let response, _)? = events.last else {
            Issue.record("thiếu .completed, events: \(events)"); return
        }
        #expect(response.statusCode == 200)
    }

    private func runCurl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 4: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter MITMProxyTests`
Expected: FAIL — `beginMITM` hiện phát `.failed` với "MitM chưa được hỗ trợ".

- [ ] **Step 5: Viết `MITMUpgradeHandler.swift`**

```swift
import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import CertKit
import TrafficModel

/// Đứng ở channel đã tháo HTTP stack, chờ leaf cert của host rồi lắp
/// tầng TLS server và dựng lại HTTP stack bên trên nó.
///
/// Việc lấy leaf là async (actor `LeafCertificateCache`) nên byte client gửi
/// tới trong lúc chờ phải được đệm lại, nếu không ClientHello sẽ mất và
/// handshake treo cho tới khi timeout.
final class MITMUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let port: Int
    private let transactionID: UUID
    private let configuration: ProxyConfiguration
    private let leafCache: LeafCertificateCache
    private let sink: TrafficEventSink

    private var buffered: [ByteBuffer] = []
    private var ready = false

    init(host: String, port: Int, transactionID: UUID,
         configuration: ProxyConfiguration, leafCache: LeafCertificateCache,
         sink: @escaping TrafficEventSink) {
        self.host = host
        self.port = port
        self.transactionID = transactionID
        self.configuration = configuration
        self.leafCache = leafCache
        self.sink = sink
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let host = self.host
        let leafCache = self.leafCache

        Task { [weak self] in
            do {
                let identity = try await leafCache.identity(forHost: host)
                channel.eventLoop.execute { self?.install(identity: identity, on: channel) }
            } catch {
                channel.eventLoop.execute {
                    self?.sink(.failed(id: self?.transactionID ?? UUID(),
                                       message: "không mint được cert cho \(host): \(error)",
                                       endedAt: Date()))
                    channel.close(promise: nil)
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Chỉ đệm khi TLS chưa lắp xong; sau đó handler này đã bị gỡ.
        buffered.append(unwrapInboundIn(data))
    }

    private func install(identity: TLSIdentity, on channel: Channel) {
        guard !ready else { return }
        ready = true
        do {
            var tls = TLSConfiguration.makeServerConfiguration(
                certificateChain: identity.certificateChain.map { .certificate($0) },
                privateKey: .privateKey(identity.privateKey)
            )
            // Chỉ http/1.1: ép client xuống HTTP/1.1 thay vì phải
            // implement HTTP/2 framing.
            tls.applicationProtocols = ["http/1.1"]
            let sslContext = try NIOSSLContext(configuration: tls)

            let sync = channel.pipeline.syncOperations
            try sync.addHandler(NIOSSLServerHandler(context: sslContext), position: .before(self))
            try sync.addHandlers([
                HTTPResponseEncoder(),
                ByteToMessageHandler(HTTPRequestDecoder()),
                HTTPProxyHandler(
                    configuration: configuration,
                    sink: sink,
                    fixedTarget: .init(host: host, port: port, scheme: .https)
                ),
            ], position: .after(self))
            try sync.removeHandler(self)

            // Phát lại byte đã đệm từ đầu pipeline để chúng đi qua tầng TLS.
            let pending = buffered
            buffered = []
            for buffer in pending {
                channel.pipeline.fireChannelRead(NIOAny(buffer))
            }
        } catch {
            sink(.failed(id: transactionID,
                         message: "không lắp được tầng TLS cho \(host): \(error)",
                         endedAt: Date()))
            channel.close(promise: nil)
        }
    }
}
```

- [ ] **Step 6: Sửa `beginMITM` trong `ProxyEntryHandler`**

```swift
    func beginMITM(channel: Channel, host: String, port: Int, transactionID: UUID) {
        _ = channel.pipeline.addHandler(MITMUpgradeHandler(
            host: host, port: port, transactionID: transactionID,
            configuration: configuration, leafCache: leafCache, sink: sink
        ), position: .before(self))
        _ = channel.pipeline.removeHandler(self)
    }
```

- [ ] **Step 7: Chạy test**

Run: `swift test --filter MITMProxyTests`
Expected: PASS.

Nếu treo ở handshake: kiểm tra `HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)` trong `ProxyServer.start()` — thiếu `.forwardBytes` thì ClientHello đã nằm trong buffer của decoder sẽ bị vứt khi gỡ handler, và triệu chứng đúng là treo cho tới timeout.

- [ ] **Step 8: Chạy toàn bộ test**

Run: `swift test`
Expected: PASS tất cả.

- [ ] **Step 9: Viết test cho ba nhánh lỗi còn lại của spec §8**

`Tests/ProxyCoreTests/ProxyErrorHandlingTests.swift`:

```swift
import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import CertKit
import TrafficModel
@testable import ProxyCore

@Suite("Xử lý lỗi")
struct ProxyErrorHandlingTests {

    private func makeServer(configure: (inout ProxyConfiguration) -> Void = { _ in })
        async throws -> (ProxyServer, Int, CertificateAuthority) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrTests-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        var config = ProxyConfiguration()
        config.listenPort = 0
        config.bypassedHosts = []
        configure(&config)
        let server = ProxyServer(
            configuration: config,
            leafCache: try LeafCertificateCache(authority: authority)
        )
        return (server, try await server.start(), authority)
    }

    @Test("CONNECT tới IP trần bị từ chối bằng 502 có thông báo rõ")
    func rejectsBareIPConnect() async throws {
        let (server, port, _) = try await makeServer()
        defer { Task { try? await server.shutdown() } }

        let output = try runCurl([
            "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "-x", "http://127.0.0.1:\(port)", "https://93.184.216.34/",
        ])
        #expect(output == "502")
    }

    @Test("Origin dùng cert không tin được thì client nhận 502, không phải treo")
    func returns502WhenUpstreamCertificateUntrusted() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        // CA của origin KHÁC CA của proxy, và không nằm trong additionalTrustRoots.
        let strangerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stranger-\(UUID().uuidString)")
        let stranger = try CertificateAuthority.loadOrCreate(in: strangerDir)
        let strangerCache = try LeafCertificateCache(authority: stranger)
        let identity = try await strangerCache.identity(forHost: "localhost")

        var originTLS = TLSConfiguration.makeServerConfiguration(
            certificateChain: identity.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(identity.privateKey)
        )
        originTLS.applicationProtocols = ["http/1.1"]
        let originContext = try NIOSSLContext(configuration: originTLS)
        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: originContext))
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(EchoServerHandler()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { try? origin.close().wait() }

        let (server, proxyPort, authority) = try await makeServer()
        defer { Task { try? await server.shutdown() } }

        let caPath = try #require(
            (try? authority.certificatePEM()).map { _ in
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("ErrTests-ca-\(UUID().uuidString).pem")
            }
        )
        try authority.certificatePEM().write(to: caPath, atomically: true, encoding: .utf8)

        let output = try runCurl([
            "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "--cacert", caPath.path,
            "-x", "http://127.0.0.1:\(proxyPort)",
            "https://localhost:\(origin.localAddress!.port!)/",
        ])
        #expect(output == "502", "proxy phải báo 502 chứ không được im lặng treo")
    }

    @Test("Client từ chối cert của proxy thì transaction ghi gợi ý cert pinning")
    func hintsAtCertificatePinningWhenClientRejectsLeaf() async throws {
        let (server, port, _) = try await makeServer()
        defer { Task { try? await server.shutdown() } }

        let collected = Task {
            for await event in server.events {
                if case .failed(_, let message, _) = event { return message }
            }
            return nil as String?
        }

        // Không truyền --cacert: curl không tin CA của proxy và sẽ gửi
        // TLS alert, đúng như một app có cert pinning.
        _ = try? runCurl([
            "-sS", "-o", "/dev/null",
            "-x", "http://127.0.0.1:\(port)", "https://example.com/",
        ])

        let message = try #require(await collected.value)
        #expect(message.lowercased().contains("pinning"),
                "người dùng cần thấy gợi ý bypass list, không phải một chuỗi lỗi TLS thô")
    }

    private func runCurl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 10: Chạy test để chắc chắn cả ba đều đỏ**

Run: `swift test --filter ProxyErrorHandlingTests`
Expected: FAIL cả 3 — chưa có nhánh nào trong ba nhánh này được implement.

- [ ] **Step 11: Từ chối CONNECT tới IP trần**

Leaf cert dùng SAN `dNSName`, mà một IP trần cần SAN `iPAddress`. Mint `dNSName: "93.184.216.34"` sẽ ra cert mà không client nào chấp nhận, và triệu chứng là lỗi TLS khó đoán thay vì một thông báo đọc được.

Thêm vào `HeaderSanitizer`:

```swift
    /// Host là IP literal (v4 hoặc v6) chứ không phải tên miền.
    public static func isIPLiteral(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        var v6 = in6_addr()
        return trimmed.withCString {
            inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1
        }
    }
```

Rồi ở đầu `ProxyEntryHandler.establishTunnel`, trước khi phát `.started`:

```swift
        if !configuration.isBypassed(host: host), HeaderSanitizer.isIPLiteral(host) {
            respond(context: context, status: .badGateway,
                    message: "MVP chưa MitM được CONNECT tới IP trần (\(host)). "
                           + "Dùng tên miền, hoặc thêm host này vào bypass list.")
            return
        }
```

- [ ] **Step 12: Trả 502 khi upstream hỏng thay vì im lặng**

`bootstrap.connect` hoàn tất ngay khi TCP nối được — handshake TLS xảy ra **sau** đó. Nên lỗi verify cert upstream không rơi vào nhánh `.failure` của `connectUpstream`, mà tới `errorCaught` của `UpstreamHandler`. Hiện chỗ đó chỉ ghi event, client không nhận được gì và sẽ treo tới timeout.

Sửa `UpstreamHandler.errorCaught`:

```swift
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(reason: "lỗi upstream: \(error)")
        sendBadGateway(reason: "\(error)")
        context.close(promise: nil)
    }

    private func sendBadGateway(reason: String) {
        let message = "502 Bad Gateway — upstream lỗi: \(reason)"
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        clientChannel.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(
            version: .http1_1, status: .badGateway, headers: headers
        ))), promise: nil)
        var buffer = clientChannel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            self.clientChannel.close(promise: nil)
        }
    }
```

- [ ] **Step 13: Ghi gợi ý cert pinning khi client từ chối leaf của ta**

Thêm vào cuối `MITMUpgradeHandler.swift`:

```swift
/// Bắt lỗi handshake ở phía CLIENT. Đây là lỗi gặp nhiều nhất khi bắt app
/// thật, và một chuỗi NIOSSLError thô không nói cho người dùng biết phải
/// làm gì — gợi ý bypass list mới là thứ họ cần.
final class ClientTLSErrorHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let transactionID: UUID
    private let sink: TrafficEventSink
    private var reported = false

    init(host: String, transactionID: UUID, sink: @escaping TrafficEventSink) {
        self.host = host
        self.transactionID = transactionID
        self.sink = sink
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !reported else { return }
        reported = true
        sink(.failed(id: transactionID, message: Self.describe(error, host: host),
                     endedAt: Date()))
        context.close(promise: nil)
    }

    static func describe(_ error: Error, host: String) -> String {
        if error is NIOSSLError {
            return "client từ chối certificate của proxy cho \(host) — "
                 + "nghi cert pinning, cân nhắc thêm host này vào bypass list "
                 + "(\(error))"
        }
        return "lỗi TLS phía client cho \(host): \(error)"
    }
}
```

Và lắp nó ngay sau `NIOSSLServerHandler` trong `MITMUpgradeHandler.install`:

```swift
            try sync.addHandler(NIOSSLServerHandler(context: sslContext), position: .before(self))
            try sync.addHandler(
                ClientTLSErrorHandler(host: host, transactionID: transactionID, sink: sink),
                position: .before(self)
            )
```

- [ ] **Step 14: Chạy test**

Run: `swift test --filter ProxyErrorHandlingTests`
Expected: PASS cả 3.

- [ ] **Step 15: Chạy toàn bộ test**

Run: `swift test`
Expected: PASS tất cả.

- [ ] **Step 16: Commit**

```bash
git add Sources/ProxyCore Tests/ProxyCoreTests
git commit -m "feat: MitM HTTPS — mint leaf theo host, giải mã, forward, ghi transaction

Kèm ba nhánh lỗi của spec §8: từ chối CONNECT tới IP trần, trả 502 khi
upstream hỏng, và gợi ý cert pinning khi client từ chối leaf."
```

---

### Task 9: `CertKit` — cài Root CA vào system trust store

**Files:**
- Create: `Sources/CertKit/TrustStoreInstaller.swift`
- Test: `Tests/CertKitTests/TrustStoreInstallerTests.swift`

**Interfaces:**
- Consumes: `CertificateAuthority.certificatePEM()` (Task 3).
- Produces:
  - `protocol TrustStoreInstaller: Sendable` với `func isInstalled(commonName: String) async throws -> Bool`, `func install(pemPath: URL) async throws`
  - `struct SecurityCommandInstaller: TrustStoreInstaller` với `init(runner:)`
  - `typealias CommandRunner = @Sendable ([String]) async throws -> String`

Test không được gọi thật `security` (đòi mật khẩu admin và sửa keychain của máy), nên `SecurityCommandInstaller` nhận `runner` tiêm vào và test kiểm **câu lệnh được dựng ra**, không kiểm side effect.

- [ ] **Step 1: Viết test**

`Tests/CertKitTests/TrustStoreInstallerTests.swift`:

```swift
import Testing
import Foundation
@testable import CertKit

@Suite("TrustStoreInstaller")
struct TrustStoreInstallerTests {

    @Test("install dựng đúng lệnh add-trusted-cert vào System keychain")
    func buildsCorrectInstallCommand() async throws {
        let captured = CommandCapture()
        let installer = SecurityCommandInstaller(runner: captured.run)
        try await installer.install(pemPath: URL(fileURLWithPath: "/tmp/ca.pem"))

        let arguments = await captured.arguments
        #expect(arguments.contains("add-trusted-cert"))
        #expect(arguments.contains("trustRoot"))
        #expect(arguments.contains("/Library/Keychains/System.keychain"))
        #expect(arguments.contains("/tmp/ca.pem"))
    }

    @Test("isInstalled true khi security tìm thấy common name")
    func detectsInstalledCertificate() async throws {
        let installer = SecurityCommandInstaller(
            runner: { _ in "1 certificates found\n    \"alis\"<blob>=\"ProxyManClone Root CA\"" }
        )
        #expect(try await installer.isInstalled(commonName: "ProxyManClone Root CA"))
    }

    @Test("isInstalled false khi không tìm thấy")
    func detectsMissingCertificate() async throws {
        let installer = SecurityCommandInstaller(runner: { _ in "" })
        #expect(try await installer.isInstalled(commonName: "ProxyManClone Root CA") == false)
    }
}

/// Bắt lại tham số của lần gọi cuối.
actor CommandCapture {
    private(set) var arguments: [String] = []
    func run(_ arguments: [String]) async throws -> String {
        self.arguments = arguments
        return ""
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter TrustStoreInstallerTests`
Expected: FAIL, "cannot find 'SecurityCommandInstaller' in scope".

- [ ] **Step 3: Viết implementation**

```swift
import Foundation

public typealias CommandRunner = @Sendable ([String]) async throws -> String

public protocol TrustStoreInstaller: Sendable {
    func isInstalled(commonName: String) async throws -> Bool
    func install(pemPath: URL) async throws
}

public enum TrustStoreError: Error, Sendable {
    case commandFailed(status: Int32, output: String)
}

/// Cài CA qua lệnh `security`. Bước ghi vào System keychain cần quyền admin
/// nên chạy qua osascript, macOS sẽ hiện hộp thoại xin mật khẩu.
///
/// Toàn bộ phần cần quyền admin nằm sau protocol này: khi chốt hướng
/// ký/phân phối (privileged helper, SMAppService...), chỉ cần thêm impl mới
/// mà không đụng tới engine.
public struct SecurityCommandInstaller: TrustStoreInstaller {
    private let runner: CommandRunner

    public init(runner: @escaping CommandRunner = SecurityCommandInstaller.runProcess) {
        self.runner = runner
    }

    public func isInstalled(commonName: String) async throws -> Bool {
        let output = try await runner([
            "/usr/bin/security", "find-certificate", "-c", commonName,
            "/Library/Keychains/System.keychain",
        ])
        return output.contains(commonName)
    }

    public func install(pemPath: URL) async throws {
        let command = [
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", pemPath.path,
        ]
        _ = try await runner(command)
    }

    /// Chạy lệnh với quyền administrator. `security add-trusted-cert` vào
    /// System keychain bắt buộc phải có quyền này.
    public static let runProcess: CommandRunner = { arguments in
        let shellCommand = arguments
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let script = "do shell script \"\(shellCommand.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TrustStoreError.commandFailed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
```

- [ ] **Step 4: Chạy test**

Run: `swift test --filter TrustStoreInstallerTests`
Expected: PASS cả 3 test.

- [ ] **Step 5: Commit**

```bash
git add Sources/CertKit Tests/CertKitTests
git commit -m "feat: cài Root CA vào System keychain qua security, cô lập sau protocol"
```

---

### Task 10: App — `TrafficStore` với ring buffer và coalescing

Toàn bộ logic quyết định performance của UI nằm ở đây và test được mà không cần dựng view.

**Files:**
- Create: `Sources/ProxyManCloneApp/TrafficStore.swift`
- Modify: `Package.swift` (thêm test target `AppTests`)
- Test: `Tests/AppTests/TrafficStoreTests.swift`

**Interfaces:**
- Consumes: `Transaction`, `TrafficEvent`, `BodyPayload` (Task 2).
- Produces:
  - `@MainActor @Observable final class TrafficStore` với `init(capacity:)`, `var searchText: String`, `var methodFilter: String?`, `private(set) var transactions: [Transaction]`, `var filtered: [Transaction]`, `func enqueue(_:)`, `func flushNow()`, `func consume(_ events: AsyncStream<TrafficEvent>) -> Task<Void, Never>`, `func clear()`
  - Task 11 và 12 bind vào nó.

- [ ] **Step 1: Thêm test target vào `Package.swift`**

Trong mảng `targets`, thêm:

```swift
        .testTarget(name: "AppTests", dependencies: ["ProxyManCloneApp", "TrafficModel"]),
```

Executable target không import được từ test target trên mọi cấu hình, nên đổi `ProxyManCloneApp` thành hai target: một library `AppCore` chứa logic, một executable mỏng chứa `@main`.

Thay hai dòng target cũ bằng:

```swift
        .target(name: "AppCore", dependencies: ["TrafficModel", "CertKit", "ProxyCore"]),
        .executableTarget(name: "ProxyManCloneApp", dependencies: ["AppCore"]),
```

và sửa test target thành:

```swift
        .testTarget(name: "AppTests", dependencies: ["AppCore", "TrafficModel"]),
```

Di chuyển `Sources/ProxyManCloneApp/App.swift` sang `Sources/AppCore/` sau, chỉ giữ lại `@main` trong executable — làm ở Task 11. Bây giờ tạo `Sources/AppCore/` với `TrafficStore.swift`.

- [ ] **Step 2: Viết test**

`Tests/AppTests/TrafficStoreTests.swift`:

```swift
import Testing
import Foundation
import TrafficModel
@testable import AppCore

@MainActor
@Suite("TrafficStore")
struct TrafficStoreTests {

    private func makeTransaction(method: String = "GET",
                                 urlString: String = "https://example.com/a") -> Transaction {
        Transaction(
            scheme: .https, host: "example.com", port: 443,
            request: RequestModel(method: method, url: URL(string: urlString)!)
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
}
```

- [ ] **Step 3: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter TrafficStoreTests`
Expected: FAIL, "cannot find 'TrafficStore' in scope".

- [ ] **Step 4: Viết implementation**

`Sources/AppCore/TrafficStore.swift`:

```swift
import Foundation
import Observation
import TrafficModel

@MainActor
@Observable
public final class TrafficStore {
    public private(set) var transactions: [Transaction] = []
    public var searchText: String = ""
    public var methodFilter: String?

    private var index: [UUID: Int] = [:]
    private var pending: [TrafficEvent] = []
    private let capacity: Int

    public init(capacity: Int = 5000) {
        self.capacity = capacity
    }

    public var filtered: [Transaction] {
        guard !searchText.isEmpty || methodFilter != nil else { return transactions }
        let needle = searchText.lowercased()
        return transactions.filter { transaction in
            if let methodFilter, transaction.request.method != methodFilter { return false }
            guard !needle.isEmpty else { return true }
            return transaction.request.url.absoluteString.lowercased().contains(needle)
        }
    }

    /// Gom event vào hàng chờ. KHÔNG chạm mảng observable — đó là điểm mấu chốt:
    /// một trang web nặng đẩy vài trăm event mỗi giây, và cập nhật mảng theo
    /// từng event làm UI đứng hình bất kể dùng Table hay NSTableView.
    public func enqueue(_ event: TrafficEvent) {
        pending.append(event)
    }

    public func flushNow() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        for event in batch { apply(event) }
        evictIfNeeded()
    }

    /// Tiêu thụ stream của engine, flush mỗi 100 ms.
    public func consume(_ events: AsyncStream<TrafficEvent>) -> Task<Void, Never> {
        Task { @MainActor in
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self.flushNow()
                }
            }
            defer { ticker.cancel() }
            for await event in events { self.enqueue(event) }
            self.flushNow()
        }
    }

    public func clear() {
        for transaction in transactions { deleteSpilledBodies(of: transaction) }
        transactions = []
        index = [:]
        pending = []
    }

    private func apply(_ event: TrafficEvent) {
        switch event {
        case .started(let transaction):
            index[transaction.id] = transactions.count
            transactions.append(transaction)

        case .responseHead(let id, let response):
            guard let position = index[id] else { return }
            transactions[position].response = response

        case .completed(let id, let response, let endedAt):
            guard let position = index[id] else { return }
            transactions[position].response = response
            transactions[position].endedAt = endedAt
            transactions[position].state = .completed

        case .failed(let id, let message, let endedAt):
            guard let position = index[id] else { return }
            transactions[position].endedAt = endedAt
            transactions[position].state = .failed(reason: message)
        }
    }

    private func evictIfNeeded() {
        guard transactions.count > capacity else { return }
        // Cắt theo lô 10% thay vì từng cái một: reindex là O(n), làm mỗi
        // transaction mới sẽ đốt CPU vô ích ở trạng thái đầy.
        let overflow = transactions.count - capacity
        let dropCount = min(transactions.count, max(overflow, capacity / 10))

        for transaction in transactions.prefix(dropCount) {
            deleteSpilledBodies(of: transaction)
        }
        transactions.removeFirst(dropCount)

        index.removeAll(keepingCapacity: true)
        for (position, transaction) in transactions.enumerated() {
            index[transaction.id] = position
        }
    }

    private func deleteSpilledBodies(of transaction: Transaction) {
        for payload in [transaction.request.body, transaction.response?.body] {
            if case .file(let url, _) = payload {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
```

- [ ] **Step 5: Chạy test**

Run: `swift test --filter TrafficStoreTests`
Expected: PASS cả 8 test.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AppCore Tests/AppTests
git commit -m "feat: TrafficStore với ring buffer, coalescing 100ms và filter"
```

---

### Task 11: App — vỏ SwiftUI và bảng transaction

**Files:**
- Create: `Sources/AppCore/AppModel.swift`
- Create: `Sources/AppCore/ContentView.swift`
- Modify: `Sources/ProxyManCloneApp/App.swift`

**Interfaces:**
- Consumes: `TrafficStore` (Task 10); `ProxyServer`, `ProxyConfiguration` (Task 6); `CertificateAuthority`, `LeafCertificateCache`, `SecurityCommandInstaller` (Task 3, 4, 9).
- Produces: `@MainActor @Observable final class AppModel` với `let store: TrafficStore`, `var isRunning: Bool`, `var statusMessage: String`, `func start() async`, `func stop() async`, `func installCertificate() async`; `struct ContentView: View`.

- [ ] **Step 1: Viết `AppModel.swift`**

```swift
import Foundation
import Observation
import CertKit
import ProxyCore
import TrafficModel

@MainActor
@Observable
public final class AppModel {
    public let store = TrafficStore()
    public private(set) var isRunning = false
    public private(set) var statusMessage = "Chưa chạy"
    public var selection: Transaction.ID?

    private var server: ProxyServer?
    private var consumeTask: Task<Void, Never>?
    private let configuration: ProxyConfiguration
    private let installer: any TrustStoreInstaller

    public init(configuration: ProxyConfiguration = ProxyConfiguration(),
                installer: any TrustStoreInstaller = SecurityCommandInstaller()) {
        self.configuration = configuration
        self.installer = installer
    }

    public func start() async {
        guard !isRunning else { return }
        do {
            let authority = try CertificateAuthority.loadOrCreate(
                in: CertificateAuthority.defaultDirectory
            )
            let cache = try LeafCertificateCache(authority: authority)
            let server = ProxyServer(configuration: configuration, leafCache: cache)
            let port = try await server.start()
            consumeTask = store.consume(server.events)
            self.server = server
            isRunning = true
            statusMessage = "Đang nghe ở 127.0.0.1:\(port)"
        } catch {
            statusMessage = "Không khởi động được: \(error)"
        }
    }

    public func stop() async {
        guard let server else { return }
        consumeTask?.cancel()
        consumeTask = nil
        try? await server.shutdown()
        self.server = nil
        isRunning = false
        statusMessage = "Đã dừng"
    }

    public func installCertificate() async {
        do {
            let authority = try CertificateAuthority.loadOrCreate(
                in: CertificateAuthority.defaultDirectory
            )
            let pemPath = CertificateAuthority.defaultDirectory.appendingPathComponent("ca.pem")
            _ = try authority.certificatePEM()
            try await installer.install(pemPath: pemPath)
            statusMessage = "Đã cài Root CA vào System keychain"
        } catch {
            statusMessage = "Cài CA thất bại: \(error)"
        }
    }
}
```

- [ ] **Step 2: Viết `ContentView.swift`**

```swift
import SwiftUI
import TrafficModel

public struct ContentView: View {
    @State private var model = AppModel()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            transactionTable
                .navigationSplitViewColumnWidth(min: 520, ideal: 720)
        } detail: {
            if let id = model.selection,
               let transaction = model.store.transactions.first(where: { $0.id == id }) {
                InspectorView(transaction: transaction)
            } else {
                ContentUnavailableView("Chọn một request",
                                       systemImage: "arrow.left.arrow.right")
            }
        }
        .toolbar { toolbarContent }
        .searchable(text: $model.store.searchText, prompt: "Lọc theo URL")
    }

    private var transactionTable: some View {
        Table(model.store.filtered, selection: $model.selection) {
            TableColumn("Method") { Text($0.request.method).monospaced() }
                .width(min: 60, ideal: 70)
            TableColumn("Status") { StatusCell(transaction: $0) }
                .width(min: 60, ideal: 70)
            TableColumn("Host") { Text($0.host) }
                .width(min: 120, ideal: 200)
            TableColumn("Path") { Text($0.request.url.path) }
                .width(min: 120, ideal: 260)
            TableColumn("Duration") { transaction in
                Text(transaction.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Size") { transaction in
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(transaction.response?.body.totalBytes ?? 0),
                    countStyle: .file
                ))
            }
            .width(min: 70, ideal: 80)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(model.isRunning ? "Dừng" : "Chạy") {
                Task { model.isRunning ? await model.stop() : await model.start() }
            }
        }
        ToolbarItem {
            Button("Cài Root CA") { Task { await model.installCertificate() } }
        }
        ToolbarItem {
            Picker("Method", selection: $model.store.methodFilter) {
                Text("Tất cả").tag(String?.none)
                ForEach(["GET", "POST", "PUT", "DELETE", "CONNECT"], id: \.self) {
                    Text($0).tag(String?.some($0))
                }
            }
        }
        ToolbarItem { Button("Xoá hết") { model.store.clear() } }
        ToolbarItem(placement: .status) {
            Text(model.statusMessage).foregroundStyle(.secondary)
        }
    }
}

/// Status code kèm màu, và nêu rõ lý do khi hỏng — cert pinning là
/// nguyên nhân phổ biến nhất và người dùng cần thấy gợi ý đó.
struct StatusCell: View {
    let transaction: Transaction

    var body: some View {
        switch transaction.state {
        case .pending:
            ProgressView().controlSize(.small)
        case .tunnelled:
            Text("tunnel").foregroundStyle(.secondary)
                .help("Host nằm trong bypass list, không giải mã")
        case .failed(let reason):
            Text("lỗi").foregroundStyle(.red).help(reason)
        case .completed:
            let code = transaction.response?.statusCode ?? 0
            Text("\(code)").foregroundStyle(code >= 400 ? .red : .primary)
        }
    }
}
```

- [ ] **Step 3: Rút gọn `Sources/ProxyManCloneApp/App.swift` còn phần `@main`**

```swift
import SwiftUI
import AppCore

@main
struct ProxyManCloneApp: App {
    init() {
        // Chạy bằng `swift run` thì binary không nằm trong .app bundle,
        // nên phải tự đặt activation policy để cửa sổ nhận được focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("ProxyManClone") {
            ContentView().frame(minWidth: 1000, minHeight: 640)
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: PASS. `InspectorView` chưa có nên sẽ lỗi — tạm thay bằng `Text(transaction.request.url.absoluteString)` để build xanh, Task 12 thay lại.

- [ ] **Step 5: Chạy toàn bộ test**

Run: `swift test`
Expected: PASS tất cả.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "feat: vỏ SwiftUI với bảng transaction, toolbar chạy/dừng và cài CA"
```

---

### Task 12: App — inspector chi tiết Request/Response

**Files:**
- Create: `Sources/AppCore/InspectorView.swift`
- Create: `Sources/AppCore/JSONNode.swift`
- Modify: `Sources/AppCore/ContentView.swift` (bỏ chỗ tạm ở Task 11)
- Test: `Tests/AppTests/JSONNodeTests.swift`

**Interfaces:**
- Consumes: `Transaction`, `BodyPayload` (Task 2).
- Produces: `struct JSONNode: Identifiable` với `static func parse(_ data: Data) -> JSONNode?`; `struct InspectorView: View`.

- [ ] **Step 1: Viết test cho `JSONNode`**

`Tests/AppTests/JSONNodeTests.swift`:

```swift
import Testing
import Foundation
@testable import AppCore

@Suite("JSONNode")
struct JSONNodeTests {

    @Test("Object thành node có con, sắp theo key")
    func parsesObject() throws {
        let data = Data(#"{"b": 2, "a": 1}"#.utf8)
        let root = try #require(JSONNode.parse(data))
        #expect(root.children?.map(\.key) == ["a", "b"])
    }

    @Test("Array đánh index làm key")
    func parsesArray() throws {
        let data = Data(#"[10, 20]"#.utf8)
        let root = try #require(JSONNode.parse(data))
        #expect(root.children?.map(\.key) == ["[0]", "[1]"])
        #expect(root.children?.first?.value == "10")
    }

    @Test("Lồng nhau giữ đúng cấu trúc cây")
    func parsesNested() throws {
        let data = Data(#"{"user": {"name": "Phuoc"}}"#.utf8)
        let root = try #require(JSONNode.parse(data))
        let user = try #require(root.children?.first)
        #expect(user.key == "user")
        #expect(user.children?.first?.value == "Phuoc")
    }

    @Test("Không phải JSON thì trả nil để view rơi về plain text")
    func returnsNilForNonJSON() {
        #expect(JSONNode.parse(Data("khong phai json".utf8)) == nil)
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó đỏ**

Run: `swift test --filter JSONNodeTests`
Expected: FAIL, "cannot find 'JSONNode' in scope".

- [ ] **Step 3: Viết `JSONNode.swift`**

```swift
import Foundation

/// Một nút trong cây JSON để `OutlineGroup` render.
public struct JSONNode: Identifiable, Sendable {
    public let id = UUID()
    public let key: String
    public let value: String
    public let children: [JSONNode]?

    public static func parse(_ data: Data) -> JSONNode? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) else { return nil }
        return node(key: "root", from: object)
    }

    private static func node(key: String, from object: Any) -> JSONNode {
        switch object {
        case let dictionary as [String: Any]:
            let children = dictionary.keys.sorted().map {
                node(key: $0, from: dictionary[$0]!)
            }
            return JSONNode(key: key, value: "{\(children.count)}", children: children)

        case let array as [Any]:
            let children = array.enumerated().map { node(key: "[\($0.offset)]", from: $0.element) }
            return JSONNode(key: key, value: "[\(children.count)]", children: children)

        case is NSNull:
            return JSONNode(key: key, value: "null", children: nil)

        default:
            return JSONNode(key: key, value: String(describing: object), children: nil)
        }
    }
}
```

- [ ] **Step 4: Chạy test**

Run: `swift test --filter JSONNodeTests`
Expected: PASS cả 4 test.

- [ ] **Step 5: Viết `InspectorView.swift`**

```swift
import SwiftUI
import TrafficModel

public struct InspectorView: View {
    let transaction: Transaction

    public init(transaction: Transaction) {
        self.transaction = transaction
    }

    public var body: some View {
        TabView {
            requestTab.tabItem { Text("Request") }
            responseTab.tabItem { Text("Response") }
        }
        .padding()
    }

    private var requestTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("URL", value: transaction.request.url.absoluteString)
                LabeledContent("Method", value: transaction.request.method)
                LabeledContent("HTTP", value: transaction.request.httpVersion)

                if !transaction.request.queryItems.isEmpty {
                    Section("Query Parameters") {
                        KeyValueTable(pairs: transaction.request.queryItems.map {
                            (name: $0.name, value: $0.value ?? "")
                        })
                    }
                }
                Section("Headers") { KeyValueTable(pairs: transaction.request.headers) }
                Section("Body") { BodyView(payload: transaction.request.body) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var responseTab: some View {
        if let response = transaction.response {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Status", value: "\(response.statusCode) \(response.reasonPhrase)")
                    Section("Headers") { KeyValueTable(pairs: response.headers) }
                    Section("Body") { BodyView(payload: response.body) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if case .failed(let reason) = transaction.state {
            ContentUnavailableView("Request thất bại", systemImage: "xmark.octagon",
                                   description: Text(reason))
        } else if case .tunnelled = transaction.state {
            ContentUnavailableView(
                "Không giải mã", systemImage: "lock",
                description: Text("\(transaction.host) nằm trong bypass list nên chỉ được tunnel byte thô.")
            )
        } else {
            ProgressView("Đang chờ response")
        }
    }
}

struct KeyValueTable: View {
    let pairs: [(name: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top) {
                    Text(pair.name).bold().frame(width: 200, alignment: .leading)
                    Text(pair.value).textSelection(.enabled)
                }
                .font(.system(.body, design: .monospaced))
            }
        }
    }
}

struct BodyView: View {
    let payload: BodyPayload

    var body: some View {
        switch payload {
        case .none:
            Text("Không có body").foregroundStyle(.secondary)

        case .file(let url, let total):
            // Body lớn đã spill ra đĩa; nạp lại toàn bộ vào view sẽ dựng lại
            // đúng vấn đề RAM mà việc spill sinh ra để tránh.
            VStack(alignment: .leading) {
                Text("Body \(total) byte đã lưu ra đĩa").foregroundStyle(.secondary)
                Text(url.path).font(.caption).textSelection(.enabled)
            }

        case .truncated(let data, let total):
            VStack(alignment: .leading) {
                Text("Chỉ giữ \(data.count)/\(total) byte — ghi đĩa thất bại")
                    .foregroundStyle(.orange)
                content(for: data)
            }

        case .inMemory(let data):
            content(for: data)
        }
    }

    @ViewBuilder
    private func content(for data: Data) -> some View {
        if let root = JSONNode.parse(data), root.children != nil {
            OutlineGroup(root.children ?? [], children: \.children) { node in
                HStack {
                    Text(node.key).bold()
                    Text(node.value).foregroundStyle(.secondary)
                }
                .font(.system(.body, design: .monospaced))
            }
        } else {
            Text(String(data: data, encoding: .utf8) ?? "\(data.count) byte nhị phân")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
```

- [ ] **Step 6: Bỏ chỗ tạm trong `ContentView`**

Đổi lại nhánh detail thành `InspectorView(transaction: transaction)` như đã viết ở Task 11 Step 2.

- [ ] **Step 7: Build và chạy toàn bộ test**

Run: `swift build && swift test`
Expected: PASS tất cả.

- [ ] **Step 8: Kiểm chứng thủ công toàn tuyến**

Đây là lần đầu mọi mảnh ghép chạy cùng nhau, và không có test tự động nào phủ được nó:

```bash
swift run ProxyManCloneApp
```

1. Bấm **Cài Root CA**, nhập mật khẩu admin. Status phải báo cài xong.
2. Bấm **Chạy**. Status phải báo `Đang nghe ở 127.0.0.1:9090`.
3. Trong terminal khác:
   `curl -sS -x 127.0.0.1:9090 http://example.com/ -o /dev/null -w '%{http_code}\n'` → `200`, và một dòng HTTP hiện trong bảng.
4. `curl -sS -x 127.0.0.1:9090 https://example.com/ -o /dev/null -w '%{http_code}\n'` → `200`, và một dòng HTTPS hiện ra **đã giải mã** (thấy được path và headers).
5. Bấm vào dòng đó, kiểm tab Request/Response hiện headers và body.
6. Gõ vào ô search, kiểm bảng lọc đúng.

Bước 4 cũng chính là bài kiểm tra cho verify upstream bằng system trust store — nếu nó ra 502 thì `TLSConfiguration.makeClientConfiguration()` không đọc được system roots trên máy này, và phải nạp roots tường minh.

- [ ] **Step 9: Commit**

```bash
git add Sources Tests
git commit -m "feat: inspector Request/Response với cây JSON, headers và query params"
```

---

## Ghi chú sau khi xong MVP

Theo mục 12 của spec, mỗi mục dưới đây là một chu kỳ spec → plan riêng, không nhét vào plan này:

1. WebSocket (chuyển pipeline sang frame codec khi upstream trả `101`).
2. Breakpoint / sửa request trước khi forward.
3. HTTP/2 (bỏ giới hạn ALPN `http/1.1`).
4. Lưu trữ SQLite, save/load session.
5. Tự động cấu hình system proxy (`networksetup` / SCPreferences).

Hai chỗ đã biết là nợ kỹ thuật, ghi lại để không quên:

- **Back-pressure.** MVP để `autoRead` mặc định. Tải một file rất lớn qua proxy sẽ đệm nhanh hơn mức ghi ra được. `BodyCollector` chặn được phần phình RAM, nhưng chưa có back-pressure thật ở tầng channel.
- **Connection pool.** Mỗi client connection giữ một upstream channel. Client mở nhiều connection tới cùng host sẽ tạo nhiều upstream trùng nhau. Đúng nhưng chưa tối ưu — và pool là nguồn bug lớn nhất trong proxy nên MVP cố ý không làm.
