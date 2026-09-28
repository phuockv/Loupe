# Tự động đặt/gỡ proxy hệ thống — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bấm Chạy là app tự đặt proxy hệ thống lên mọi dịch vụ mạng đang hoạt động; bấm Dừng, tắt toggle, thoát app, hoặc mở lại sau khi crash là tự trả về đúng trạng thái cũ.

**Architecture:** Target mới `SystemProxy` gọi `/usr/sbin/networksetup` qua một `CommandRunner` tiêm được — cùng khuôn `TrustStoreInstaller` của `CertKit`, nên test chạy bằng runner giả và không đụng máy thật. Một `SystemProxyController` (actor) điều phối nhiều dịch vụ và quản file snapshot JSON; file luôn được ghi và `fsync` **trước** khi đổi bất cứ cài đặt nào, nên crash giữa chừng vẫn còn đường về.

**Tech Stack:** Swift 6 strict concurrency, Foundation, `Testing` framework, SwiftUI (`NSApplicationDelegateAdaptor`), `DispatchSource` signal source.

**Spec:** [`docs/superpowers/specs/2026-09-28-system-proxy-automation-design.md`](../specs/2026-09-28-system-proxy-automation-design.md)

## Global Constraints

- Chỉ quản HTTP (`-getwebproxy`/`-setwebproxy`) và HTTPS (`-getsecurewebproxy`/`-setsecurewebproxy`). Không đụng SOCKS, FTP, Gopher, PAC URL, bypass domains.
- Binary luôn gọi bằng đường dẫn tuyệt đối `/usr/sbin/networksetup`. Không bao giờ qua shell — đối số truyền thẳng vào `Process.arguments`.
- "Loopback" nhận đúng ba chuỗi, không phân biệt hoa thường: `127.0.0.1`, `::1`, `localhost`. Không nhận cả dải `127.0.0.0/8`.
- Mọi kiểu công khai phải `Sendable`. Target build sạch dưới strict concurrency của Swift 6.
- File snapshot: `~/Library/Application Support/Loupe/system-proxy-snapshot.json`.
- Text hiển thị cho người dùng viết bằng tiếng Việt, khớp giọng văn các chuỗi sẵn có trong `AppModel`.
- Toggle mới **không** lưu qua các lần mở app — mặc định BẬT, giống `allowLANDevices` và `forceDecompressible`.

## Review Focus

Năm lớp đầu vào mà spec ngụ ý nhưng dễ rơi khỏi test. Mỗi dòng đã được gắn một test vào task sở hữu đoạn code đó.

1. **Bật hai lần liên tiếp không Dừng ở giữa.** Lần chụp thứ hai sẽ chụp nhằm trạng thái *đã bị ta đổi*. Luật chuẩn hoá §2.3 biến nó thành "tắt", nên nếu trạng thái gốc là proxy công ty thì đường về bị xoá vĩnh viễn. Kỳ vọng: `enable` thấy snapshot đã tồn tại thì **không chụp đè**. → Task 5.
2. **Không có dịch vụ nào đang hoạt động.** `enable` không được ghi snapshot rỗng rồi báo thành công như thể đã đặt xong. → Task 5.
3. **Khôi phục về trạng thái "tắt".** Trạng thái gốc tắt thì `server` rỗng và `port` là 0; gọi `-setwebproxy Wi-Fi "" 0` là lệnh không hợp lệ. Phải dùng `-setwebproxystate <svc> off`. → Task 3.
4. **Tên dịch vụ có dấu cách** (`Thunderbolt Bridge`) và có dấu chấm/gạch (`phuoc.kieu-c-sg`). Parse danh sách phải giữ nguyên tên, không cắt ở dấu cách. → Task 3.
5. **Cổng đổi giữa lúc bật và lúc gỡ.** Cấu hình dùng cổng 0 thì cổng thật do kernel cấp và khác nhau mỗi lần. Việc nhận diện "dấu vết của chính ta" phải đọc `appliedPort` trong snapshot, không đọc cổng hiện tại của server. → Task 6.

---

## File Structure

**Tạo mới:**

| File | Trách nhiệm |
| --- | --- |
| `Sources/SystemProxy/ProxyModels.swift` | `ProxySetting`, `ServiceProxySnapshot`, `ProxySnapshot`, luật loopback và chuẩn hoá. Logic thuần, không I/O. |
| `Sources/SystemProxy/SystemProxyConfiguring.swift` | `CommandRunner`, `SystemProxyError`, protocol `SystemProxyConfiguring`. |
| `Sources/SystemProxy/NetworkSetupConfigurer.swift` | Hiện thực protocol bằng `networksetup`: dựng lệnh và parse output. |
| `Sources/SystemProxy/ProxySnapshotStore.swift` | Đọc/ghi/xoá file JSON, có `fsync`. |
| `Sources/SystemProxy/SystemProxyController.swift` | Actor điều phối: `enable`, `disable`, `recoverIfNeeded`. |
| `Sources/SystemProxy/SyncProxyRestore.swift` | Đường khôi phục **đồng bộ** cho lúc thoát app và cho signal handler. |
| `Tests/SystemProxyTests/ProxyModelsTests.swift` | Luật loopback, chuẩn hoá, `Codable` round-trip. |
| `Tests/SystemProxyTests/NetworkSetupConfigurerTests.swift` | Parse output, dựng lệnh. |
| `Tests/SystemProxyTests/ProxySnapshotStoreTests.swift` | Ghi/đọc/xoá, file hỏng. |
| `Tests/SystemProxyTests/SystemProxyControllerTests.swift` | Thứ tự ghi file, rollback, khôi phục có điều kiện. |

**Sửa:**

| File | Sửa gì |
| --- | --- |
| `Package.swift` | Thêm target `SystemProxy` + test target; `AppCore` phụ thuộc `SystemProxy`. |
| `Sources/AppCore/AppModel.swift` | Thêm `setSystemProxy` toggle và nối vào `start()`/`stop()`. |
| `Sources/AppCore/ContentView.swift` | Thêm toggle thứ ba vào `.safeAreaInset(edge: .bottom)`. |
| `Sources/LoupeApp/App.swift` | `NSApplicationDelegateAdaptor`: khôi phục lúc mở, gỡ lúc thoát, bắt `SIGTERM`/`SIGINT`. |

---

## Task 1: Spike M1 — `networksetup` có ghi được từ app GUI không

**Đây là cổng chặn. Không viết một dòng code sản phẩm nào trước khi task này xong.**

Spec §7.1: đây là rủi ro cùng hình dạng với sai lầm §6.3 Root CA, thứ chưa từng chạy được từ app GUI trên bất kỳ máy nào mà không review nào bắt được. Chạy ngon trong Terminal dưới tài khoản admin **không** đảm bảo chạy ngon từ trong một app bundle ad-hoc sign.

**Files:**
- Create: `/tmp/proxy-probe/main.swift` (throwaway — không commit)
- Create: `/tmp/proxy-probe/build.sh` (throwaway — không commit)

**Interfaces:**
- Consumes: không
- Produces: một câu trả lời có/không. Không có code nào của task này được giữ lại.

- [ ] **Step 1: Viết probe app**

```swift
// /tmp/proxy-probe/main.swift
import Foundation
import AppKit

func run(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "không exec được: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// Chạy trong app GUI thật: activation policy .regular, có NSApplication.
NSApplication.shared.setActivationPolicy(.regular)

var report = "=== probe chạy lúc \(Date()) ===\n"
report += "uid=\(getuid()) euid=\(geteuid())\n"

let (s1, o1) = run(["/usr/sbin/networksetup", "-setwebproxy", "Wi-Fi", "127.0.0.1", "9099"])
report += "SET  exit=\(s1) output=[\(o1.trimmingCharacters(in: .whitespacesAndNewlines))]\n"

let (s2, o2) = run(["/usr/sbin/networksetup", "-getwebproxy", "Wi-Fi"])
report += "GET  exit=\(s2) output=[\(o2.trimmingCharacters(in: .whitespacesAndNewlines))]\n"

let (s3, o3) = run(["/usr/sbin/networksetup", "-setwebproxystate", "Wi-Fi", "off"])
report += "OFF  exit=\(s3) output=[\(o3.trimmingCharacters(in: .whitespacesAndNewlines))]\n"

try? report.write(toFile: "/tmp/proxy-probe/report.txt", atomically: true, encoding: .utf8)
exit(0)
```

- [ ] **Step 2: Dựng .app bundle ad-hoc sign, y hệt cách `Scripts/make-app.sh` làm**

```bash
cd /tmp/proxy-probe
mkdir -p Probe.app/Contents/MacOS
cat > Probe.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleIdentifier</key><string>local.proxy.probe</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
swiftc -o Probe.app/Contents/MacOS/Probe main.swift -framework AppKit
codesign --force --deep --sign - Probe.app
```

- [ ] **Step 3: Ghi lại trạng thái proxy Wi-Fi TRƯỚC khi chạy probe**

```bash
networksetup -getwebproxy Wi-Fi | tee /tmp/proxy-probe/before.txt
```

- [ ] **Step 4: Chạy probe bằng `open` — phải là `open`, không phải gọi binary trực tiếp**

Gọi binary trực tiếp từ Terminal thì tiến trình thừa kế ngữ cảnh của Terminal và sẽ cho kết quả sai lệch lạc quan. `open` mới dựng đúng ngữ cảnh một app GUI do Launch Services khởi động.

```bash
open /tmp/proxy-probe/Probe.app
sleep 3
cat /tmp/proxy-probe/report.txt
```

- [ ] **Step 5: Đánh giá kết quả**

ĐẠT khi cả ba điều sau cùng đúng:
- `SET exit=0`
- `GET` in ra `Enabled: Yes`, `Server: 127.0.0.1`, `Port: 9099`
- **Không có hộp thoại mật khẩu nào hiện ra** trong lúc probe chạy

KHÔNG ĐẠT nếu `SET exit` khác 0, hoặc output chứa chữ về quyền/authorization, hoặc có hộp thoại.

- [ ] **Step 6: Trả máy về trạng thái cũ**

