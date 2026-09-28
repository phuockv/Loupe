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

    /// - Returns: true nếu có dọn gì đó — tức có ít nhất một lệnh set/state
    ///   thực sự được phát ra. Snapshot tồn tại và đọc được nhưng không dịch
    ///   vụ nào còn trỏ vào ta (người dùng đã tự đổi hết) thì trả về false.
    @discardableResult
    public static func restoreNow(
        storeURL: URL,
        runSync: SyncRunner? = nil
    ) -> Bool {
        // `runSync` mặc định `nil` — một literal, không tham chiếu gì cả —
        // để giữ `NetworkSetupConfigurer.runProcessSync` là internal. Tham
        // chiếu nó ngay trong biểu thức mặc định của một khai báo public sẽ
        // buộc nó phải public theo cùng mức, dù chẳng có nơi gọi nào bên
        // ngoài module cần tới nó.
        let run = runSync ?? { NetworkSetupConfigurer.runProcessSync($0) }

        let store = ProxySnapshotStore(url: storeURL)
        // `try?` trên một biểu thức kiểu `ProxySnapshot?` được Swift làm
        // phẳng thành `ProxySnapshot?`, nên một lần `let` là đủ.
        guard store.exists, let snapshot = try? store.read() else { return false }

        let binary = NetworkSetupConfigurer.binary
        var allSucceeded = true
        var restoredAny = false

        for original in snapshot.services {
            // Cùng luật với đường async (SystemProxyController.restore):
            // đọc CẢ HAI field rồi xét TỪNG FIELD riêng, không gộp OR chung
            // một cổng cho cả dịch vụ. Người dùng thường chỉ đổi một field
            // (vd. tự đặt proxy công ty cho HTTP, để yên HTTPS vẫn trỏ vào
            // ta) — gộp sẽ đạp mất field họ vừa đổi, hoặc bỏ quên field kia
            // làm dấu vết chết vĩnh viễn.
            guard case .success(let webOut) = run([binary, "-getwebproxy", original.service]),
                  let currentWeb = try? NetworkSetupConfigurer.parseProxy(webOut),
                  case .success(let secureOut) = run([binary, "-getsecurewebproxy", original.service]),
                  let currentSecureWeb = try? NetworkSetupConfigurer.parseProxy(secureOut)
            else { allSucceeded = false; continue }

            let webStillOurs = currentWeb.pointsAt(host: snapshot.appliedHost, port: snapshot.appliedPort)
            let secureStillOurs =
                currentSecureWeb.pointsAt(host: snapshot.appliedHost, port: snapshot.appliedPort)
            guard webStillOurs || secureStillOurs else { continue }

            for (stillOurs, setting, setCmd, stateCmd) in [
                (webStillOurs, original.web, "-setwebproxy", "-setwebproxystate"),
                (secureStillOurs, original.secureWeb, "-setsecurewebproxy", "-setsecurewebproxystate"),
            ] {
                // Field không còn trỏ vào ta (người dùng đã tự đổi) thì để
                // yên — không phát lệnh nào cho field đó.
                guard stillOurs else { continue }
                restoredAny = true
                let commands: [[String]] = setting.enabled
                    ? [[binary, setCmd, original.service, setting.server, String(setting.port)],
                       [binary, stateCmd, original.service, "on"]]
                    : [[binary, stateCmd, original.service, "off"]]
                for command in commands {
                    if case .failure = run(command) { allSucceeded = false }
                }
            }
        }

        // Giữ file khi có bất kỳ lệnh nào hỏng: lần mở sau `recoverIfNeeded`
        // sẽ thử lại. Luật khôi phục là idempotent nên thử lại vô hại.
        if allSucceeded { try? store.delete() }
        return restoredAny
    }
}
