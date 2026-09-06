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
            let server = ProxyServer(configuration: configuration, leafCache: cache)
            allocatedServer = server
            let port = try await server.start()
            consumeTask = store.consume(server.events)
            self.server = server
            isRunning = true
            statusMessage = "Đang nghe ở \(configuration.listenHost):\(port)"
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