```bash
networksetup -setwebproxystate Wi-Fi off
networksetup -getwebproxy Wi-Fi   # đối chiếu với before.txt
rm -rf /tmp/proxy-probe
```

- [ ] **Step 7: Nếu KHÔNG ĐẠT — dừng lại**

Không đi tiếp task nào. Báo cho người dùng nguyên văn output và nói rõ: thiết kế trong spec dựa trên giả định `networksetup` ghi được từ app GUI, giả định đó vừa sai, nên cả spec phải xem lại. Đây chính xác là kết cục mà việc đặt M1 lên đầu sinh ra để bắt sớm.

Không commit gì ở task này.

---

## Task 2: Kiểu dữ liệu, luật loopback và chuẩn hoá

**Files:**
- Create: `Sources/SystemProxy/ProxyModels.swift`
- Create: `Tests/SystemProxyTests/ProxyModelsTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: không
- Produces: `ProxySetting` (`enabled: Bool`, `server: String`, `port: Int`, `.off`, `pointsAt(host:port:) -> Bool`, `normalizedAsOriginal(appliedHost:appliedPort:) -> ProxySetting`); `ServiceProxySnapshot` (`service: String`, `web: ProxySetting`, `secureWeb: ProxySetting`); `ProxySnapshot` (`takenAt: Date`, `appliedHost: String`, `appliedPort: Int`, `services: [ServiceProxySnapshot]`); `Loopback.isLoopback(_ host: String) -> Bool`.

- [ ] **Step 1: Thêm target vào `Package.swift`**

Thêm vào mảng `targets`, ngay sau `.target(name: "CertKit", ...)`:

```swift
        .target(name: "SystemProxy"),
```

Và vào cuối mảng `targets`:

```swift
        .testTarget(name: "SystemProxyTests", dependencies: ["SystemProxy"]),
```

Thêm vào mảng `products`, sau dòng `CertKit`:

```swift
        .library(name: "SystemProxy", targets: ["SystemProxy"]),
```

- [ ] **Step 2: Viết test thất bại**

```swift
// Tests/SystemProxyTests/ProxyModelsTests.swift
import Testing
import Foundation
@testable import SystemProxy

@Suite("ProxyModels")
struct ProxyModelsTests {

    @Test("Nhận đúng ba chuỗi loopback, không phân biệt hoa thường")
    func recognisesLoopbackHosts() {
        #expect(Loopback.isLoopback("127.0.0.1"))
        #expect(Loopback.isLoopback("::1"))
        #expect(Loopback.isLoopback("localhost"))
        #expect(Loopback.isLoopback("LocalHost"))
    }

    @Test("KHÔNG nhận cả dải 127.0.0.0/8 — 127.0.0.2 là thứ khác, không phải ta")
    func rejectsWiderLoopbackRange() {
        #expect(!Loopback.isLoopback("127.0.0.2"))
        #expect(!Loopback.isLoopback("127.1.1.1"))
        #expect(!Loopback.isLoopback("10.7.0.10"))
        #expect(!Loopback.isLoopback(""))
    }

    @Test("Trỏ vào chính app đúng cổng thì chuẩn hoá thành tắt")
    func normalisesOwnLeftoverToOff() {
        let leftover = ProxySetting(enabled: true, server: "127.0.0.1", port: 9090)
        let normalised = leftover.normalizedAsOriginal(appliedHost: "127.0.0.1", appliedPort: 9090)
        #expect(normalised.enabled == false)
    }

    @Test("Loopback nhưng KHÁC cổng thì giữ nguyên — Charles ở 8888 không phải dấu vết của ta")
    func keepsOtherLoopbackProxyIntact() {
        let charles = ProxySetting(enabled: true, server: "127.0.0.1", port: 8888)
        let normalised = charles.normalizedAsOriginal(appliedHost: "127.0.0.1", appliedPort: 9090)
        #expect(normalised == charles, "gỡ mất proxy của công cụ khác là một kiểu phá hoại khó lần ra")
    }

    @Test("Proxy công ty giữ nguyên tuyệt đối")
    func keepsCorporateProxyIntact() {
        let corporate = ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
        #expect(corporate.normalizedAsOriginal(appliedHost: "127.0.0.1", appliedPort: 9090) == corporate)
    }

    @Test("Đang tắt thì chuẩn hoá không đổi gì, kể cả khi server trùng ta")
    func leavesDisabledSettingAlone() {
        let disabled = ProxySetting(enabled: false, server: "127.0.0.1", port: 9090)
        #expect(disabled.normalizedAsOriginal(appliedHost: "127.0.0.1", appliedPort: 9090) == disabled)
    }

    @Test("ProxySnapshot đi qua Codable không mất dữ liệu")
    func snapshotRoundTripsThroughCodable() throws {
        let snapshot = ProxySnapshot(
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            appliedHost: "127.0.0.1",
            appliedPort: 9090,
            services: [
                ServiceProxySnapshot(
                    service: "Thunderbolt Bridge",
                    web: ProxySetting(enabled: false, server: "", port: 0),
                    secureWeb: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
                )
            ]
        )
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(ProxySnapshot.self, from: data)
        #expect(back == snapshot)
    }
}
```

- [ ] **Step 3: Chạy test để chắc chắn nó thất bại**

Run: `swift test --filter ProxyModels`
Expected: FAIL — không compile được, `cannot find 'Loopback' in scope`.

- [ ] **Step 4: Viết hiện thực tối thiểu**

```swift
// Sources/SystemProxy/ProxyModels.swift
import Foundation

/// Nhận diện host trỏ về chính máy này.
///
/// Danh sách CỐ TÌNH hẹp: đúng ba chuỗi, không nhận cả dải `127.0.0.0/8`.
/// Người cố ý đặt proxy ở `127.0.0.2` đang trỏ vào một thứ khác đang chạy
/// trên máy, không phải vào ta — và luật này được dùng để quyết định có xoá
/// một cấu hình của người dùng hay không, nên nhận rộng là hỏng theo hướng
/// tốn kém.
public enum Loopback {
    public static func isLoopback(_ host: String) -> Bool {
        switch host.lowercased() {
        case "127.0.0.1", "::1", "localhost": return true
        default: return false
        }
    }
}

/// Trạng thái proxy của MỘT giao thức (HTTP hoặc HTTPS) trên MỘT dịch vụ.
public struct ProxySetting: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var server: String
    public var port: Int

    public init(enabled: Bool, server: String, port: Int) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }

    public static let off = ProxySetting(enabled: false, server: "", port: 0)

    /// Cấu hình này có đang trỏ vào đúng `host:port` không.
    public func pointsAt(host: String, port: Int) -> Bool {
        enabled && Loopback.isLoopback(server) && Loopback.isLoopback(host) && self.port == port
    }

    /// Giá trị sẽ ghi vào snapshot làm "trạng thái nguyên bản".
    ///
    /// Thấy dấu vết của CHÍNH app (loopback + đúng cổng sắp đặt) thì ghi nhận
    /// là tắt. Không có luật này, mớ cũ còn sót trên máy sẽ bị đóng băng
    /// thành "nguyên bản" và mỗi lần Dừng lại đặt máy về đúng trạng thái mất
    /// mạng — tính năng sinh ra để sửa lỗi đó sẽ tự tái tạo nó vĩnh viễn.
    ///
    /// Điều kiện PHẢI khớp cả cổng: một Charles ở `127.0.0.1:8888` cũng là
    /// loopback nhưng không phải dấu vết của ta.
    public func normalizedAsOriginal(appliedHost: String, appliedPort: Int) -> ProxySetting {
        pointsAt(host: appliedHost, port: appliedPort) ? .off : self
    }
}

public struct ServiceProxySnapshot: Sendable, Equatable, Codable {
    public var service: String
    public var web: ProxySetting
    public var secureWeb: ProxySetting

    public init(service: String, web: ProxySetting, secureWeb: ProxySetting) {
        self.service = service
        self.web = web
        self.secureWeb = secureWeb
    }
}

public struct ProxySnapshot: Sendable, Equatable, Codable {
    public var takenAt: Date
    /// Host app đã đặt. Lưu lại để nhận ra dấu vết của chính mình về sau.
    public var appliedHost: String
    /// Cổng app đã đặt — cổng THẬT SỰ bind được, không phải cổng trong cấu
    /// hình. Hai giá trị đó khác nhau khi cấu hình dùng cổng 0.
    public var appliedPort: Int
    public var services: [ServiceProxySnapshot]

    public init(takenAt: Date, appliedHost: String, appliedPort: Int,
                services: [ServiceProxySnapshot]) {
        self.takenAt = takenAt
        self.appliedHost = appliedHost
        self.appliedPort = appliedPort
        self.services = services
    }
}
```

- [ ] **Step 5: Chạy test để xác nhận đã pass**

Run: `swift test --filter ProxyModels`
Expected: PASS, 7 test.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/SystemProxy/ProxyModels.swift Tests/SystemProxyTests/ProxyModelsTests.swift
git commit -m "feat(SystemProxy): kiểu dữ liệu và luật nhận diện dấu vết của chính app"
```

---

## Task 3: Protocol, parse output, dựng lệnh

**Files:**
- Create: `Sources/SystemProxy/SystemProxyConfiguring.swift`
- Create: `Sources/SystemProxy/NetworkSetupConfigurer.swift`
- Create: `Tests/SystemProxyTests/NetworkSetupConfigurerTests.swift`

**Interfaces:**
- Consumes: `ProxySetting`, `ServiceProxySnapshot` (Task 2)
- Produces: `CommandRunner = @Sendable ([String]) async throws -> String`; `SystemProxyError` (`.commandFailed(status:output:)`, `.unreadableOutput(command:output:)`, `.snapshotUnreadable(String)`); protocol `SystemProxyConfiguring` (`activeServices() async throws -> [String]`, `read(service:) async throws -> ServiceProxySnapshot`, `apply(host:port:to:) async throws`, `restore(_:) async throws`); `NetworkSetupConfigurer(runner:)` với `static let runProcess: CommandRunner`, và hai hàm static test được: `parseServices(_:) -> [String]`, `parseProxy(_:) throws -> ProxySetting`.

