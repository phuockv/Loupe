import Foundation
import Observation
import CertKit
import ProxyCore
import TrafficModel

/// Chủ sở hữu vòng đời của proxy (start/stop), của việc cài Root CA vào
/// system keychain, và của `TrafficStore` mà UI đọc.
///
/// `isRunning`/`statusMessage` chỉ được ghi từ đây (`private(set)`) — view
/// chỉ đọc và gọi `start()`/`stop()`/`installCertificate()`.
@MainActor
@Observable
public final class AppModel {
    public let store: TrafficStore
    public private(set) var isRunning = false
    public private(set) var statusMessage = "Chưa chạy"
    public var selection: Transaction.ID?

    /// `nil` nghĩa là "chưa kiểm tra lần nào trong phiên này", KHÔNG phải
    /// "chưa cài". Chỉ được set bởi `refreshCertificateStatus()` — không bao
    /// giờ được tính lại trong `body`, trong một computed property, hay trên
    /// timer: `TrustStoreInstaller.isInstalled` fork+exec `/usr/bin/security`
    /// mỗi lần gọi (vài chục ms), và gọi nó từ một đường tái tính toán của
    /// SwiftUI nghĩa là gọi lại nó mỗi lần render.
    public private(set) var certificateInstalled: Bool?

    /// Bind `0.0.0.0` thay vì `127.0.0.1`, để thiết bị khác trong LAN (iPhone,
    /// máy ảo) dùng được proxy này.
    ///
    /// Mặc định TẮT, có chủ ý. Bind mọi interface biến proxy thành một open
    /// proxy trên mạng: bất kỳ ai cùng Wi-Fi đều định tuyến traffic của họ qua
    /// máy này được, và log ở đây sẽ lẫn traffic lạ. Ở mạng nhà rủi ro thấp; ở
    /// quán cà phê hay mạng công ty thì không. Người dùng bật khi cần bắt
    /// traffic thiết bị khác, tắt khi xong.
    ///
    /// Chỉ đổi qua `setAllowLANDevices(_:)` — đổi thẳng sẽ không restart
    /// proxy đang chạy, và bind chỉ đọc giá trị này lúc `start()`.
    public private(set) var allowLANDevices = false

    /// Ép server không dùng brotli/zstd, bằng cách viết lại `Accept-Encoding`
    /// của request forward. Xem `ProxyConfiguration.rewriteAcceptEncoding` —
    /// nó THAY ĐỔI thứ đi trên dây, nên mặc định tắt.
    public private(set) var forceDecompressible = false

    private var server: ProxyServer?
    private var consumeTask: Task<Void, Never>?

    /// Task thật sự chạy `installer.install(pemPath:)`, sở hữu bởi AppModel
    /// chứ không phải bởi view gọi `installCertificate()`.
    ///
    /// `install(pemPath:)` hiện hộp thoại xin mật khẩu qua osascript và chặn
    /// một OS thread cho tới khi người dùng trả lời — `runProcess` không có
    /// đường lan truyền cancellation nào cho việc đó. Nếu Task chạy việc này
    /// bị buộc vào vòng đời của view (ví dụ tạo trong `.task {}` rồi view
    /// biến mất), huỷ Task đó không dừng được thread đang chặn thật sự — nó
    /// chỉ làm ta MẤT tham chiếu tới một tác vụ vẫn đang chạy ngầm, tức leak.
    /// Giữ Task ở đây, độc lập với bất kỳ Task nào ở call site, để nó luôn có
    /// chủ; đồng thời hai lần gọi `installCertificate()` chồng nhau chia sẻ
    /// cùng một lần cài thay vì bật hai hộp thoại mật khẩu.
    private var installTask: Task<Void, Never>?

    private let configuration: ProxyConfiguration
    private let installer: any TrustStoreInstaller

    /// Thư mục chứa `ca.pem`/`ca.key.pem`. Mặc định là thư mục thật của ứng
    /// dụng; test truyền một thư mục tạm để không đụng tới Application
    /// Support thật của máy chạy test.
    private let caDirectory: URL

    public init(
        configuration: ProxyConfiguration = ProxyConfiguration(),
        installer: any TrustStoreInstaller = SecurityCommandInstaller(),
        store: TrafficStore = TrafficStore(),
        caDirectory: URL = CertificateAuthority.defaultDirectory
    ) {
        self.configuration = configuration
        self.installer = installer
        self.store = store
        self.caDirectory = caDirectory
    }

    private var pemPath: URL {
        caDirectory.appendingPathComponent("ca.pem")
    }

    /// Cấu hình thật sự đem đi bind.
    ///
    /// Chỉ ghi đè `listenHost` khi toggle BẬT — để một `ProxyConfiguration`
    /// được tiêm vào (test dùng cổng 0, host tuỳ ý) không bị âm thầm mất host
    /// của nó ở trạng thái mặc định.
    /// `internal` chứ không `private` để test khẳng định được host thật sự
    /// đem đi bind, thay vì chỉ khẳng định lại giá trị của toggle.
    var effectiveConfiguration: ProxyConfiguration {
        var config = configuration
        if allowLANDevices { config.listenHost = "0.0.0.0" }
        if forceDecompressible { config.rewriteAcceptEncoding = true }
        return config
    }

    /// Bật/tắt việc cho thiết bị khác trong LAN dùng proxy. Nếu proxy đang
    /// chạy thì restart, vì host bind chỉ được đọc một lần lúc `start()`.
    public func setAllowLANDevices(_ allow: Bool) async {
        guard allow != allowLANDevices else { return }
        allowLANDevices = allow
        await restartIfRunning()
    }

