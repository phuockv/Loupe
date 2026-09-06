import Testing
import Foundation
@testable import AppCore

/// `JSONNode` là cây thuần logic cho `OutlineGroup` trong `InspectorView`
/// render — không có harness test cho SwiftUI view trong package này, nên
/// mọi quyết định hiển thị nằm ở đây, xem `InspectorView.swift`.
@Suite("JSONNode")
struct JSONNodeTests {

    @Test("Object thành node có con, sắp theo key")
    func parsesObject() throws {
        let data = Data(#"{"b": 2, "a": 1}"#.utf8)
        let root = try #require(JSONNode.parse(data))
        #expect(root.children?.map(\.key) == ["a", "b"])
    }

    @Test("Array đánh index làm key")
    func parsesArray() throws {
        let data = Data(#"[10, 20]"#.utf8)
        let root = try #require(JSONNode.parse(data))
        #expect(root.children?.map(\.key) == ["[0]", "[1]"])
        #expect(root.children?.first?.value == "10")
    }

    @Test("Lồng nhau giữ đúng cấu trúc cây")
    func parsesNested() throws {
        let data = Data(#"{"user": {"name": "Phuoc"}}"#.utf8)
        let root = try #require(JSONNode.parse(data))
        let user = try #require(root.children?.first)
        #expect(user.key == "user")
        #expect(user.children?.first?.value == "Phuoc")
    }

    @Test("Không phải JSON thì trả nil để view rơi về plain text")
    func returnsNilForNonJSON() {
        #expect(JSONNode.parse(Data("khong phai json".utf8)) == nil)
    }

    // `JSONSerialization` bridge `true`/`false` thành `NSNumber` (cụ thể là
    // `__NSCFBoolean`); `String(describing:)` trên nó ra "1"/"0", giống hệt
    // số nguyên 1/0 — người dùng nhìn cây JSON sẽ không phân biệt được
    // `"active": true` với `"active": 1`. Phải nhận diện Bool riêng.
    @Test("Boolean hiện đúng true/false, không lẫn với số 1/0")
    func rendersBooleanNotOneZero() throws {
        let data = Data(#"{"active": true, "inactive": false, "count": 1}"#.utf8)
        let root = try #require(JSONNode.parse(data))
        let children = try #require(root.children)
        #expect(children.first(where: { $0.key == "active" })?.value == "true")
        #expect(children.first(where: { $0.key == "inactive" })?.value == "false")
        #expect(children.first(where: { $0.key == "count" })?.value == "1")
    }

    @Test("null hiện thành chữ null")
    func rendersNull() throws {
        let data = Data(#"{"missing": null}"#.utf8)
        let root = try #require(JSONNode.parse(data))
        #expect(root.children?.first?.value == "null")
    }
}
