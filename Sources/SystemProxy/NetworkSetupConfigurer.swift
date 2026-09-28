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
        let enabled = enabledText.lowercased() == "yes"

        // Khi Enabled: No, `networksetup` hợp lệ in ra `Server: ` (rỗng) và
        // `Port: 0` — đó là input hợp lệ, không phải input hỏng, nên giữ
        // nguyên cách đọc khoan dung cho nhánh này.
        guard enabled else {
            return ProxySetting(
                enabled: false,
                server: field("Server") ?? "",
                port: Int(field("Port") ?? "0") ?? 0
            )
        }

        // Khi Enabled: Yes, Server rỗng/thiếu hoặc Port không phải cổng hợp
        // lệ là output hỏng — không được lặng lẽ rơi về "", 0: giá trị bịa
        // đó sẽ bị ghi vào snapshot làm "nguyên bản", rồi lúc restore phát ra
        // `-setwebproxy <svc> "" 0`, một câu lệnh `networksetup` từ chối.
        guard let server = field("Server"), !server.isEmpty else {
            throw SystemProxyError.unreadableOutput(command: "getwebproxy", output: output)
        }
        guard let portText = field("Port"), let port = Int(portText), (1...65535).contains(port) else {
            throw SystemProxyError.unreadableOutput(command: "getwebproxy", output: output)
        }
        return ProxySetting(enabled: true, server: server, port: port)
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

    /// Trạng thái gốc TẮT thì chỉ gọi `...state off`.
    ///
    /// Không gọi `-setwebproxy <svc> "" 0`: server rỗng và cổng 0 là đối số
    /// không hợp lệ, `networksetup` sẽ báo lỗi. Đường khôi phục mà tự ném lỗi
    /// là đúng cái không được phép hỏng.
    ///
    /// Đúng MỘT field mỗi lần gọi, và KHÔNG BAO GIỜ đụng field kia. Trước đây
    /// hàm này phát lệnh cho cả hai field, kể cả field người dùng vừa tự đổi:
    /// `-setwebproxy <svc> <host> <port>` không mang theo username/password
    /// nên nó xoá sạch credential của một proxy có xác thực — và mỗi lệnh
    /// thừa là thêm một chỗ hỏng được, đúng lúc đang cố cứu mạng cho họ.
    /// Đường đồng bộ (`SyncProxyRestore`) vốn đã không đụng field kia; giờ
    /// hai đường khớp nhau, nên kết quả không còn phụ thuộc app thoát kiểu gì.
    public func restore(_ setting: ProxySetting, field: ProxyField, of service: String) async throws {
        guard setting.enabled else {
            _ = try await runner([Self.binary, field.stateCommand, service, "off"])
            return
        }
        _ = try await runner(
            [Self.binary, field.setCommand, service, setting.server, String(setting.port)])
        _ = try await runner([Self.binary, field.stateCommand, service, "on"])
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
