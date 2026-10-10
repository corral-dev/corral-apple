import Foundation
import Compression

/// 中继层帧 + 应用层 JSON 消息，与 Python `corral.remote.protocol` 对齐。
///
/// 中继只看 `[类型][16 字节通道][载荷]` 做路由；载荷解密后才是 JSON 业务消息。
nonisolated enum WireProtocol {
    static let frameVersion: UInt8 = 2
    static let subprotocol = "corral.v2"

    // MARK: - 中继层帧类型

    static let frameData: UInt8 = 0x10
    static let frameDeviceOpen: UInt8 = 0x01
    static let frameDeviceClose: UInt8 = 0x02
    static let frameHello: UInt8 = 0x03
    static let framePing: UInt8 = 0x04
    static let framePong: UInt8 = 0x05
    static let framePush: UInt8 = 0x06
    static let frameRegistered: UInt8 = 0x07

    static let channelIDLength = 16
    static let maxFrameBytes = 8 * 1024 * 1024
    static let messagePageLimit = 80
    static let zeroChannel = Data(repeating: 0, count: channelIDLength)

    // MARK: - 方法名

    static let mHello = "hello"
    static let mPair = "pair"
    static let mPushRegister = "push.register"

    static let mSessionsList = "sessions.list"
    static let mSessionsWatch = "sessions.watch"
    static let mSessionsUnwatch = "sessions.unwatch"
    static let mSessionGet = "session.get"
    static let mSessionMessages = "session.messages"
    static let mSessionToolDetail = "session.toolDetail"
    static let mSessionWatch = "session.watch"
    static let mSessionUnwatch = "session.unwatch"
    static let mSessionMarkRead = "session.markRead"
    static let mSessionPrompts = "session.prompts"
    /// Read-only: every human prompt of the session, oldest first (`user_prompts` capability).
    static let mSessionUserPrompts = "session.userPrompts"
    /// Read-only: bounded preview of an image a message cites (`media_image` capability).
    static let mMediaImage = "media.image"

    static let mScreenWatch = "screen.watch"
    static let mScreenUnwatch = "screen.unwatch"
    static let mScreenScroll = "screen.scroll"
    /// 仅作协议对齐用；手机端禁止调用。服务端收到也会拒绝，不会改桌面窗口尺寸。
    static let mScreenResize = "screen.resize"

    static let mInputText = "input.text"
    static let mInputQuestion = "input.question"
    static let mInputKeys = "input.keys"
    static let mInputImage = "input.image"
    /// Query durable host receipt for a previously sent `command_id`.
    static let mCommandStatus = "command.status"

    /// Hello capability key / feature name for durable command receipts.
    static let capabilityCommandReceipts = "command_receipts"
    /// Host omits tool bodies on history wire; fetch via `session.toolDetail`.
    static let capabilityToolDetail = "tool_detail"
    static let capabilityMediaImage = "media_image"

    static let mSessionNew = "session.new"
    static let mSessionResume = "session.resume"
    static let mSessionRestart = "session.restart"
    static let mSessionCopy = "session.copy"
    static let mSessionHandoff = "session.handoff"
    static let mSessionStop = "session.stop"
    static let mSessionDelete = "session.delete"
    static let mSessionPin = "session.pin"
    // Desktop layout: split groups shared with the TUI (Mac client only).
    static let mLayoutWatch = "layout.watch"
    static let mLayoutUnwatch = "layout.unwatch"
    static let mLayoutSetGroup = "layout.setGroup"
    static let mLayoutRemoveSession = "layout.removeSession"
    static let mLayoutSetFocus = "layout.setFocus"
    static let mLayoutPin = "layout.pin"
    static let mLayoutPinGroup = "layout.pinGroup"
    static let mLayoutCollapse = "layout.collapse"
    /// `{group_id, name}`; an empty name restores the automatic name.
    static let mLayoutRenameGroup = "layout.renameGroup"
    // Desktop terminal: raw pane output for a local emulator, sized like a TUI window.
    static let mTerminalAttach = "terminal.attach"
    static let mTerminalResize = "terminal.resize"
    static let mTerminalResync = "terminal.resync"
    static let mTerminalInput = "terminal.input"
    static let mTerminalDetach = "terminal.detach"
    /// `{key, background, foreground}` (`#rrggbb`): colours the host answers to the agent's queries.
    static let mTerminalTheme = "terminal.theme"

    // Project terminal: host login shells; their screens use terminal.* with `shell:<id>` keys.
    static let mShellList = "shell.list"
    static let mShellOpen = "shell.open"
    static let mShellClose = "shell.close"

    static let mProjectsList = "projects.list"
    static let mSearch = "search"
    /// Conversation-body search with hit lines (desktop clients).
    static let mSearchFulltext = "search.fulltext"
    static let mRuntimesList = "runtimes.list"

    static let chSessions = "sessions"
    static let chLayout = "layout"

    static func screenChannel(sessionKey: String) -> String { "screen:\(sessionKey)" }
    static func sessionChannel(sessionKey: String) -> String { "session:\(sessionKey)" }
    static func terminalChannel(sessionKey: String) -> String { "term:\(sessionKey)" }

    // MARK: - 错误码

    static let eUsage = "usage_error"
    static let eNotFound = "not_found"
    static let eUnauthorized = "unauthorized"
    static let eUnavailable = "unavailable"
    static let eInternal = "internal_error"
    static let eRateLimited = "rate_limited"

    // MARK: - 控制/数据双连接

    static let planeControl = "control"
    static let planeData = "data"
    static let wantDataPlaneKey = "want_data_plane"
    static let wantCommandReceiptsKey = "want_command_receipts"

    /// 历史页与终端帧走数据面；其余走控制面。未附着数据面时全部走唯一连接。
    static let dataPlaneMethods: Set<String> = [
        mSessionMessages,
        mSessionUserPrompts,
        mMediaImage,
        mSessionGet,
        mSessionWatch,
        mScreenWatch,
        mScreenScroll,
    ]

    /// Top-level request field naming this app process. The host keeps one
    /// control plane per (device key, instance), so two copies of the app on one
    /// machine coexist instead of evicting each other.
    static let clientInstanceKey = "ci"

    static func controlHelloParams(name: String) -> [String: Any] {
        [
            "name": name,
            "want_data_plane": true,
            // Opt in to durable input receipts when the host advertises command_receipts.
            "want_command_receipts": true,
        ]
    }

    static func dataHelloParams(bind: String, name: String) -> [String: Any] {
        ["plane": planeData, "bind": bind, "name": name]
    }

    static func shouldAttachDataPlane(dataBind: String?) -> Bool {
        guard let dataBind else { return false }
        return !dataBind.isEmpty
    }

    static func usesDataPlane(_ method: String) -> Bool {
        dataPlaneMethods.contains(method)
    }

    static func dataBind(fromHelloPayload payload: Any) -> String? {
        guard let dict = payload as? [String: Any] else { return nil }
        if let bind = dict["data_bind"] as? String, !bind.isEmpty {
            return bind
        }
        return nil
    }

    /// Whether hello advertised durable command receipts (`command_receipts`).
    /// Parsed from loosely typed JSON so this stays usable from nonisolated protocol helpers.
    static func supportsCommandReceipts(fromHelloPayload payload: Any) -> Bool {
        capabilityFlag(capabilityCommandReceipts, fromHelloPayload: payload)
    }

    /// Whether hello advertised message image previews (`media_image`).
    static func supportsMediaImage(fromHelloPayload payload: Any) -> Bool {
        capabilityFlag(capabilityMediaImage, fromHelloPayload: payload)
    }

    /// Whether hello advertised on-demand tool bodies (`tool_detail`).
    static func supportsToolDetail(fromHelloPayload payload: Any) -> Bool {
        capabilityFlag(capabilityToolDetail, fromHelloPayload: payload)
    }

    private static func capabilityFlag(_ name: String, fromHelloPayload payload: Any) -> Bool {
        guard let dict = payload as? [String: Any] else { return false }
        guard let caps = dict["capabilities"] else { return false }
        if let cdict = caps as? [String: Any] {
            if let flag = cdict[name] as? Bool {
                return flag
            }
            if let features = cdict["features"] as? [String] {
                return features.contains(name)
            }
            if let list = cdict[name] as? [Any] {
                return !list.isEmpty
            }
            return false
        }
        if let list = caps as? [String] {
            return list.contains(name)
        }
        return false
    }
}