**Review Focus #3** (khôi phục về trạng thái tắt phải dùng `-setwebproxystate off`, không set server rỗng) và **#4** (tên dịch vụ có dấu cách) đều được pin bằng test trong task này.

- [ ] **Step 1: Viết test thất bại**

```swift
// Tests/SystemProxyTests/NetworkSetupConfigurerTests.swift
import Testing
import Foundation
@testable import SystemProxy

@Suite("NetworkSetupConfigurer")
struct NetworkSetupConfigurerTests {

    /// Runner giả: ghi lại mọi lệnh đã chạy, trả output đặt sẵn theo thứ tự.
    actor FakeRunner {
        private(set) var commands: [[String]] = []
        private var outputs: [String]
        private let failAt: Int?

        init(outputs: [String], failAt: Int? = nil) {
            self.outputs = outputs
            self.failAt = failAt
        }

        func run(_ args: [String]) async throws -> String {
            commands.append(args)
            if let failAt, commands.count == failAt {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi")
            }
            return outputs.isEmpty ? "" : outputs.removeFirst()
        }

        var runner: CommandRunner {
            { [self] args in try await self.run(args) }
        }
    }

    @Test("Bỏ dịch vụ bị tắt (dấu * đầu tên) và bỏ dòng tiêu đề")
    func parsesActiveServicesOnly() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        Thunderbolt Bridge
        Wi-Fi
        *Urban VPN Desktop
        phuoc.kieu-c-sg
        """
        #expect(NetworkSetupConfigurer.parseServices(output)
                == ["Thunderbolt Bridge", "Wi-Fi", "phuoc.kieu-c-sg"])
    }

    @Test("Tên có dấu cách và dấu chấm/gạch không bị cắt")
    func keepsServiceNamesWithSpacesAndPunctuation() {
        let parsed = NetworkSetupConfigurer.parseServices("Thunderbolt Bridge\nphuoc.kieu-c-sg")
        #expect(parsed.first == "Thunderbolt Bridge")
        #expect(parsed.last == "phuoc.kieu-c-sg")
    }

    @Test("Parse output getwebproxy khi đang bật")
    func parsesEnabledProxy() throws {
        let output = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 9090
        Authenticated Proxy Enabled: 0
        """
        let setting = try NetworkSetupConfigurer.parseProxy(output)
        #expect(setting == ProxySetting(enabled: true, server: "127.0.0.1", port: 9090))
    }

    @Test("Parse output getwebproxy khi đang tắt")
    func parsesDisabledProxy() throws {
        let output = "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0"
        let setting = try NetworkSetupConfigurer.parseProxy(output)
        #expect(setting.enabled == false)
        #expect(setting.port == 0)
    }

    @Test("Output không đọc được thì ném lỗi, không đoán bừa thành 'đang tắt'")
    func throwsOnUnreadableOutput() {
        #expect(throws: SystemProxyError.self) {
            try NetworkSetupConfigurer.parseProxy("** Error: dịch vụ không tồn tại")
        }
    }

    @Test("apply đặt cả HTTP lẫn HTTPS, dùng đường dẫn tuyệt đối")
    func applySetsBothProtocols() async throws {
        let fake = FakeRunner(outputs: ["", ""])
        let sut = NetworkSetupConfigurer(runner: await fake.runner)
        try await sut.apply(host: "127.0.0.1", port: 9090, to: "Wi-Fi")

        let commands = await fake.commands
        #expect(commands == [
            ["/usr/sbin/networksetup", "-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
            ["/usr/sbin/networksetup", "-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"],
        ])
    }

    @Test("Khôi phục về TẮT dùng -setwebproxystate off, KHÔNG set server rỗng port 0")
    func restoreToOffUsesStateCommand() async throws {
        let fake = FakeRunner(outputs: ["", ""])
        let sut = NetworkSetupConfigurer(runner: await fake.runner)
        try await sut.restore(ServiceProxySnapshot(service: "Wi-Fi", web: .off, secureWeb: .off))

        let commands = await fake.commands
        #expect(commands == [
            ["/usr/sbin/networksetup", "-setwebproxystate", "Wi-Fi", "off"],
            ["/usr/sbin/networksetup", "-setsecurewebproxystate", "Wi-Fi", "off"],
        ], "`-setwebproxy Wi-Fi \"\" 0` là lệnh không hợp lệ, sẽ lỗi lúc chạy thật")
    }

    @Test("Khôi phục về một proxy đang bật thì set server rồi bật state")
    func restoreToEnabledSetsServerThenState() async throws {
        let fake = FakeRunner(outputs: ["", "", "", ""])
        let sut = NetworkSetupConfigurer(runner: await fake.runner)
        let corporate = ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128)
        try await sut.restore(ServiceProxySnapshot(service: "Wi-Fi", web: corporate, secureWeb: .off))

        let commands = await fake.commands
        #expect(commands.first == ["/usr/sbin/networksetup", "-setwebproxy",
                                   "Wi-Fi", "proxy.corp.local", "3128"])
        #expect(commands.contains(["/usr/sbin/networksetup", "-setwebproxystate", "Wi-Fi", "on"]))
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó thất bại**

Run: `swift test --filter NetworkSetupConfigurer`
Expected: FAIL — `cannot find 'NetworkSetupConfigurer' in scope`.

- [ ] **Step 3: Viết protocol và kiểu lỗi**

```swift
// Sources/SystemProxy/SystemProxyConfiguring.swift
import Foundation

public typealias CommandRunner = @Sendable ([String]) async throws -> String

public enum SystemProxyError: Error, Sendable, Equatable {
    case commandFailed(status: Int32, output: String)
    /// `networksetup` chạy xong exit 0 nhưng output không đúng định dạng kỳ
    /// vọng. Tách riêng khỏi `commandFailed` vì nó KHÔNG được phép im lặng
    /// rơi về "đang tắt": đoán sai theo hướng đó sẽ làm ta ghi đè một cấu
    /// hình thật của người dùng bằng một giá trị bịa ra.
    case unreadableOutput(command: String, output: String)
    case snapshotUnreadable(String)
}

extension SystemProxyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Lệnh mạng thất bại (mã \(status))."
                : "Lệnh mạng thất bại (mã \(status)): \(trimmed)"
        case .unreadableOutput(let command, let output):
            return "Không đọc được kết quả của \(command): \(output)"
        case .snapshotUnreadable(let reason):
            return "Không đọc được file trạng thái proxy đã lưu: \(reason)"
        }
    }
}

/// Đọc và ghi cài đặt proxy của MỘT dịch vụ mạng mỗi lần.
///
/// Việc điều phối nhiều dịch vụ, quản file snapshot và chuẩn hoá nằm ở
/// `SystemProxyController`, không nằm ở đây — lớp này chỉ biết dịch một thao
/// tác thành lệnh và dịch output thành kiểu dữ liệu.
public protocol SystemProxyConfiguring: Sendable {
    func activeServices() async throws -> [String]
    func read(service: String) async throws -> ServiceProxySnapshot
    func apply(host: String, port: Int, to service: String) async throws
    func restore(_ snapshot: ServiceProxySnapshot) async throws
}
```

- [ ] **Step 4: Viết hiện thực `networksetup`**

```swift
// Sources/SystemProxy/NetworkSetupConfigurer.swift
import Foundation

/// Hiện thực bằng `/usr/sbin/networksetup`.
///
/// Chọn shell-out thay vì SystemConfiguration framework vì ghi qua
/// `SCPreferencesCreateWithAuthorization` gần như chắc chắn bật hộp thoại
/// mật khẩu — phá đúng mục tiêu "bấm Chạy là xong". Thêm nữa, khi hỏng,
/// người dùng gõ lại được đúng lệnh này trong Terminal để tự kiểm chứng và
/// tự cứu; không có tầng nào che mất.
public struct NetworkSetupConfigurer: SystemProxyConfiguring {
    static let binary = "/usr/sbin/networksetup"

    private let runner: CommandRunner

    public init(runner: @escaping CommandRunner = NetworkSetupConfigurer.runProcess) {
        self.runner = runner
    }

    // MARK: - Parsing

    /// Dịch vụ đang tắt được `networksetup` đánh dấu bằng `*` ở đầu tên.
    /// Dòng đầu là câu giải thích, không phải tên dịch vụ.
    static func parseServices(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("*") }
            .filter { !$0.lowercased().contains("denotes that a network service is disabled") }
    }

    static func parseProxy(_ output: String) throws -> ProxySetting {
        func field(_ name: String) -> String? {
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == name
                else { continue }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        guard let enabledText = field("Enabled") else {
            throw SystemProxyError.unreadableOutput(command: "getwebproxy", output: output)
        }
        return ProxySetting(
            enabled: enabledText.lowercased() == "yes",
            server: field("Server") ?? "",
            port: Int(field("Port") ?? "0") ?? 0
        )
    }

    // MARK: - SystemProxyConfiguring

    public func activeServices() async throws -> [String] {
        Self.parseServices(try await runner([Self.binary, "-listallnetworkservices"]))
    }

    public func read(service: String) async throws -> ServiceProxySnapshot {
        let web = try Self.parseProxy(try await runner([Self.binary, "-getwebproxy", service]))
        let secure = try Self.parseProxy(try await runner([Self.binary, "-getsecurewebproxy", service]))
        return ServiceProxySnapshot(service: service, web: web, secureWeb: secure)
    }

    public func apply(host: String, port: Int, to service: String) async throws {
        _ = try await runner([Self.binary, "-setwebproxy", service, host, String(port)])
        _ = try await runner([Self.binary, "-setsecurewebproxy", service, host, String(port)])
    }

    public func restore(_ snapshot: ServiceProxySnapshot) async throws {
        try await restore(snapshot.web, service: snapshot.service,
                          setCommand: "-setwebproxy", stateCommand: "-setwebproxystate")
        try await restore(snapshot.secureWeb, service: snapshot.service,
                          setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate")
    }

    /// Trạng thái gốc TẮT thì chỉ gọi `...state off`.
    ///
    /// Không gọi `-setwebproxy <svc> "" 0`: server rỗng và cổng 0 là đối số
    /// không hợp lệ, `networksetup` sẽ báo lỗi. Đường khôi phục mà tự ném lỗi
    /// là đúng cái không được phép hỏng.
    private func restore(_ setting: ProxySetting, service: String,
                         setCommand: String, stateCommand: String) async throws {
        guard setting.enabled else {
            _ = try await runner([Self.binary, stateCommand, service, "off"])
            return
        }
        _ = try await runner([Self.binary, setCommand, service, setting.server, String(setting.port)])
        _ = try await runner([Self.binary, stateCommand, service, "on"])
    }

    // MARK: - Chạy tiến trình thật

    public static let runProcess: CommandRunner = { arguments in
        try await withCheckedThrowingContinuation { continuation in
            // Thread riêng, KHÔNG Task.detached: Task.detached vẫn chạy trên
            // cooperative pool của Swift concurrency, chặn ở đó là chặn pool.
            Thread.detachNewThread {
                let result = runProcessSync(arguments)
                switch result {
                case .success(let output): continuation.resume(returning: output)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Bản đồng bộ, dùng chung cho `runProcess` và cho đường khôi phục lúc
    /// thoát app (`SyncProxyRestore`), nơi không `await` được.
    static func runProcessSync(_ arguments: [String]) -> Result<String, SystemProxyError> {
        guard let first = arguments.first, first.hasPrefix("/") else {
            return .failure(.commandFailed(status: -1, output: "cần đường dẫn tuyệt đối"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return .failure(.commandFailed(status: -1, output: "không exec được: \(error)"))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return .failure(.commandFailed(status: process.terminationStatus, output: output))
        }
        return .success(output)
    }
}
```

