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
