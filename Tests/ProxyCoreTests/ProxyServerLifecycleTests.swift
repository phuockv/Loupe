import Testing
import Foundation
import CertKit
import TrafficModel
@testable import ProxyCore

/// Bug đã sửa: `ProxyServer.shutdown()` từng đóng channel và group nhưng
/// không bao giờ gọi `continuation.finish()`, nên `for await` của bất kỳ
/// consumer nào trên `events` (ví dụ `TrafficStore.consume`) không bao giờ
/// kết thúc — kể cả sau khi server đã dừng hẳn.
@Suite("ProxyServer lifecycle")
struct ProxyServerLifecycleTests {

    private func makeServer() async throws -> ProxyServer {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyServerLifecycleTests-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(
            configuration: config,
            leafCache: try LeafCertificateCache(authority: authority)
        )
        _ = try await server.start()
        return server
    }

    @Test("shutdown() kết thúc continuation, nên for-await tiêu thụ events phải thoát ra")
    func shutdownEndsEventsStream() async throws {
        let server = try await makeServer()

        let consumer = Task<Int, Never> {
            var count = 0
            for await _ in server.events { count += 1 }
            return count
        }

        try await server.shutdown()

        // Nếu continuation.finish() không được gọi ở shutdown(), dòng dưới
        // treo vô thời hạn thay vì trả về — đây chính là hồi quy cần chặn.
        _ = await consumer.value
    }

    @Test("shutdown() vẫn kết thúc continuation dù chưa từng start()/stop() channel")
    func shutdownEndsEventsStreamWithoutPriorChannel() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyServerLifecycleTests-\(UUID().uuidString)")
        let authority = try CertificateAuthority.loadOrCreate(in: dir)
        var config = ProxyConfiguration()
        config.listenPort = 0
        let server = ProxyServer(
            configuration: config,
            leafCache: try LeafCertificateCache(authority: authority)
        )

        let consumer = Task<Int, Never> {
            var count = 0
            for await _ in server.events { count += 1 }
            return count
        }

        try await server.shutdown()
        _ = await consumer.value
    }
}