    /// Bật/tắt việc ép server trả về dạng giải nén được.
    public func setForceDecompressible(_ force: Bool) async {
        guard force != forceDecompressible else { return }
        forceDecompressible = force
        await restartIfRunning()
    }

    /// Cả hai cờ trên chỉ được đọc lúc `start()`, nên đổi khi đang chạy thì
    /// phải dựng lại server mới có hiệu lực.
    private func restartIfRunning() async {
        guard isRunning else { return }
        await stop()
        await start()
    }

    /// Văn bản trạng thái sau khi bind thành công.
    ///
    /// Tách khỏi `start()` để test được mà không cần dựng server thật. Khi
    /// bind `0.0.0.0`, hiện IP LAN chứ không hiện `0.0.0.0` — người dùng cần
    /// một con số gõ được vào phần cấu hình proxy của iPhone, và `0.0.0.0`
    /// không phải con số đó.
    static func listeningStatus(host: String, port: Int, lanAddress: String?) -> String {
        guard host == "0.0.0.0" else { return "Đang nghe ở \(host):\(port)" }
        guard let lanAddress else {
            return "Đang nghe ở mọi interface, cổng \(port) — chưa tìm thấy IP LAN của máy"
        }
        return "Đang nghe ở \(lanAddress):\(port) — thiết bị khác trong LAN dùng được"
    }

    /// IPv4 đầu tiên của một interface đang UP và không phải loopback.
    /// `nil` khi không có (chưa nối mạng).
    static func localNetworkAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            if !text.isEmpty { return text }
        }
        return nil
    }

    public func start() async {
        guard !isRunning else { return }
        // Khai báo NGOÀI `do` để `catch` dọn được nó. `ProxyServer.init` cấp
        // phát một `MultiThreadedEventLoopGroup(numberOfThreads:
        // System.coreCount)` ngay trong init, và NIO KHÔNG dọn group khi
        // deinit — thread của nó là detached và sống tiếp tới khi process
        // chết. Đường thất bại hay gặp nhất là bind hỏng vì port đã bị chiếm,
        // đúng lúc người dùng bấm "Chạy" lại ngay: không shutdown ở đây thì
        // mỗi lần bấm rò rỉ `coreCount` thread vĩnh viễn.
        var allocatedServer: ProxyServer?
        do {
            let authority = try CertificateAuthority.loadOrCreate(in: caDirectory)
            let cache = try LeafCertificateCache(authority: authority)
            let config = effectiveConfiguration
            let server = ProxyServer(configuration: config, leafCache: cache)
            allocatedServer = server
            let port = try await server.start()
            consumeTask = store.consume(server.events)
            self.server = server
            isRunning = true
            statusMessage = Self.listeningStatus(
                host: config.listenHost,
                port: port,
                lanAddress: config.listenHost == "0.0.0.0" ? Self.localNetworkAddress() : nil
            )
        } catch {
            // `nil` khi lỗi xảy ra TRƯỚC lúc dựng server (CA/leaf cache) —
            // lúc đó chưa có group nào để dọn.
            try? await allocatedServer?.shutdown()
            statusMessage = "Không khởi động được: \(error.localizedDescription)"
        }
    }

    public func stop() async {
        guard let server else { return }
        // Đợi shutdown xong RỒI mới hạ `isRunning`: hạ trước, khi hàm này
        // còn đang `await` (tức đã nhường MainActor), sẽ để một `start()`
        // khác chen vào ngay khi `isRunning == false`, cố bind lại đúng port
        // trong lúc channel/group cũ chưa chắc đã đóng xong.
        try? await server.shutdown()
        self.server = nil
        consumeTask?.cancel()
        consumeTask = nil
        isRunning = false
        statusMessage = "Đã dừng"
    }

    /// Kiểm tra CHÍNH cert tại `ca.pem` có đang được hệ thống tin làm root
    /// hay không. Không tạo CA nếu chưa có: `ca.pem` không tồn tại thì
    /// `isInstalled` tự nhiên trả `false`, không cần `loadOrCreate` trước.
    ///
    /// Gọi rõ ràng — lúc view xuất hiện, ngay sau khi `installCertificate()`
    /// xong, hoặc từ một nút refresh nếu có — KHÔNG bao giờ từ `body`.
    public func refreshCertificateStatus() async {
        do {
            certificateInstalled = try await installer.isInstalled(pemPath: pemPath)
        } catch {
            certificateInstalled = nil
            statusMessage = "Không kiểm tra được trạng thái Root CA: \(error.localizedDescription)"
        }
    }

    public func installCertificate() async {
        if let installTask {
            await installTask.value
            return
        }
        let task = Task {
            await self.performInstall()
        }
        installTask = task
        await task.value
        installTask = nil
    }

    private func performInstall() async {
        do {
            // `loadOrCreate` đã ghi `ca.pem` xuống đĩa (sinh mới hoặc đã có
            // sẵn) — không cần gọi `certificatePEM()` sau đó, kết quả sẽ
            // không dùng vào đâu.
            _ = try CertificateAuthority.loadOrCreate(in: caDirectory)
            try await installer.install(pemPath: pemPath)
            statusMessage = "Đã cài Root CA vào System keychain"
        } catch TrustStoreError.cancelled {
            // Phân biệt rõ với thất bại thật: đây là người dùng chủ động bấm
            // Cancel ở hộp thoại xin quyền admin, không phải lỗi.
            statusMessage = "Đã huỷ cài Root CA — bạn đã đóng hộp thoại xin quyền admin"
        } catch {
            statusMessage = "Cài Root CA thất bại: \(error.localizedDescription)"
        }
        await refreshCertificateStatus()
    }
}
