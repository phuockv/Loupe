import Foundation

/// Một nút trong cây JSON để `OutlineGroup` render trong `InspectorView`.
///
/// `parse` trả `nil` cho bất kỳ input nào không phải JSON hợp lệ (kể cả
/// binary tuỳ ý) — view gọi nó chỉ để "thử xem có phải JSON không" và rơi về
/// hiển thị text/binary thô khi trả `nil`, không coi `nil` là lỗi.
public struct JSONNode: Identifiable, Sendable {
    public let id = UUID()
    public let key: String
    public let value: String
    public let children: [JSONNode]?

    public static func parse(_ data: Data) -> JSONNode? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) else { return nil }
        return node(key: "root", from: object)
    }

    private static func node(key: String, from object: Any) -> JSONNode {
        switch object {
        case let dictionary as [String: Any]:
            let children = dictionary.keys.sorted().map {
                node(key: $0, from: dictionary[$0]!)
            }
            return JSONNode(key: key, value: "{\(children.count)}", children: children)

        case let array as [Any]:
            let children = array.enumerated().map { node(key: "[\($0.offset)]", from: $0.element) }
            return JSONNode(key: key, value: "[\(children.count)]", children: children)

        case is NSNull:
            return JSONNode(key: key, value: "null", children: nil)

        // `JSONSerialization` bridge cả `true`/`false` lẫn số nguyên thành
        // `NSNumber` — không tách riêng thì `String(describing:)` của một
        // Bool ra "1"/"0", giống hệt số 1/0 thật, xoá mất sự khác biệt giữa
        // `true` và `1` trên cây hiển thị. `CFBooleanGetTypeID()` là cách
        // đáng tin để phân biệt, vì kiểm tra qua `objCType` ("c" cho cả
        // Bool lẫn một số biểu diễn số nguyên nhỏ) không chắc chắn.
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return JSONNode(key: key, value: number.boolValue ? "true" : "false", children: nil)

        default:
            return JSONNode(key: key, value: String(describing: object), children: nil)
        }
    }
}
