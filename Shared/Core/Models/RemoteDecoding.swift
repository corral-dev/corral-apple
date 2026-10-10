import CoreFoundation
import Foundation

// MARK: - 泛型解码辅助

/// 单元素解码失败时吞掉，供数组「尽量多拿」使用。
nonisolated struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

nonisolated enum RemoteJSONDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let normalized = normalizeJSON(value)
        let data = try JSONSerialization.data(withJSONObject: normalized)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Same as `decode`, on the concurrent executor: a history page or session list
    /// costs several milliseconds to normalize and decode and must not hold the UI thread.
    @concurrent
    static func decodeOffMain<T: Decodable & Sendable>(_ type: T.Type, from value: JSONValueBox) async throws -> T {
        try decode(type, from: value.value)
    }

    /// 把 JSONSerialization 产出的 NSNumber 尽量收成 Int，减少 Int 字段被写成 `1.0` 后解码失败。
    private static func normalizeJSON(_ value: Any) -> Any {
        switch value {
        case let number as NSNumber:
            // Bool 也是 NSNumber，必须先排除。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded() == doubleValue,
               doubleValue >= Double(Int.min),
               doubleValue <= Double(Int.max) {
                return Int(doubleValue)
            }
            return doubleValue
        case let dict as [String: Any]:
            return dict.mapValues { normalizeJSON($0) }
        case let array as [Any]:
            return array.map { normalizeJSON($0) }
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }
}

/// Immutable Foundation JSON object (`JSONSerialization` output) handed to a decoder
/// on another executor. Nothing mutates these trees after unpacking.
nonisolated struct JSONValueBox: @unchecked Sendable {
    let value: Any
}

// MARK: - KeyedDecodingContainer 宽松取值

// A missing or null key short-circuits to the default: each failed `try?` below
// builds a DecodingError, and a cascade of four per absent field dominated decoding.
nonisolated extension KeyedDecodingContainer {
    private func isAbsentOrNull(_ key: Key) -> Bool {
        !contains(key) || (try? decodeNil(forKey: key)) == true
    }

    func decodeFlexibleString(forKey key: Key, default defaultValue: String = "") -> String {
        if isAbsentOrNull(key) { return defaultValue }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        if let value = try? decode(Bool.self, forKey: key) { return value ? "true" : "false" }
        return defaultValue
    }

    func decodeFlexibleOptionalString(forKey key: Key) -> String? {
        guard !isAbsentOrNull(key) else { return nil }
        let value = decodeFlexibleString(forKey: key)
        return value
    }

    func decodeFlexibleBool(forKey key: Key, default defaultValue: Bool = false) -> Bool {
        if isAbsentOrNull(key) { return defaultValue }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(Double.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on": return true
            case "0", "false", "no", "n", "off", "": return false
            default: return defaultValue
            }
        }
        return defaultValue
    }

    func decodeFlexibleInt(forKey key: Key, default defaultValue: Int = 0) -> Int {
        if isAbsentOrNull(key) { return defaultValue }
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? decode(String.self, forKey: key), let parsed = Int(value) { return parsed }
        if let value = try? decode(Bool.self, forKey: key) { return value ? 1 : 0 }
        return defaultValue
    }

    func decodeFlexibleDouble(forKey key: Key, default defaultValue: Double = 0) -> Double {
        if isAbsentOrNull(key) { return defaultValue }
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? decode(String.self, forKey: key), let parsed = Double(value) { return parsed }
        return defaultValue
    }
}
