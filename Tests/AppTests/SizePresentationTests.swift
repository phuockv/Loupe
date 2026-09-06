import Testing
import Foundation
import TrafficModel
@testable import AppCore

/// `SizePresentation` là chỗ DUY NHẤT cột Size suy luận nên hiện gì — xem doc
/// comment của nó trong `ContentView.swift`.
///
/// Bất biến mà cả bộ test này bảo vệ: cột Size KHÔNG BAO GIỜ được in ra một
/// con số cho một dòng mà proxy không đo được. Bản trước dùng
/// `response?.body.totalBytes ?? 0` và `ByteCountFormatter` biến số 0 đó thành
/// "Zero bytes" — một khẳng định sai về dây — cho MỌI dòng CONNECT (cả tunnel
/// mù đã relay megabyte lẫn phiên MitM) và cho mọi transaction chết giữa body.
@Suite("SizePresentation")
struct SizePresentationTests {

    private func makeTransaction(
        method: String = "GET",
        isTunnelled: Bool = false,
        state: TransactionState = .completed,
        response: ResponseModel? = nil,
        bytesSent: Int = 0,
        bytesReceived: Int = 0
    ) -> Transaction {
        var transaction = Transaction(
            scheme: .https, host: "example.com", port: 443,
            request: RequestModel(method: method,
                                  url: URL(string: "https://example.com/a")!),
            state: state,
            isTunnelled: isTunnelled
        )
        transaction.response = response
        transaction.bytesSent = bytesSent
        transaction.bytesReceived = bytesReceived
        return transaction
    }

    @Test("Response đã thu trọn: hiện đúng số byte của body")
    func completedResponseShowsBodySize() {
        let transaction = makeTransaction(
            response: ResponseModel(statusCode: 200, reasonPhrase: "OK",
                                    body: .inMemory(Data(repeating: 0x41, count: 1234)))
        )
        #expect(SizePresentation(transaction: transaction).kind == .responseBody(bytes: 1234))
    }

    @Test("Body đã spill ra đĩa: dùng totalBytes thật, không phải kích thước phần giữ trong RAM")
    func spilledBodyUsesTotalBytes() {
        let transaction = makeTransaction(
            response: ResponseModel(statusCode: 200, reasonPhrase: "OK",
                                    body: .file(URL(fileURLWithPath: "/tmp/x"),
                                                totalBytes: 9_000_000))
        )
        #expect(SizePresentation(transaction: transaction).kind
                == .responseBody(bytes: 9_000_000))
    }

    @Test("Body chỉ giữ được phần đầu (.truncated): totalBytes vẫn là con số thật trên dây")
    func truncatedBodyUsesRealTotal() {
        let transaction = makeTransaction(
            response: ResponseModel(statusCode: 200, reasonPhrase: "OK",
                                    body: .truncated(Data(repeating: 0x41, count: 16),
                                                     totalBytes: 5_000))
        )
        #expect(SizePresentation(transaction: transaction).kind == .responseBody(bytes: 5_000))
    }

    /// Ca thứ nhất của lỗi "Zero bytes": dòng CONNECT của một phiên MitM mang
    /// response `200 Connection Established` tổng hợp với body `.none`. Nội
    /// dung thật của phiên nằm ở các dòng con đã giải mã, không ở dòng này.
    @Test("Dòng CONNECT của phiên MitM: không biết kích thước, KHÔNG được in ra 0")
    func mitmConnectRowIsUnknown() {
        let transaction = makeTransaction(
            method: "CONNECT",
            response: ResponseModel(statusCode: 200, reasonPhrase: "Connection Established",
                                    headers: [(name: "Content-Length", value: "0")],
                                    body: .none)
        )
        #expect(SizePresentation(transaction: transaction).kind == .unknown)
    }

    /// Ca thứ hai: `.responseHead` đã tới rồi origin đóng giữa body. Bản ghi
    /// có response nhưng body chưa bao giờ được thu — 0 ở đây là "chưa đo
    /// được", không phải "response rỗng".
    @Test("Response một phần rồi thất bại: không biết kích thước, KHÔNG được in ra 0")
    func partialResponseThenFailureIsUnknown() {
        let transaction = makeTransaction(
            state: .failed(reason: "upstream đóng kết nối giữa chừng"),
            response: ResponseModel(statusCode: 200, reasonPhrase: "OK", body: .none)
        )
        #expect(SizePresentation(transaction: transaction).kind == .unknown)
    }

    @Test("Chưa có response nào: không biết kích thước")
    func pendingTransactionIsUnknown() {
        let transaction = makeTransaction(state: .pending, response: nil)
        #expect(SizePresentation(transaction: transaction).kind == .unknown)
    }

    /// Ca thứ ba, và là ca tệ nhất của lỗi cũ: một tunnel mù đã chở megabyte
    /// nhưng response tổng hợp của nó có body `.none`.
    @Test("Tunnel mù đã đóng: hiện byte THẬT đã relay, cả hai chiều")
    func closedTunnelShowsRelayedBytes() {
        let transaction = makeTransaction(
            method: "CONNECT", isTunnelled: true,
            response: ResponseModel(statusCode: 200, reasonPhrase: "Connection Established",
                                    body: .none),
            bytesSent: 4_096, bytesReceived: 8_388_608
        )
        #expect(SizePresentation(transaction: transaction).kind
                == .relayedThroughTunnel(sent: 4_096, received: 8_388_608))
    }

    /// Tunnel đang chạy: byte đang chảy nhưng `.bytesRelayed` chỉ được phát
    /// lúc đóng, nên hai bộ đếm còn là 0. Hiện "0 byte" ở đây là in một khẳng
    /// định sai lên một tunnel đang tải dở.
    @Test("Tunnel còn đang chạy: chưa ai báo byte nào, phải là chưa biết chứ không phải 0")
    func runningTunnelIsUnknown() {
        let transaction = makeTransaction(method: "CONNECT", isTunnelled: true,
                                          state: .pending, response: nil)
        #expect(SizePresentation(transaction: transaction).kind == .unknown)
    }

    @Test("Tunnel hỏng trước khi chở được byte nào: vẫn là chưa biết, không phải 0")
    func failedEmptyTunnelIsUnknown() {
        let transaction = makeTransaction(
            method: "CONNECT", isTunnelled: true,
            state: .failed(reason: "tunnel không nối được"), response: nil
        )
        #expect(SizePresentation(transaction: transaction).kind == .unknown)
    }
}
