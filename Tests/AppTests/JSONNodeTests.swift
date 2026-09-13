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

@Suite("JSON in đẹp")
struct JSONPrettyPrintTests {

    @Test("Object nhỏ gọn thành nhiều dòng có thụt lề")
    func expandsCompactObject() throws {
        let pretty = try #require(JSONNode.prettyPrinted(Data(#"{"a":1,"b":2}"#.utf8)))
        #expect(pretty.contains("\n"), "phải xuống dòng, không còn một dòng dính liền")
        #expect(pretty.contains("  "), "phải có thụt lề")
        #expect(pretty.contains("\"a\" : 1") || pretty.contains("\"a\": 1"))
    }

    @Test("Mảng lồng nhau in ra được, không mất phần tử")
    func keepsEveryElement() throws {
        let json = #"[{"id":1},{"id":2},{"id":3}]"#
        let pretty = try #require(JSONNode.prettyPrinted(Data(json.utf8)))
        for id in ["1", "2", "3"] { #expect(pretty.contains(id)) }
    }

    @Test("Không escape dấu gạch chéo trong URL — /api/v1 chứ không \\/api\\/v1")
    func doesNotEscapeSlashes() throws {
        let pretty = try #require(JSONNode.prettyPrinted(Data(#"{"u":"/api/v1"}"#.utf8)))
        #expect(pretty.contains("/api/v1"))
        #expect(!pretty.contains("\\/"))
    }

    @Test("Không phải JSON thì trả nil để view rơi về chế độ Thô")
    func returnsNilForNonJSON() {
        #expect(JSONNode.prettyPrinted(Data("<html></html>".utf8)) == nil)
    }

    @Test("Giữ nguyên giá trị boolean, không biến thành 1/0")
    func keepsBooleansAsBooleans() throws {
        let pretty = try #require(JSONNode.prettyPrinted(Data(#"{"ok":true,"no":false}"#.utf8)))
        #expect(pretty.contains("true"))
        #expect(pretty.contains("false"))
        #expect(!pretty.contains(": 1"))
    }
}
