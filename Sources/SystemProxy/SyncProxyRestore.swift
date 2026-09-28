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