enum WireProtocolError: Error, Sendable {
    case invalidFrame(String)
    case invalidMessage(String)
}

// MARK: - 帧编解码

nonisolated enum WireFrame {
    static func encode(type: UInt8, channelID: Data, payload: Data = Data()) throws -> Data {
        guard channelID.count == WireProtocol.channelIDLength else {
            throw WireProtocolError.invalidFrame("通道标识长度不合法")
        }
        var frame = Data([WireProtocol.frameVersion, type])
        frame.append(channelID)
        frame.append(payload)
        return frame
    }

    static func decode(_ raw: Data) throws -> (type: UInt8, channelID: Data, payload: Data) {
        guard raw.count >= 2 + WireProtocol.channelIDLength else {
            throw WireProtocolError.invalidFrame("帧过短")
        }
        guard raw.count <= WireProtocol.maxFrameBytes else {
            throw WireProtocolError.invalidFrame("帧过大")
        }
        guard raw[0] == WireProtocol.frameVersion else {
            throw WireProtocolError.invalidFrame("帧版本不是 v2")
        }
        let type = raw[1]
        let channelStart = 2
        let channelEnd = channelStart + WireProtocol.channelIDLength
        let channelID = raw[channelStart ..< channelEnd]
        let payload = raw[channelEnd...]
        return (type, Data(channelID), Data(payload))
    }
}