- [ ] **Step 5: Chạy test để xác nhận đã pass**

Run: `swift test --filter NetworkSetupConfigurer`
Expected: PASS, 8 test.

- [ ] **Step 6: Commit**

```bash
git add Sources/SystemProxy/SystemProxyConfiguring.swift Sources/SystemProxy/NetworkSetupConfigurer.swift Tests/SystemProxyTests/NetworkSetupConfigurerTests.swift
git commit -m "feat(SystemProxy): protocol, parse output networksetup, dựng lệnh"
```

---

## Task 4: File snapshot

**Files:**
- Create: `Sources/SystemProxy/ProxySnapshotStore.swift`
- Create: `Tests/SystemProxyTests/ProxySnapshotStoreTests.swift`

**Interfaces:**
- Consumes: `ProxySnapshot` (Task 2), `SystemProxyError` (Task 3)
- Produces: `ProxySnapshotStore(url:)` với `static var defaultURL: URL`, `write(_:) throws`, `read() throws -> ProxySnapshot?`, `delete() throws`, `var exists: Bool`.

- [ ] **Step 1: Viết test thất bại**

```swift
// Tests/SystemProxyTests/ProxySnapshotStoreTests.swift
import Testing
import Foundation
@testable import SystemProxy

@Suite("ProxySnapshotStore")
struct ProxySnapshotStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString)")
            .appendingPathComponent("system-proxy-snapshot.json")
    }

    private func sample() -> ProxySnapshot {
        ProxySnapshot(
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            appliedHost: "127.0.0.1",
            appliedPort: 9090,
            services: [ServiceProxySnapshot(service: "Wi-Fi", web: .off, secureWeb: .off)]
        )
    }

    @Test("Chưa có file thì read trả nil, không ném lỗi")
    func readsNilWhenAbsent() throws {
        let store = ProxySnapshotStore(url: tempURL())
        #expect(store.exists == false)
        #expect(try store.read() == nil)
    }

    @Test("Ghi rồi đọc lại đúng nguyên vẹn, thư mục cha được tạo nếu chưa có")
    func writesThenReadsBack() throws {
        let store = ProxySnapshotStore(url: tempURL())
        try store.write(sample())
        #expect(store.exists)
        #expect(try store.read() == sample())
    }

    @Test("Xoá xong thì exists false")
    func deletesFile() throws {
        let store = ProxySnapshotStore(url: tempURL())
        try store.write(sample())
        try store.delete()
        #expect(store.exists == false)
    }

    @Test("Xoá file không tồn tại không ném lỗi — disable gọi nó ở đường đã dọn rồi")
    func deleteIsIdempotent() throws {
        let store = ProxySnapshotStore(url: tempURL())
        #expect(throws: Never.self) { try store.delete() }
    }

    @Test("JSON hỏng thì ném snapshotUnreadable và KHÔNG xoá file")
    func throwsOnCorruptJSONWithoutDeleting() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ không phải json".utf8).write(to: url)
        let store = ProxySnapshotStore(url: url)

        #expect(throws: SystemProxyError.self) { _ = try store.read() }
        #expect(FileManager.default.fileExists(atPath: url.path),
                "xoá file lúc chưa khôi phục xong là vứt mất bản đồ đường về")
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó thất bại**

Run: `swift test --filter ProxySnapshotStore`
Expected: FAIL — `cannot find 'ProxySnapshotStore' in scope`.

- [ ] **Step 3: Viết hiện thực**

```swift
// Sources/SystemProxy/ProxySnapshotStore.swift
import Foundation

/// Lưu trạng thái proxy nguyên bản ra đĩa.
///
/// Đây là toàn bộ đường về sau một lần crash, nên `write` phải `fsync`: dữ
/// liệu nằm trong page cache mà máy mất điện thì file rỗng, và một file
/// snapshot rỗng còn tệ hơn không có file — nó nói dối rằng đã lưu xong.
public struct ProxySnapshotStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loupe", isDirectory: true)
            .appendingPathComponent("system-proxy-snapshot.json")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func write(_ snapshot: ProxySnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)

        // `.atomic` đảm bảo file không bị đọc thấy ở trạng thái nửa vời,
        // nhưng KHÔNG đảm bảo dữ liệu đã xuống đĩa. Với một file mà lý do tồn
        // tại của nó là sống sót qua crash, thiếu bước này là hỏng đúng chỗ.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public func read() throws -> ProxySnapshot? {
        guard exists else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SystemProxyError.snapshotUnreadable("không đọc được file: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(ProxySnapshot.self, from: data)
        } catch {
            // KHÔNG xoá file ở đây. Nội dung hỏng vẫn có thể cứu được bằng
            // tay; xoá đi là chắc chắn không.
            throw SystemProxyError.snapshotUnreadable("JSON hỏng: \(error.localizedDescription)")
        }
    }

    public func delete() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Chạy test để xác nhận đã pass**

Run: `swift test --filter ProxySnapshotStore`
Expected: PASS, 5 test.

- [ ] **Step 5: Commit**

```bash
git add Sources/SystemProxy/ProxySnapshotStore.swift Tests/SystemProxyTests/ProxySnapshotStoreTests.swift
git commit -m "feat(SystemProxy): file snapshot có fsync, giữ file khi JSON hỏng"
```

---

## Task 5: Controller — bật

**Files:**
- Create: `Sources/SystemProxy/SystemProxyController.swift`
- Create: `Tests/SystemProxyTests/SystemProxyControllerTests.swift`

**Interfaces:**
- Consumes: mọi kiểu của Task 2–4
- Produces: `actor SystemProxyController`, `init(configurer:store:)`, `enable(host:port:) async throws -> [String]` (trả về danh sách dịch vụ đã đặt thành công).

**Review Focus #1** (bật hai lần liên tiếp) và **#2** (không có dịch vụ nào) được pin bằng test trong task này.

- [ ] **Step 1: Viết test thất bại**

