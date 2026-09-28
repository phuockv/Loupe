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