// MARK: - JSON 消息

nonisolated enum WireMessage {
    private static let payloadMagic: [UInt8] = [0x43, 0x52] // CR
    private static let payloadVersion: UInt8 = 1
    private static let codecNone: UInt8 = 0
    private static let codecDeflate: UInt8 = 1
    private static let payloadHeaderBytes = 8
    private static let compressionThreshold = 1024
    static let maxUncompressedBytes = 4 * 1024 * 1024

    static func dumps(_ message: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw WireProtocolError.invalidMessage("消息不是合法 JSON 对象")
        }
        // 紧凑 JSON，与 Python `json.dumps(..., separators=(",", ":"))` 体积口径一致。
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        guard data.count <= maxUncompressedBytes else {
            throw WireProtocolError.invalidMessage("消息未压缩体积过大")
        }
        return data
    }

    static func loads(_ raw: Data) throws -> [String: Any] {
        guard raw.count <= maxUncompressedBytes else {
            throw WireProtocolError.invalidMessage("消息未压缩体积过大")
        }
        let value = try JSONSerialization.jsonObject(with: raw)
        guard let dict = value as? [String: Any] else {
            throw WireProtocolError.invalidMessage("消息顶层必须是对象")
        }
        return dict
    }

    /// `deflate` 编码使用 raw DEFLATE（RFC 1951）。Apple 的 `COMPRESSION_ZLIB`
    /// 名称带 zlib，实际输出没有 0x78 包装头；开发机侧同样使用 `wbits=-15`。
    static func pack(_ message: [String: Any], compression: Bool = false) throws -> Data {
        let raw = try dumps(message)
        guard compression, raw.count >= compressionThreshold else { return raw }
        let encoded = try deflate(raw)
        guard encoded.count + payloadHeaderBytes < raw.count else { return raw }

        var packed = Data(payloadMagic)
        packed.append(contentsOf: [payloadVersion, codecDeflate])
        packed.append(UInt8((raw.count >> 24) & 0xff))
        packed.append(UInt8((raw.count >> 16) & 0xff))
        packed.append(UInt8((raw.count >> 8) & 0xff))
        packed.append(UInt8(raw.count & 0xff))
        packed.append(encoded)
        return packed
    }

    static func unpack(_ raw: Data) throws -> [String: Any] {
        guard raw.count >= 2, raw[0] == payloadMagic[0], raw[1] == payloadMagic[1] else {
            return try loads(raw)
        }
        guard raw.count >= payloadHeaderBytes else {
            throw WireProtocolError.invalidMessage("压缩载荷头不完整")
        }
        guard raw[2] == payloadVersion else {
            throw WireProtocolError.invalidMessage("压缩载荷版本不支持")
        }
        let expected = (Int(raw[4]) << 24)
            | (Int(raw[5]) << 16)
            | (Int(raw[6]) << 8)
            | Int(raw[7])
        guard expected <= maxUncompressedBytes else {
            throw WireProtocolError.invalidMessage("解压后消息过大")
        }
        let body = Data(raw.dropFirst(payloadHeaderBytes))
        let decoded: Data
        switch raw[3] {
        case codecNone:
            decoded = body
        case codecDeflate:
            decoded = try inflate(body, expectedCount: expected)
        default:
            throw WireProtocolError.invalidMessage("压缩算法不支持")
        }
        guard decoded.count == expected else {
            throw WireProtocolError.invalidMessage("解压后长度不匹配")
        }
        return try loads(decoded)
    }

    static func request(
        id: Int,
        method: String,
        params: [String: Any] = [:],
        caps: [String: Any] = [:]
    ) -> [String: Any] {
        var message: [String: Any] = ["t": "req", "id": id, "m": method, "p": params]
        if !caps.isEmpty { message["caps"] = caps }
        return message
    }

    static func response(id: Int, data: Any) -> [String: Any] {
        ["t": "res", "id": id, "ok": true, "d": data]
    }

    static func error(id: Int, code: String, message: String, hint: String = "") -> [String: Any] {
        var payload: [String: Any] = ["code": code, "message": message]
        if !hint.isEmpty { payload["hint"] = hint }
        return ["t": "res", "id": id, "ok": false, "e": payload]
    }

    static func event(channel: String, data: Any) -> [String: Any] {
        ["t": "evt", "c": channel, "d": data]
    }

    private static func deflate(_ data: Data) throws -> Data {
        var capacity = max(data.count + 64, data.count + data.count / 4)
        for _ in 0..<5 {
            var output = Data(count: capacity)
            let count = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        destinationBase,
                        destination.count,
                        sourceBase,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if count > 0 {
                output.removeSubrange(count..<output.count)
                return output
            }
            capacity *= 2
        }
        throw WireProtocolError.invalidMessage("压缩消息失败")
    }

    private static func inflate(_ data: Data, expectedCount: Int) throws -> Data {
        guard expectedCount > 0 else {
            guard data.isEmpty else { throw WireProtocolError.invalidMessage("压缩载荷长度不匹配") }
            return Data()
        }
        let raw = zlibUnwrapped(data)
        var output = Data(count: expectedCount)
        let count = output.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    raw.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard count == expectedCount else {
            throw WireProtocolError.invalidMessage("压缩载荷解压失败")
        }
        return output
    }

    /// Apple `COMPRESSION_ZLIB` 吃 raw DEFLATE。若对端误发 RFC 1950 包装，先剥掉头尾。
    private static func zlibUnwrapped(_ data: Data) -> Data {
        guard data.count >= 6,
              data[0] & 0x0f == 0x08,
              (Int(data[0]) * 256 + Int(data[1])) % 31 == 0 else {
            return data
        }
        return Data(data.dropFirst(2).dropLast(4))
    }
}

/// 远程调用返回的结构化错误。
struct RemoteCallError: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let hint: String

    var errorDescription: String? { message }
}

nonisolated extension RemoteCallError {
    init?(from message: [String: Any]) {
        guard let error = message["e"] as? [String: Any] else { return nil }
        code = error["code"] as? String ?? WireProtocol.eInternal
        self.message = error["message"] as? String ?? String(localized: String.LocalizationValue("error.unknown"))
        hint = error["hint"] as? String ?? ""
    }
}