```swift
// Tests/SystemProxyTests/SystemProxyControllerTests.swift
import Testing
import Foundation
@testable import SystemProxy

@Suite("SystemProxyController")
struct SystemProxyControllerTests {

    /// Configurer giả: giữ trạng thái trong bộ nhớ, ghi lại timeline thao tác.
    actor FakeConfigurer: SystemProxyConfiguring {
        enum Event: Equatable {
            case list
            case read(String)
            case apply(service: String, host: String, port: Int)
            case restore(ServiceProxySnapshot)
        }

        private(set) var events: [Event] = []
        private var services: [String]
        private var current: [String: ServiceProxySnapshot]
        private let failApplyAt: Int?
        private let failRestoreFor: String?
        /// Gọi ngay trước mỗi `apply`, để test soi trạng thái đĩa đúng lúc đó.
        var onApply: (@Sendable () -> Void)?

        init(services: [String],
             current: [String: ServiceProxySnapshot] = [:],
             failApplyAt: Int? = nil,
             failRestoreFor: String? = nil) {
            self.services = services
            self.current = current
            self.failApplyAt = failApplyAt
            self.failRestoreFor = failRestoreFor
        }

        func setOnApply(_ block: @escaping @Sendable () -> Void) { onApply = block }

        func activeServices() async throws -> [String] {
            events.append(.list)
            return services
        }

        func read(service: String) async throws -> ServiceProxySnapshot {
            events.append(.read(service))
            return current[service]
                ?? ServiceProxySnapshot(service: service, web: .off, secureWeb: .off)
        }

        func apply(host: String, port: Int, to service: String) async throws {
            onApply?()
            let applyCount = events.filter { if case .apply = $0 { return true }; return false }.count
            if let failApplyAt, applyCount + 1 == failApplyAt {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi apply")
            }
            events.append(.apply(service: service, host: host, port: port))
            current[service] = ServiceProxySnapshot(
                service: service,
                web: ProxySetting(enabled: true, server: host, port: port),
                secureWeb: ProxySetting(enabled: true, server: host, port: port))
        }

        func restore(_ snapshot: ServiceProxySnapshot) async throws {
            if snapshot.service == failRestoreFor {
                throw SystemProxyError.commandFailed(status: 1, output: "giả lập lỗi restore")
            }
            events.append(.restore(snapshot))
            current[snapshot.service] = snapshot
        }

        var applied: [String] {
            events.compactMap { if case .apply(let s, _, _) = $0 { return s }; return nil }
        }
        var restored: [String] {
            events.compactMap { if case .restore(let s) = $0 { return s.service }; return nil }
        }
    }

    private func tempStore() -> ProxySnapshotStore {
        ProxySnapshotStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.json"))
    }

    @Test("Bật thì đặt proxy lên MỌI dịch vụ đang hoạt động")
    func enablesEveryActiveService() async throws {
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge", "phuoc.kieu-c-sg"])
        let sut = SystemProxyController(configurer: fake, store: tempStore())

        let applied = try await sut.enable(host: "127.0.0.1", port: 9090)

        #expect(applied == ["Wi-Fi", "Thunderbolt Bridge", "phuoc.kieu-c-sg"])
        #expect(await fake.applied == ["Wi-Fi", "Thunderbolt Bridge", "phuoc.kieu-c-sg"])
    }

    @Test("File snapshot tồn tại TRƯỚC lệnh apply đầu tiên")
    func writesSnapshotBeforeFirstApply() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"])

        // Soi đĩa ngay tại thời điểm apply đầu tiên được gọi.
        let sawFile = SeenBox()
        await fake.setOnApply { sawFile.record(store.exists) }

        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        #expect(sawFile.first == true,
                "crash giữa chừng mà chưa có file là mất sạch đường về")
    }

    @Test("Dấu vết cũ của chính app được ghi vào snapshot là TẮT")
    func normalisesOwnLeftoverBeforeSaving() async throws {
        let leftover = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090),
            secureWeb: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090))
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"], current: ["Wi-Fi": leftover])
        let sut = SystemProxyController(configurer: fake, store: store)

        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        let saved = try #require(try store.read())
        #expect(saved.services[0].web.enabled == false)
        #expect(saved.services[0].secureWeb.enabled == false)
    }

    @Test("Proxy công ty được lưu nguyên vẹn, không bị chuẩn hoá nhầm")
    func preservesCorporateProxyInSnapshot() async throws {
        let corporate = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128))
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"], current: ["Wi-Fi": corporate])
        let sut = SystemProxyController(configurer: fake, store: store)

        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        #expect(try #require(try store.read()).services[0] == corporate)
    }

    @Test("Apply hỏng giữa chừng thì lùi lại dịch vụ đã đặt và ném lỗi")
    func rollsBackOnPartialFailure() async throws {
        let store = tempStore()
        // Hỏng ở lần apply thứ hai.
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"], failApplyAt: 2)
        let sut = SystemProxyController(configurer: fake, store: store)

        await #expect(throws: SystemProxyError.self) {
            _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        }
        #expect(await fake.restored == ["Wi-Fi"], "dịch vụ đã đặt phải được trả lại")
        #expect(store.exists == false, "lùi xong thì không còn gì để khôi phục")
    }

    @Test("Bật lần hai khi snapshot đã tồn tại thì KHÔNG chụp đè")
    func doesNotOverwriteExistingSnapshot() async throws {
        let corporate = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off)
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"], current: ["Wi-Fi": corporate])
        let sut = SystemProxyController(configurer: fake, store: store)

        _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)   // lần hai

        #expect(try #require(try store.read()).services[0] == corporate,
                "chụp đè lần hai sẽ chụp nhằm trạng thái ta vừa đổi, xoá vĩnh viễn đường về")
    }

    @Test("Không có dịch vụ nào đang hoạt động thì ném lỗi, không báo thành công giả")
    func failsLoudlyWhenNoActiveServices() async throws {
        let store = tempStore()
        let sut = SystemProxyController(configurer: FakeConfigurer(services: []), store: store)

        await #expect(throws: SystemProxyError.self) {
            _ = try await sut.enable(host: "127.0.0.1", port: 9090)
        }
        #expect(store.exists == false, "không đặt được gì thì đừng để lại file trống")
    }
}

/// Hộp ghi nhận giá trị quan sát được từ trong closure `@Sendable`.
final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var first: Bool? { lock.lock(); defer { lock.unlock() }; return values.first }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó thất bại**

Run: `swift test --filter SystemProxyController`
Expected: FAIL — `cannot find 'SystemProxyController' in scope`.

- [ ] **Step 3: Viết hiện thực phần `enable`**

```swift
// Sources/SystemProxy/SystemProxyController.swift
import Foundation

/// Điều phối việc đặt/gỡ proxy trên NHIỀU dịch vụ, và quản file snapshot.
///
/// Đặt lên tất cả dịch vụ đang hoạt động chứ không chỉ dịch vụ chính: macOS
/// chỉ đọc cấu hình của dịch vụ chính, nhưng dịch vụ nào là chính thì đổi
/// theo thời gian — bật VPN là đổi, rút cáp là đổi. Đặt lên tất cả làm câu
/// hỏi "cái nào đang là chính" biến mất khỏi thiết kế thay vì phải theo dõi
/// nó suốt phiên.
public actor SystemProxyController {
    private let configurer: any SystemProxyConfiguring
    private let store: ProxySnapshotStore

    public init(configurer: any SystemProxyConfiguring = NetworkSetupConfigurer(),
                store: ProxySnapshotStore = ProxySnapshotStore(url: ProxySnapshotStore.defaultURL)) {
        self.configurer = configurer
        self.store = store
    }

    /// Đặt proxy lên mọi dịch vụ đang hoạt động. Trả về danh sách đã đặt.
    @discardableResult
    public func enable(host: String, port: Int) async throws -> [String] {
        let services = try await configurer.activeServices()
        guard !services.isEmpty else {
            // Báo lỗi chứ không lặng lẽ thành công: người dùng bấm Chạy và
            // thấy "đã đặt proxy" trong khi không đặt được gì là kiểu nói dối
            // dẫn tới nửa giờ chẩn đoán sai.
            throw SystemProxyError.commandFailed(
                status: -1, output: "Không có dịch vụ mạng nào đang hoạt động.")
        }

        // Chụp trạng thái gốc CHỈ khi chưa có snapshot. Bật lần hai mà chụp
        // đè là chụp nhằm trạng thái ta vừa đổi; luật chuẩn hoá sẽ biến nó
        // thành "tắt", và nếu gốc là proxy công ty thì đường về mất vĩnh viễn.
        if !store.exists {
            var originals: [ServiceProxySnapshot] = []
            for service in services {
                let current = try await configurer.read(service: service)
                originals.append(ServiceProxySnapshot(
                    service: service,
                    web: current.web.normalizedAsOriginal(appliedHost: host, appliedPort: port),
                    secureWeb: current.secureWeb.normalizedAsOriginal(appliedHost: host, appliedPort: port)
                ))
            }
            // Ghi và fsync TRƯỚC khi đổi bất cứ thứ gì. Đây là cốt lõi của
            // toàn bộ thiết kế: crash giữa vòng apply bên dưới thì file đã mô
            // tả đủ MỌI dịch vụ ta định đụng vào, kể cả cái chưa kịp đụng.
            // Khôi phục thừa thì vô hại; khôi phục thiếu thì mất mạng.
            try store.write(ProxySnapshot(takenAt: Date(), appliedHost: host,
                                          appliedPort: port, services: originals))
        }

        var applied: [String] = []
        do {
            for service in services {
                try await configurer.apply(host: host, port: port, to: service)
                applied.append(service)
            }
        } catch {
            await rollBack(applied)
            throw error
        }
        return applied
    }

    /// Lùi lại những dịch vụ đã đặt trong CHÍNH lần gọi này, rồi bỏ snapshot.
    ///
    /// Lỗi trong lúc lùi được nuốt có chủ ý: ta đang xử lý một lỗi khác và
    /// sắp ném nó lên trên; ném đè một lỗi thứ hai sẽ giấu mất nguyên nhân
    /// đầu tiên, thứ người dùng cần để hiểu chuyện gì đã xảy ra.
    private func rollBack(_ applied: [String]) async {
        guard let snapshot = try? store.read() else { return }
        for service in applied {
            guard let original = snapshot.services.first(where: { $0.service == service }) else { continue }
            try? await configurer.restore(original)
        }
        try? store.delete()
    }
}
```

- [ ] **Step 4: Chạy test để xác nhận đã pass**

Run: `swift test --filter SystemProxyController`
Expected: PASS, 7 test.

- [ ] **Step 5: Commit**

```bash
git add Sources/SystemProxy/SystemProxyController.swift Tests/SystemProxyTests/SystemProxyControllerTests.swift
git commit -m "feat(SystemProxy): enable — ghi snapshot trước khi đổi, rollback khi hỏng giữa chừng"
```

---

## Task 6: Controller — gỡ và khôi phục

**Files:**
- Modify: `Sources/SystemProxy/SystemProxyController.swift`
- Modify: `Tests/SystemProxyTests/SystemProxyControllerTests.swift`

**Interfaces:**
- Consumes: mọi thứ của Task 5
- Produces: `disable() async throws`, `recoverIfNeeded() async throws -> Bool` (true nếu có dọn gì đó).

**Review Focus #5** (cổng đổi giữa bật và gỡ) được pin bằng test trong task này.

- [ ] **Step 1: Viết test thất bại — thêm vào cuối `SystemProxyControllerTests`**

```swift
    @Test("Gỡ thì trả mọi dịch vụ về trạng thái đã lưu rồi xoá file")
    func disableRestoresEverythingThenDeletesFile() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"])
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        try await sut.disable()

        #expect(await fake.restored == ["Wi-Fi", "Thunderbolt Bridge"])
        #expect(store.exists == false)
    }

    @Test("Chỉ khôi phục dịch vụ CÒN đang trỏ vào ta; ai đã đổi đi thì để yên")
    func skipsServicesChangedBySomeoneElse() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"])
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        // Người dùng tự đặt Wi-Fi sang proxy công ty trong lúc app đang chạy.
        try await fake.restore(ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off))
        await fake.clearEvents()

        try await sut.disable()

        #expect(await fake.restored == ["Thunderbolt Bridge"],
                "ý muốn mới của người dùng phải thắng dấu vết cũ của ta")
    }

    @Test("Nhận diện dấu vết dùng appliedPort trong snapshot, không dùng cổng hiện tại")
    func usesAppliedPortFromSnapshotNotCurrentPort() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let sut = SystemProxyController(configurer: fake, store: store)
        // Cấu hình cổng 0 → kernel cấp 54321 cho lần chạy này.
        _ = try await sut.enable(host: "127.0.0.1", port: 54321)
        await fake.clearEvents()

        try await sut.disable()

        #expect(await fake.restored == ["Wi-Fi"],
                "đọc cổng ở chỗ khác ngoài snapshot là bỏ sót dịch vụ cần trả lại")
    }

    @Test("Khôi phục hỏng một dịch vụ thì GIỮ file lại để lần sau thử tiếp")
    func keepsSnapshotWhenRestoreFails() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                  failRestoreFor: "Thunderbolt Bridge")
        let sut = SystemProxyController(configurer: fake, store: store)
        _ = try await sut.enable(host: "127.0.0.1", port: 9090)

        await #expect(throws: SystemProxyError.self) { try await sut.disable() }
        #expect(store.exists, "xoá file lúc chưa khôi phục xong là vứt mất bản đồ đường về")
    }

    @Test("Mở app mà không có file sót thì KHÔNG chạy lệnh nào")
    func recoverDoesNothingWithoutSnapshot() async throws {
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let sut = SystemProxyController(configurer: fake, store: tempStore())

        #expect(try await sut.recoverIfNeeded() == false)
        #expect(await fake.events.isEmpty, "app mở bình thường không được đụng vào cài đặt mạng")
    }

    @Test("File sót thì khôi phục rồi xoá")
    func recoverRestoresLeftoverSnapshot() async throws {
        let store = tempStore()
        let fake = FakeConfigurer(services: ["Wi-Fi"])
        let first = SystemProxyController(configurer: fake, store: store)
        _ = try await first.enable(host: "127.0.0.1", port: 9090)
        // Không gọi disable — giả lập app bị SIGKILL.

        let afterRelaunch = SystemProxyController(configurer: fake, store: store)
        #expect(try await afterRelaunch.recoverIfNeeded() == true)
        #expect(store.exists == false)
    }

    @Test("JSON hỏng thì đi đường cứu: chỉ tắt dịch vụ đang trỏ vào ta")
    func corruptSnapshotFallsBackToTurningOffOwnLeftovers() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ hỏng".utf8).write(to: url)

        let ours = ServiceProxySnapshot(
            service: "Wi-Fi",
            web: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090),
            secureWeb: ProxySetting(enabled: true, server: "127.0.0.1", port: 9090))
        let corporate = ServiceProxySnapshot(
            service: "Thunderbolt Bridge",
            web: ProxySetting(enabled: true, server: "proxy.corp.local", port: 3128),
            secureWeb: .off)
        let fake = FakeConfigurer(services: ["Wi-Fi", "Thunderbolt Bridge"],
                                  current: ["Wi-Fi": ours, "Thunderbolt Bridge": corporate])
        let sut = SystemProxyController(configurer: fake,
                                        store: ProxySnapshotStore(url: url))

        _ = try await sut.recoverIfNeeded(fallbackPort: 9090)

        #expect(await fake.restored == ["Wi-Fi"], "chỉ gỡ dấu vết chắc chắn của ta")
        let restoredWiFi = await fake.lastRestored(for: "Wi-Fi")
        #expect(restoredWiFi?.web.enabled == false)
    }
