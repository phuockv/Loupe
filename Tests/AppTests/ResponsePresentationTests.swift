import Testing
import Foundation
import TrafficModel
@testable import AppCore

/// `ResponsePresentation` là chỗ DUY NHẤT `InspectorView.responseTab` suy luận
/// nên hiện gì cho tab Response — xem doc comment của nó trong
/// `InspectorView.swift`. Test ở đây khẳng định đúng thứ tự ưu tiên
/// `isTunnelled` → response → `.failed` → pending, và đặc biệt là case đã bị
/// bỏ sót ở vòng review đầu: response một phần (`.responseHead` đã tới,
/// `.end` thì không) kèm `state == .failed` — lý do thất bại phải lộ ra
/// CÙNG với response một phần đó, không cái nào được che mất cái kia.
@Suite("ResponsePresentation")
struct ResponsePresentationTests {

    @Test("Tunnelled + completed: kind luôn là .tunnelled dù response có giá trị (ConnectEstablished tổng hợp)")
    func tunnelledCompletedIgnoresSyntheticResponse() {
        let presentation = ResponsePresentation(
            isTunnelled: true,
            state: .completed,
            response: ResponseModel(statusCode: 200, reasonPhrase: "Connection Established")
        )
        #expect(presentation.kind == .tunnelled)
        #expect(presentation.failureReason == nil)
    }

    @Test("Tunnelled + failed: kind vẫn .tunnelled, NHƯNG failureReason lộ ra kèm theo")
    func tunnelledFailedCarriesReason() {
        let presentation = ResponsePresentation(
            isTunnelled: true,
            state: .failed(reason: "tunnel relay hỏng giữa chừng"),
            response: nil
        )
        #expect(presentation.kind == .tunnelled)
        #expect(presentation.failureReason == "tunnel relay hỏng giữa chừng")
    }

    @Test("Không tunnelled, có response, completed: kind .response với đúng status code")
    func normalCompletedResponse() {
        let presentation = ResponsePresentation(
            isTunnelled: false,
            state: .completed,
            response: ResponseModel(statusCode: 204, reasonPhrase: "No Content")
        )
        #expect(presentation.kind == .response(statusCode: 204, reasonPhrase: "No Content"))
        #expect(presentation.failureReason == nil)
    }

    @Test("""
        REGRESSION: response một phần (head đã tới, .end thì không) kèm .failed \
        — kind vẫn .response (không giấu response đã có) VÀ failureReason vẫn lộ ra \
        (không giấu lý do thất bại). Đây đúng kịch bản UpstreamHandler phát \
        .responseHead (body: .none) rồi origin đóng kết nối giữa chừng trước .end.
        """)
    func partialResponseWithFailureShowsBoth() {
        let presentation = ResponsePresentation(
            isTunnelled: false,
            state: .failed(reason: "upstream đóng kết nối giữa chừng"),
            response: ResponseModel(statusCode: 200, reasonPhrase: "OK", body: .none)
        )
        #expect(presentation.kind == .response(statusCode: 200, reasonPhrase: "OK"))
        #expect(presentation.failureReason == "upstream đóng kết nối giữa chừng")
    }

    @Test("Không tunnelled, không có response, failed: kind .failed, failureReason là lý do")
    func failedWithoutResponse() {
        let presentation = ResponsePresentation(
            isTunnelled: false,
            state: .failed(reason: "không nối được upstream"),
            response: nil
        )
        #expect(presentation.kind == .failed)
        #expect(presentation.failureReason == "không nối được upstream")
    }

    @Test("Không tunnelled, không có response, pending: kind .pending, không có failureReason")
    func pendingHasNoReason() {
        let presentation = ResponsePresentation(isTunnelled: false, state: .pending, response: nil)
        #expect(presentation.kind == .pending)
        #expect(presentation.failureReason == nil)
    }
}
