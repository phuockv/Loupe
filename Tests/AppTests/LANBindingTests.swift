import Testing
import Foundation
import ProxyCore
@testable import AppCore

/// Toggle "cho thiết bị LAN dùng" và văn bản trạng thái đi kèm.
///
/// Không có test nào ở đây bind ra ngoài loopback: việc bind `0.0.0.0` thật sẽ
/// mở proxy ra mạng của máy chạy test. Thứ được kiểm là QUYẾT ĐỊNH (host nào
/// được chọn, hiện chữ gì), không phải cú bind.
@MainActor
@Suite("Bind LAN")
struct LANBindingTests {

    @Test("Mặc định TẮT — proxy chỉ nghe loopback nếu không ai bật")
    func defaultsToLoopbackOnly() {
        #expect(AppModel().allowLANDevices == false)
    }

    @Test("Tắt: host đem đi bind là loopback")
    func bindsLoopbackWhenOff() {
        #expect(AppModel().effectiveConfiguration.listenHost == "127.0.0.1")
    }

    @Test("Bật: host đem đi bind thành 0.0.0.0")
    func bindsWildcardWhenOn() async {
        let model = AppModel()
        await model.setAllowLANDevices(true)
        #expect(model.effectiveConfiguration.listenHost == "0.0.0.0")
    }

    @Test("Tắt thì KHÔNG ghi đè host được tiêm vào")
    func leavesInjectedHostAloneWhenOff() {
        var config = ProxyConfiguration()
        config.listenHost = "127.0.0.2"
        let model = AppModel(configuration: config)
        #expect(model.effectiveConfiguration.listenHost == "127.0.0.2",
                "config tiêm vào bị nuốt mất host — test dùng host riêng sẽ hỏng âm thầm")
    }

    @Test("Bật rồi tắt lại thì quay về đúng host tiêm vào, không kẹt ở 0.0.0.0")
    func revertsToInjectedHostAfterToggleOff() async {
        var config = ProxyConfiguration()
        config.listenHost = "127.0.0.2"
        let model = AppModel(configuration: config)
        await model.setAllowLANDevices(true)
        #expect(model.effectiveConfiguration.listenHost == "0.0.0.0")
        await model.setAllowLANDevices(false)
        #expect(model.effectiveConfiguration.listenHost == "127.0.0.2")
    }

    @Test("Loopback: status hiện đúng host đang bind")
    func statusShowsLoopbackHostVerbatim() {
        let text = AppModel.listeningStatus(host: "127.0.0.1", port: 9090, lanAddress: "192.168.1.26")
        #expect(text == "Đang nghe ở 127.0.0.1:9090")
    }

    @Test("LAN: status hiện IP LAN chứ KHÔNG hiện 0.0.0.0")
    func statusShowsLANAddressNotWildcard() {
        let text = AppModel.listeningStatus(host: "0.0.0.0", port: 9090, lanAddress: "192.168.1.26")
        #expect(text.contains("192.168.1.26:9090"))
        #expect(!text.contains("0.0.0.0"), "0.0.0.0 không phải con số gõ được vào iPhone")
    }

    @Test("LAN nhưng không tìm được IP: nói thẳng là chưa tìm thấy, không bịa số")
    func statusAdmitsWhenLANAddressUnknown() {
        let text = AppModel.listeningStatus(host: "0.0.0.0", port: 9090, lanAddress: nil)
        #expect(text.contains("9090"))
        #expect(text.contains("chưa tìm thấy"))
    }

    @Test("localNetworkAddress trả về IPv4 hợp lệ hoặc nil, không bao giờ trả loopback")
    func localAddressIsNeverLoopback() {
        guard let address = AppModel.localNetworkAddress() else { return }
        #expect(!address.hasPrefix("127."))
        let parts = address.split(separator: ".")
        #expect(parts.count == 4)
        #expect(parts.allSatisfy { UInt8($0) != nil })
    }
}