```

Thêm vào `FakeConfigurer` hai helper mà các test trên dùng:

```swift
        func clearEvents() { events.removeAll() }

        func lastRestored(for service: String) -> ServiceProxySnapshot? {
            events.reversed().compactMap {
                if case .restore(let s) = $0, s.service == service { return s }
                return nil
            }.first
        }
```

- [ ] **Step 2: Chạy test để chắc chắn nó thất bại**

Run: `swift test --filter SystemProxyController`
Expected: FAIL — `value of type 'SystemProxyController' has no member 'disable'`.

- [ ] **Step 3: Viết hiện thực — thêm vào `SystemProxyController`**

```swift
    /// Trả mọi dịch vụ về trạng thái đã lưu, rồi xoá file.
    ///
    /// Xoá file CHỈ khi tất cả thành công. Hỏng cái nào thì giữ lại để lần mở
    /// sau thử tiếp — xoá lúc chưa khôi phục xong là vứt mất bản đồ đường về.
    public func disable() async throws {
        guard let snapshot = try store.read() else { return }
        try await restore(snapshot)
        try store.delete()
    }

    /// Gọi lúc app khởi động. Trả về true nếu có dọn gì đó.
    ///
    /// File còn sót nghĩa là lần trước chết bất thường (SIGKILL, mất điện) —
    /// không có cách nào chạy code sau SIGKILL, nên đây là đường về duy nhất.
    ///
    /// - Parameter fallbackPort: cổng dùng để nhận diện dấu vết của chính app
    ///   khi file snapshot hỏng không đọc được `appliedPort` từ trong đó.
    @discardableResult
    public func recoverIfNeeded(fallbackPort: Int = 9090) async throws -> Bool {
        guard store.exists else { return false }

        let snapshot: ProxySnapshot
        do {
            guard let read = try store.read() else { return false }
            snapshot = read
        } catch {
            // File hỏng: vẫn còn một đường cứu không cần tới nó. Dấu vết
            // loopback đúng cổng ta chắc chắn do ta để lại, nên tắt nó an
            // toàn kể cả khi không biết trạng thái gốc. Không đoán gì thêm
            // ngoài phạm vi đó — proxy của người khác không bị đụng.
            try await turnOffOwnLeftovers(host: "127.0.0.1", port: fallbackPort)
            try store.delete()
            return true
        }

        try await restore(snapshot)
        try store.delete()
        return true
    }

    /// Luật chung cho mọi đường khôi phục: chỉ đụng dịch vụ mà cấu hình HIỆN
    /// TẠI vẫn đang trỏ vào ta.
    ///
    /// Không có luật này thì kịch bản sau làm hỏng việc thật: app crash →
    /// người dùng mất mạng → họ tự đặt proxy công ty → mở lại app → app lẳng
    /// lặng đạp mất cấu hình vừa đặt, viện cớ "khôi phục". Ý muốn mới của
    /// người dùng phải thắng dấu vết cũ của ta.
    ///
    /// Luật này cũng làm việc khôi phục idempotent: chạy lại bao nhiêu lần
    /// cũng không hại.
    private func restore(_ snapshot: ProxySnapshot) async throws {
        for original in snapshot.services {
            let current = try await configurer.read(service: original.service)
            let stillOurs =
                current.web.pointsAt(host: snapshot.appliedHost, port: snapshot.appliedPort)
                || current.secureWeb.pointsAt(host: snapshot.appliedHost, port: snapshot.appliedPort)
            guard stillOurs else { continue }
            try await configurer.restore(original)
        }
    }

    private func turnOffOwnLeftovers(host: String, port: Int) async throws {
        for service in try await configurer.activeServices() {
            let current = try await configurer.read(service: service)
            let web = current.web.pointsAt(host: host, port: port) ? ProxySetting.off : current.web
            let secure = current.secureWeb.pointsAt(host: host, port: port)
                ? ProxySetting.off : current.secureWeb
            guard web != current.web || secure != current.secureWeb else { continue }
            try await configurer.restore(
                ServiceProxySnapshot(service: service, web: web, secureWeb: secure))
        }
    }
```

- [ ] **Step 4: Chạy test để xác nhận đã pass**

Run: `swift test --filter SystemProxyController`
Expected: PASS, 14 test.

- [ ] **Step 5: Chạy toàn bộ test để chắc chắn không vỡ gì**

Run: `swift test`
Expected: PASS, 173 test cũ + test mới.

- [ ] **Step 6: Commit**

```bash
git add Sources/SystemProxy/SystemProxyController.swift Tests/SystemProxyTests/SystemProxyControllerTests.swift
git commit -m "feat(SystemProxy): disable/recover, chỉ đụng dịch vụ còn trỏ vào ta"
```

---

## Task 7: Đường khôi phục đồng bộ

`applicationWillTerminate` là hàm đồng bộ — trả về xong là app chết, một `Task` async bên trong sẽ không kịp chạy. Signal handler cũng vậy.

**Files:**
- Create: `Sources/SystemProxy/SyncProxyRestore.swift`
- Modify: `Tests/SystemProxyTests/ProxySnapshotStoreTests.swift` (thêm suite mới ở cuối file)

**Interfaces:**
- Consumes: `ProxySnapshotStore`, `ProxySnapshot`, `NetworkSetupConfigurer.runProcessSync` (Task 3–4)
- Produces: `enum SyncProxyRestore` với `static func restoreNow(storeURL: URL, runSync: (([String]) -> Result<String, SystemProxyError>)) -> Bool`, và overload mặc định dùng `NetworkSetupConfigurer.runProcessSync`.

- [ ] **Step 1: Viết test thất bại**

```swift
@Suite("SyncProxyRestore")
struct SyncProxyRestoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.json")
    }

    @Test("Không có file thì không chạy lệnh nào và trả false")
    func noopWithoutSnapshot() {
        var commands: [[String]] = []
        let done = SyncProxyRestore.restoreNow(storeURL: tempURL()) { args in
            commands.append(args); return .success("")
        }
        #expect(done == false)
        #expect(commands.isEmpty)
    }

    @Test("Có file thì gỡ proxy trên dịch vụ còn trỏ vào ta rồi xoá file")
    func restoresAndDeletes() throws {
        let url = tempURL()
        let store = ProxySnapshotStore(url: url)
        try store.write(ProxySnapshot(
            takenAt: Date(), appliedHost: "127.0.0.1", appliedPort: 9090,
            services: [ServiceProxySnapshot(service: "Wi-Fi", web: .off, secureWeb: .off)]))

        var commands: [[String]] = []
        let done = SyncProxyRestore.restoreNow(storeURL: url) { args in
            commands.append(args)
            // Giả lập: Wi-Fi vẫn đang trỏ vào ta.
            if args.contains("-getwebproxy") || args.contains("-getsecurewebproxy") {
                return .success("Enabled: Yes\nServer: 127.0.0.1\nPort: 9090")
            }
            return .success("")
        }

        #expect(done == true)
        #expect(commands.contains(["/usr/sbin/networksetup", "-setwebproxystate", "Wi-Fi", "off"]))
        #expect(store.exists == false)
    }

    @Test("Lệnh hỏng thì GIỮ file lại cho lần mở sau")
    func keepsSnapshotWhenCommandFails() throws {
        let url = tempURL()
        let store = ProxySnapshotStore(url: url)
        try store.write(ProxySnapshot(
            takenAt: Date(), appliedHost: "127.0.0.1", appliedPort: 9090,
            services: [ServiceProxySnapshot(service: "Wi-Fi", web: .off, secureWeb: .off)]))

        _ = SyncProxyRestore.restoreNow(storeURL: url) { args in
            if args.contains("-getwebproxy") {
                return .success("Enabled: Yes\nServer: 127.0.0.1\nPort: 9090")
            }
            return .failure(.commandFailed(status: 1, output: "giả lập lỗi"))
        }
        #expect(store.exists, "thoát app mà gỡ hỏng thì lần mở sau phải còn đường dọn")
    }
}
```

- [ ] **Step 2: Chạy test để chắc chắn nó thất bại**

Run: `swift test --filter SyncProxyRestore`
Expected: FAIL — `cannot find 'SyncProxyRestore' in scope`.

- [ ] **Step 3: Viết hiện thực**

```swift
// Sources/SystemProxy/SyncProxyRestore.swift
import Foundation

