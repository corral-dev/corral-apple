import Foundation

// MARK: - 终端画面

nonisolated struct ScreenFrame: Codable, Sendable, Equatable {
    let cols: Int
    let rows: Int
    let full: Bool
    /// 每行 `[行号, 文本, [[起始, 结束, 前景, 背景, 属性], ...]]`。
    let lines: [[JSONValue]]
    let cursor: [Int]
    let history: [Int]
    let status: String

    var cursorX: Int { cursor.count > 0 ? cursor[0] : 0 }
    var cursorY: Int { cursor.count > 1 ? cursor[1] : 0 }
    var cursorVisible: Bool { cursor.count > 2 ? cursor[2] != 0 : false }
    var historySize: Int { history.count > 0 ? history[0] : 0 }
    var historyOffset: Int { history.count > 1 ? history[1] : 0 }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cols = max(1, container.decodeFlexibleInt(forKey: .cols, default: 80))
        rows = max(1, container.decodeFlexibleInt(forKey: .rows, default: 24))
        full = container.decodeFlexibleBool(forKey: .full)
        // 坏行跳过，避免半屏差分把整帧丢掉。
        if let wrapped = try? container.decodeIfPresent([FailableDecodable<[JSONValue]>].self, forKey: .lines) {
            lines = wrapped.compactMap(\.value)
        } else {
            lines = []
        }
        if let values = try? container.decodeIfPresent([FailableDecodable<Int>].self, forKey: .cursor) {
            let ints = values.compactMap(\.value)
            cursor = ints.isEmpty ? [0, 0, 0] : ints
        } else {
            cursor = [0, 0, 0]
        }
        if let values = try? container.decodeIfPresent([FailableDecodable<Int>].self, forKey: .history) {
            let ints = values.compactMap(\.value)
            history = ints.isEmpty ? [0, 0] : ints
        } else {
            history = [0, 0]
        }
        status = container.decodeFlexibleString(forKey: .status)
    }

    private enum CodingKeys: String, CodingKey {
        case cols, rows, full, lines, cursor, history, status
    }
}

/// 用于 ScreenFrame.lines 等半结构化 JSON 数组。
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case int(Int)
    case string(String)
    case array([JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .string("")
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            // JSON 数字经 Any 往返时常变成 Double；行号/颜色索引按整型用。
            self = .int(Int(value))
        } else if let value = try? container.decode(Bool.self) {
            self = .int(value ? 1 : 0)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            // 未知类型降级为空串，避免整帧失败。
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        }
    }
}