/// Khôi phục proxy KHÔNG dùng async.
///
/// `applicationWillTerminate` là hàm đồng bộ: trả về xong là app chết, nên
/// một `Task { await controller.disable() }` bên trong sẽ không bao giờ chạy
/// tới nơi. Signal handler cũng vậy. Đây là ràng buộc của nền tảng, không
/// phải lựa chọn thiết kế — nên đường đồng bộ này tồn tại song song với
/// `SystemProxyController`, dùng chung logic quyết định nhưng khác cách chạy
/// lệnh.
public enum SyncProxyRestore {
    public typealias SyncRunner = ([String]) -> Result<String, SystemProxyError>

    /// - Returns: true nếu có dọn gì đó.
    @discardableResult
    public static func restoreNow(
        storeURL: URL,
        runSync: SyncRunner = { NetworkSetupConfigurer.runProcessSync($0) }
    ) -> Bool {
        let store = ProxySnapshotStore(url: storeURL)
        // `try?` trên một biểu thức kiểu `ProxySnapshot?` được Swift làm
        // phẳng thành `ProxySnapshot?`, nên một lần `let` là đủ.
        guard store.exists, let snapshot = try? store.read() else { return false }

        let binary = NetworkSetupConfigurer.binary
        var allSucceeded = true

        for original in snapshot.services {
            // Cùng luật với đường async: chỉ đụng dịch vụ còn trỏ vào ta.
            guard case .success(let webOut) =
                    runSync([binary, "-getwebproxy", original.service]),
                  let currentWeb = try? NetworkSetupConfigurer.parseProxy(webOut)
            else { allSucceeded = false; continue }

            guard currentWeb.pointsAt(host: snapshot.appliedHost, port: snapshot.appliedPort) else {
                continue
            }

            for (setting, setCmd, stateCmd) in [
                (original.web, "-setwebproxy", "-setwebproxystate"),
                (original.secureWeb, "-setsecurewebproxy", "-setsecurewebproxystate"),
            ] {
                let commands: [[String]] = setting.enabled
                    ? [[binary, setCmd, original.service, setting.server, String(setting.port)],
                       [binary, stateCmd, original.service, "on"]]
                    : [[binary, stateCmd, original.service, "off"]]
                for command in commands {
                    if case .failure = runSync(command) { allSucceeded = false }
                }
            }
        }

        // Giữ file khi có bất kỳ lệnh nào hỏng: lần mở sau `recoverIfNeeded`
        // sẽ thử lại. Luật khôi phục là idempotent nên thử lại vô hại.
        if allSucceeded { try? store.delete() }
        return true
    }
}
```

- [ ] **Step 4: Chạy test để xác nhận đã pass**

Run: `swift test --filter SyncProxyRestore`
Expected: PASS, 3 test.

- [ ] **Step 5: Commit**

```bash
git add Sources/SystemProxy/SyncProxyRestore.swift Tests/SystemProxyTests/ProxySnapshotStoreTests.swift
git commit -m "feat(SystemProxy): đường khôi phục đồng bộ cho lúc thoát app"
```

---

## Task 8: Nối vào `AppModel` và thêm toggle

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/AppCore/AppModel.swift`
- Modify: `Sources/AppCore/ContentView.swift`
- Modify: `Tests/AppTests/` — thêm `SystemProxyWiringTests.swift`

**Interfaces:**
- Consumes: `SystemProxyController` (Task 5–6)
- Produces: `AppModel.setSystemProxy: Bool` (đọc được, mặc định `true`), `AppModel.setSetSystemProxy(_:) async`.

- [ ] **Step 1: Cho `AppCore` phụ thuộc `SystemProxy` trong `Package.swift`**

Sửa target `AppCore`, thêm `"SystemProxy"` vào `dependencies`:

```swift
        .target(name: "AppCore", dependencies: [
            "TrafficModel", "CertKit", "ProxyCore", "SystemProxy",
        ]),
```

Và test target `AppTests`:

```swift
        .testTarget(name: "AppTests", dependencies: ["AppCore", "TrafficModel", "CertKit", "ProxyCore", "SystemProxy"]),
```

- [ ] **Step 2: Viết test thất bại**

```swift
// Tests/AppTests/SystemProxyWiringTests.swift
import Testing
import Foundation
@testable import AppCore

@Suite("AppModel — nối proxy hệ thống")
@MainActor
struct SystemProxyWiringTests {

    @Test("Toggle mặc định BẬT")
    func defaultsToOn() {
        #expect(AppModel().setSystemProxy == true)
    }

    @Test("Toggle không lưu qua các lần mở app — model mới luôn bật lại")
    func doesNotPersistAcrossLaunches() async {
        let first = AppModel()
        await first.setSetSystemProxy(false)
        #expect(first.setSystemProxy == false)

        #expect(AppModel().setSystemProxy == true,
                "công tắc đổi cài đặt mạng toàn máy nên về giá trị đã biết mỗi lần mở")
    }

    @Test("Đặt lại đúng giá trị đang có thì không làm gì")
    func ignoresRedundantChange() async {
        let model = AppModel()
        await model.setSetSystemProxy(true)
        #expect(model.setSystemProxy == true)
    }
}
```

- [ ] **Step 3: Chạy test để chắc chắn nó thất bại**

Run: `swift test --filter "AppModel — nối proxy"`
Expected: FAIL — `value of type 'AppModel' has no member 'setSystemProxy'`.

- [ ] **Step 4: Sửa `AppModel`**

Thêm `import SystemProxy` lên đầu file. Thêm property cạnh hai toggle sẵn có (quanh dòng 39–44):

```swift
    /// Tự đặt proxy hệ thống lên mọi dịch vụ mạng khi Chạy, và gỡ khi Dừng.
    ///
    /// KHÔNG lưu qua các lần mở app — giống `allowLANDevices` và
    /// `forceDecompressible`. Với một công tắc đổi cài đặt mạng toàn máy, về
    /// giá trị đã biết mỗi lần mở an toàn hơn là âm thầm khôi phục lựa chọn
    /// của phiên trước.
    public private(set) var setSystemProxy = true
```

Thêm property lưu controller cạnh `installTask`:

```swift
    private let systemProxy = SystemProxyController()
```

Thêm hàm đổi toggle, cạnh `setForceDecompressible`:

```swift
    /// Khác hai toggle kia: KHÔNG đi qua `restartIfRunning()`. Dựng lại cả
    /// engine chỉ để đổi cài đặt mạng là thừa, và nó sẽ cắt đứt mọi kết nối
    /// đang mở. Bật/gỡ thẳng là đủ.
    public func setSetSystemProxy(_ enabled: Bool) async {
        guard enabled != setSystemProxy else { return }
        setSystemProxy = enabled
        guard isRunning, let port = listeningPort else { return }
        if enabled {
            await applySystemProxy(port: port)
        } else {
            await removeSystemProxy()
        }
    }

    /// Đặt proxy hệ thống, và hạ toggle nếu thất bại.
    ///
    /// Toggle phải phản ánh THỰC TẾ, không phản ánh ý định: để nó bật trong
    /// khi không đặt được gì là nói dối người dùng về trạng thái máy họ.
    /// Engine vẫn chạy — nó đã bind rồi và vẫn dùng được qua cờ
    /// `--proxy-server` hoặc cấu hình tay.
    private func applySystemProxy(port: Int) async {
        do {
            let services = try await systemProxy.enable(host: "127.0.0.1", port: port)
            statusMessage += " — đã đặt proxy cho \(services.count) dịch vụ mạng"
        } catch {
            setSystemProxy = false
            statusMessage += " — KHÔNG đặt được proxy hệ thống: \(error.localizedDescription)"
        }
    }

    private func removeSystemProxy() async {
        do {
            try await systemProxy.disable()
        } catch {
            // Đây là trạng thái có thể đang mất mạng, nên nó phải ồn và phải
            // kèm đúng lệnh người dùng gõ được để tự cứu.
            statusMessage = """
            GỠ PROXY HỆ THỐNG THẤT BẠI: \(error.localizedDescription)
            Máy có thể đang không vào mạng được. Mở Terminal và chạy:
            networksetup -setwebproxystate Wi-Fi off
            networksetup -setsecurewebproxystate Wi-Fi off
            """
        }
    }
```

Thêm property lưu cổng đang nghe, cạnh `server`:

```swift
    private var listeningPort: Int?
```

Trong `start()`, sau dòng `statusMessage = Self.listeningStatus(...)`, thêm:

```swift
            listeningPort = port
            if setSystemProxy {
                await applySystemProxy(port: port)
            }
```

Trong `stop()`, ngay đầu hàm — **trước** `guard let server`, vì proxy hệ thống phải được gỡ kể cả khi engine đã chết:

```swift
        await removeSystemProxy()
        listeningPort = nil
```

- [ ] **Step 5: Thêm toggle vào `ContentView`**

Trong `.safeAreaInset(edge: .bottom)`, sau toggle LAN sẵn có:

```swift
                Toggle("Đặt proxy cho máy này", isOn: Binding(
                    get: { model.setSystemProxy },
                    set: { on in Task { await model.setSetSystemProxy(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Tự đặt proxy hệ thống lên mọi dịch vụ mạng khi Chạy, và gỡ khi Dừng. "
                    + "Tắt nếu bạn chỉ muốn bắt traffic từ iPhone và không muốn máy Mac đi qua proxy.")
```

- [ ] **Step 6: Chạy test để xác nhận đã pass**

Run: `swift test`
Expected: PASS, toàn bộ.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/AppCore/AppModel.swift Sources/AppCore/ContentView.swift Tests/AppTests/SystemProxyWiringTests.swift
git commit -m "feat(AppCore): toggle đặt proxy hệ thống, nối vào start/stop"
```

---

## Task 9: Vòng đời app — khôi phục lúc mở, gỡ lúc thoát, bắt signal

**Files:**
- Modify: `Sources/LoupeApp/App.swift`

**Interfaces:**
- Consumes: `SyncProxyRestore`, `ProxySnapshotStore.defaultURL`, `SystemProxyController` (Task 4, 6, 7)
- Produces: không có API mới cho task sau.

- [ ] **Step 1: Viết `AppDelegate`**

```swift
// Sources/LoupeApp/App.swift
import SwiftUI
import AppKit
import Dispatch
import AppCore
import SystemProxy

/// Dọn proxy hệ thống ở ba thời điểm mà SwiftUI không tự lo:
/// mở app, thoát bình thường, và bị SIGTERM/SIGINT.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TRƯỚC khi vẽ cửa sổ. File còn sót nghĩa là lần trước chết bất
        // thường; người dùng lúc này nhiều khả năng đang không vào được mạng,
        // nên dọn là việc khẩn nhất, không phải việc để sau.
        SyncProxyRestore.restoreNow(storeURL: ProxySnapshotStore.defaultURL)

        installSignalHandler(SIGTERM)
        installSignalHandler(SIGINT)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Đồng bộ, KHÔNG Task { }: hàm này trả về xong là app chết, một Task
        // async sẽ không kịp chạy tới nơi.
        SyncProxyRestore.restoreNow(storeURL: ProxySnapshotStore.defaultURL)
    }

    /// `DispatchSource` chạy handler trên một hàng đợi bình thường, không
    /// trong ngữ cảnh signal — nên gọi được `Process`, `FileManager` và mọi
    /// thứ khác vốn KHÔNG async-signal-safe. Một `signal(2)` handler thì
    /// không: ghi file hay spawn tiến trình trong đó là hành vi không xác
    /// định.
    private func installSignalHandler(_ sig: Int32) {
        signal(sig, SIG_IGN)   // tắt hành vi mặc định, nếu không tiến trình chết ngay
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            SyncProxyRestore.restoreNow(storeURL: ProxySnapshotStore.defaultURL)
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

@main
struct LoupeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // Chạy bằng `swift run` thì binary không nằm trong .app bundle, nên
        // phải tự activate để cửa sổ nhận được focus (mặc định nó mở phía
        // sau các app khác, dễ trông như app "không chạy").
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Loupe") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 640)
        }
    }
}
```

- [ ] **Step 2: Build và chạy toàn bộ test**

Run: `swift build && swift test`
Expected: build sạch, toàn bộ test PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/LoupeApp/App.swift
git commit -m "feat(App): dọn proxy lúc mở app, lúc thoát, và khi bị SIGTERM"
```

---

## Task 10: Kiểm thủ công M2–M7

Ba lỗi nặng nhất của dự án này — `TabView` không vẽ thanh tab, cây JSON thu gọn hết, và §6.3 Root CA — **đều qua sạch toàn bộ test**. Task này không phải thủ tục cho có.

**Files:** không sửa file nào. Chỉ chạy và quan sát.

- [ ] **Step 1: Dựng app và ghi lại trạng thái xuất phát**

```bash
./Scripts/make-app.sh
networksetup -getwebproxy Wi-Fi | tee /tmp/before-manual.txt
open Loupe.app
```

- [ ] **Step 2: M7 — dọn mớ cũ**

Máy đang có Wi-Fi bật proxy trỏ 9090 (dấu vết cũ). Bấm Chạy, rồi bấm Dừng.

```bash
networksetup -getwebproxy Wi-Fi
```
Expected: `Enabled: No`. **KHÔNG** được là `Enabled: Yes ... 9090` — nếu vẫn 9090 thì luật chuẩn hoá §2.3 hỏng.

- [ ] **Step 3: M1 lại trong app thật + M2**

Bấm Chạy.
```bash
networksetup -getwebproxy Wi-Fi
networksetup -getwebproxy "Thunderbolt Bridge"
```
Expected: cả hai `Enabled: Yes`, `127.0.0.1`, `9090`. Không hộp thoại mật khẩu nào.

Bấm Dừng.
```bash
networksetup -getwebproxy Wi-Fi
```
Expected: `Enabled: No`.

- [ ] **Step 4: M3 — thoát bằng ⌘Q khi đang chạy**

Bấm Chạy, xác nhận proxy đã bật, rồi ⌘Q.
```bash
networksetup -getwebproxy Wi-Fi
```
Expected: `Enabled: No`.

- [ ] **Step 5: M4 — SIGKILL rồi mở lại**

```bash
open Loupe.app   # bấm Chạy trong app
networksetup -getwebproxy Wi-Fi          # Enabled: Yes
pkill -9 -f "Loupe.app/Contents/MacOS"
networksetup -getwebproxy Wi-Fi          # vẫn Yes — đúng, không tránh được
open Loupe.app
sleep 3
networksetup -getwebproxy Wi-Fi          # phải là No
```
Expected: sau khi mở lại, `Enabled: No`, và việc dọn xảy ra trước khi cửa sổ hiện.

- [ ] **Step 6: M6 — người dùng tự đổi proxy giữa chừng**

Bấm Chạy. Rồi trong Terminal:
```bash
networksetup -setwebproxy Wi-Fi 127.0.0.1 8888
```
Bấm Dừng trong app.
```bash
networksetup -getwebproxy Wi-Fi
```
Expected: vẫn là `127.0.0.1`, `8888`, `Enabled: Yes`. App **không** được đạp giá trị này.

Dọn tay sau khi kiểm xong:
```bash
networksetup -setwebproxystate Wi-Fi off
```

- [ ] **Step 7: M5 — bật VPN giữa chừng**

Bấm Chạy với VPN đang tắt. Mở Chrome, xác nhận traffic lên bảng. Bật VPN. Tải lại trang.
Expected: traffic vẫn lên bảng, không phải làm gì. (Vì proxy đã được đặt lên *mọi* dịch vụ từ đầu, kể cả dịch vụ VPN.)

- [ ] **Step 8: Ghi kết quả vào decision log**

Thêm một mục vào `docs/superpowers/2026-09-06-mvp-decision-log.md` ghi ngày kiểm, M nào đạt, M nào không, và output thật của mục không đạt.

- [ ] **Step 9: Commit**

```bash
git add docs/superpowers/2026-09-06-mvp-decision-log.md
git commit -m "docs: kết quả kiểm thủ công M1-M7 cho proxy hệ thống"
```

---

## Self-review

**Spec coverage:**

| Mục spec | Task |
| --- | --- |
| §2.1 tất cả dịch vụ | 5 (`enablesEveryActiveService`) |
| §2.2 khôi phục qua file, lần mở sau | 6 (`recoverRestoresLeftoverSnapshot`), 9 |
| §2.3 dấu vết của chính app → tắt | 2, 5 (`normalisesOwnLeftoverBeforeSaving`) |
| §2.4 toggle mặc định bật, không lưu | 8 |
| §3 module và kiểu | 2, 3 |
| §3.1 đường đồng bộ | 7 |
| §3.2 vị trí file | 4 (`defaultURL`) |
| §4.1 thứ tự ghi file trước apply | 5 (`writesSnapshotBeforeFirstApply`) |
| §4.2 xoá file chỉ khi tất cả thành công | 6 (`keepsSnapshotWhenRestoreFails`) |
| §4.3 khôi phục trước khi vẽ cửa sổ | 9 |
| §4.4 chỉ đụng dịch vụ còn trỏ vào ta | 6 (`skipsServicesChangedBySomeoneElse`) |
| §4.5 `restartIfRunning` | 8 (toggle không đi qua restart) |
| §5.1 rollback, toggle về tắt | 5, 8 |
| §5.2 báo lỗi kèm lệnh tự cứu | 8 (`removeSystemProxy`) |
| §5.3 file hỏng → đường cứu | 6 (`corruptSnapshotFallsBackTo...`) |
| §5.4 quyền bị từ chối | 1, 3 |
| §5.5 thoát app | 7, 9 |
| §6.3 kiểm thủ công M1–M7 | 1, 10 |
| §7.1 rủi ro quyền GUI | 1 (cổng chặn) |
| §7.2 thời gian lúc thoát | 10 (M3) |
| §7.3 dịch vụ biến mất | 6 (`keepsSnapshotWhenRestoreFails`) |

Không có mục spec nào thiếu task.

**Review Focus:** cả 5 mục đều có test trong task sở hữu code — #1 và #2 ở Task 5, #3 và #4 ở Task 3, #5 ở Task 6.

**Type consistency:** `ProxySetting.pointsAt(host:port:)`, `normalizedAsOriginal(appliedHost:appliedPort:)`, `SystemProxyController.enable(host:port:)`/`disable()`/`recoverIfNeeded(fallbackPort:)`, `ProxySnapshotStore.write/read/delete/exists`, `SyncProxyRestore.restoreNow(storeURL:runSync:)` — dùng nhất quán ở mọi task.
