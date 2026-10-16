import Foundation

// MARK: - 开发机信息

nonisolated struct HostInfo: Codable, Sendable, Identifiable, Equatable, Hashable {
    let hostID: String
    var name: String
    /// 本机自定义别名：用户在手机设置页单独改的名字，优先于开发机下发的 `name` 显示。
    /// 服务端不存它；`hello.host_name` 变化只在别名未设置时更新 `name`。
    var customName: String?
    let publicKeyHex: String
    var relayURL: String?
    var localHints: [String]
    /// Last LAN endpoint that actually won a race (`ip:port`). Tried first next time.
    var lastLocalHint: String?
    var pairedAt: Date

    /// 界面实际显示的开发机名：本地别名优先，否则用开发机下发的默认名。
    var displayName: String {
        let trimmed = (customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    /// Apply freshly discovered `local_hints` (hello is authoritative).
    ///
    /// Replaces the stored list with the fresh snapshot (capped), keeping
    /// `lastLocalHint` first when still present so the next race stays sticky.
    func applyingFreshLocalHints(_ hints: [String], cap: Int = 12) -> HostInfo {
        let fresh = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var merged: [String] = []
        var seen = Set<String>()
        if let last = lastLocalHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !last.isEmpty,
           fresh.contains(last) || fresh.isEmpty
        {
            merged.append(last)
            seen.insert(last)
        }
        for hint in fresh {
            guard seen.insert(hint).inserted else { continue }
            merged.append(hint)
            if merged.count >= max(cap, 1) { break }
        }
        var copy = self
        copy.localHints = merged
        return copy
    }

    /// Merge discovered hints (Bonjour / opportunistic). Prefer `applyingFreshLocalHints`
    /// for hello — that path replaces rather than growing forever.
    func mergingLocalHints(_ hints: [String], cap: Int = 12) -> HostInfo {
        applyingFreshLocalHints(hints + localHints, cap: cap)
    }

    var id: String { hostID }

    init(
        hostID: String,
        name: String,
        customName: String? = nil,
        publicKeyHex: String,
        relayURL: String? = nil,
        localHints: [String] = [],
        lastLocalHint: String? = nil,
        pairedAt: Date = .now
    ) {
        self.hostID = hostID
        self.name = name
        self.customName = customName
        self.publicKeyHex = publicKeyHex
        self.relayURL = relayURL
        self.localHints = localHints
        self.lastLocalHint = lastLocalHint
        self.pairedAt = pairedAt
    }

    init(from pairing: PairingPayload, pairedAt: Date = .now) {
        hostID = pairing.hostID
        name = pairing.hostName
        customName = nil
        publicKeyHex = pairing.hostPublicKey.map { String(format: "%02x", $0) }.joined()
        relayURL = pairing.relayURL
        localHints = pairing.localHints
        lastLocalHint = pairing.localHints.first
        self.pairedAt = pairedAt
    }

    var publicKeyData: Data? {
        var data = Data(capacity: 32)
        var index = publicKeyHex.startIndex
        while index < publicKeyHex.endIndex {
            let next = publicKeyHex.index(index, offsetBy: 2, limitedBy: publicKeyHex.endIndex) ?? publicKeyHex.endIndex
            guard next <= publicKeyHex.endIndex,
                  let byte = UInt8(publicKeyHex[index ..< next], radix: 16)
            else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == 32 ? data : nil
    }
}

nonisolated struct HelloResponse: Codable, Sendable {
    let protocolVersion: Int?
    let corralVersion: String?
    let hostID: String?
    let hostName: String?
    let access: String?
    var isReadonlyPairing: Bool {
        access?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "readonly"
    }
    let paired: Bool
    let pairingOpen: Bool?
    /// 开发机当前中继地址；未开中继时为空串。手机可据此补全旧配对 Host。
    let relayURL: String?
    let relayEnabled: Bool?
    let localEnabled: Bool?
    /// 开发机当前局域网直连提示（如 `["192.168.1.5:8737"]`）。未配对也返回。
    /// 缺字段为 nil；坏元素在解码时跳过。
    let localHints: [String]?
    /// Host-advertised feature flags from hello `capabilities` (unknown keys ignored).
    let capabilities: HostCapabilities

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case corralVersion = "corral_version"
        case hostID = "host_id"
        case hostName = "host_name"
        case paired, access
        case pairingOpen = "pairing_open"
        case relayURL = "relay_url"
        case relayEnabled = "relay_enabled"
        case localEnabled = "local_enabled"
        case localHints = "local_hints"
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.protocolVersion) {
            protocolVersion = container.decodeFlexibleInt(forKey: .protocolVersion)
        } else {
            protocolVersion = nil
        }
        corralVersion = container.decodeFlexibleOptionalString(forKey: .corralVersion)
        hostID = container.decodeFlexibleOptionalString(forKey: .hostID)
        hostName = container.decodeFlexibleOptionalString(forKey: .hostName)
        access = container.decodeFlexibleOptionalString(forKey: .access)
        paired = container.decodeFlexibleBool(forKey: .paired)
        if container.contains(.pairingOpen) {
            pairingOpen = container.decodeFlexibleBool(forKey: .pairingOpen)
        } else {
            pairingOpen = nil
        }
        if let relay = container.decodeFlexibleOptionalString(forKey: .relayURL), !relay.isEmpty {
            relayURL = relay
        } else {
            relayURL = nil
        }
        if container.contains(.relayEnabled) {
            relayEnabled = container.decodeFlexibleBool(forKey: .relayEnabled)
        } else {
            relayEnabled = nil
        }
        if container.contains(.localEnabled) {
            localEnabled = container.decodeFlexibleBool(forKey: .localEnabled)
        } else {
            localEnabled = nil
        }
        if container.contains(.localHints),
           let raw = try? container.decodeIfPresent([FailableDecodable<String>].self, forKey: .localHints) {
            let hints = raw.compactMap(\.value)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            localHints = hints.isEmpty ? nil : hints
        } else {
            localHints = nil
        }
        if let caps = try? container.decodeIfPresent(HostCapabilities.self, forKey: .capabilities) {
            capabilities = caps
        } else {
            capabilities = .empty
        }
    }
}

/// Subset of hello `capabilities` the phone acts on. Extra host fields are ignored.
nonisolated struct HostCapabilities: Codable, Sendable, Equatable {
    var commandReceipts: Bool
    var sessionCreateReceipts: Bool = false
    var toolDetail: Bool
    var sessionRestart: Bool
    /// Host stops a running turn with the runtime's own key (`session.interrupt`).
    var sessionInterrupt: Bool = false
    /// Host shares the TUI's split groups with desktop clients (`layout.*`).
    var desktopLayout: Bool = false
    /// Host streams raw pane output and takes desktop size votes (`terminal.*`).
    var terminalStream: Bool = false
    var terminalPrompt: Bool = false
    /// Host lists every human prompt of a session (`session.userPrompts`).
    var userPrompts: Bool = false
    /// Host runs project shells for the project terminal (`shell.*`).
    var projectShell: Bool = false

    static let empty = HostCapabilities(commandReceipts: false, toolDetail: false)

    enum CodingKeys: String, CodingKey {
        case commandReceipts = "command_receipts"
        case sessionCreateReceipts = "session_create_receipts"
        case toolDetail = "tool_detail"
        case features
        case sessionRestart = "session_restart"
        case sessionInterrupt = "session_interrupt"
        case desktopLayout = "desktop_layout"
        case terminalStream = "terminal_stream"
        case terminalPrompt = "terminal_prompt"
        case userPrompts = "user_prompts"
        case projectShell = "project_shell"
    }

    init(commandReceipts: Bool, toolDetail: Bool = false, sessionRestart: Bool = false) {
        self.commandReceipts = commandReceipts
        self.toolDetail = toolDetail
        self.sessionRestart = sessionRestart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let features = (try? container.decode([String].self, forKey: .features)) ?? []
        sessionCreateReceipts = (try? container.decode(Bool.self, forKey: .sessionCreateReceipts)) ?? features.contains("session_create_receipts")
        sessionRestart = (try? container.decode(Bool.self, forKey: .sessionRestart)) ?? features.contains("session_restart")
        sessionInterrupt = (try? container.decode(Bool.self, forKey: .sessionInterrupt)) ?? features.contains("session_interrupt")
        desktopLayout = (try? container.decode(Bool.self, forKey: .desktopLayout)) ?? features.contains("desktop_layout")
        terminalPrompt = (try? container.decode(Bool.self, forKey: .terminalPrompt)) ?? features.contains("terminal_prompt")
        terminalStream = (try? container.decode(Bool.self, forKey: .terminalStream)) ?? features.contains("terminal_stream")
        userPrompts = (try? container.decode(Bool.self, forKey: .userPrompts)) ?? features.contains("user_prompts")
        projectShell = (try? container.decode(Bool.self, forKey: .projectShell)) ?? features.contains("project_shell")
        if container.contains(.commandReceipts) {
            if let flag = try? container.decode(Bool.self, forKey: .commandReceipts) {
                commandReceipts = flag
            } else if let list = try? container.decode([String].self, forKey: .commandReceipts) {
                commandReceipts = !list.isEmpty
            } else {
                commandReceipts = false
            }
        } else {
            commandReceipts = features.contains("command_receipts")
        }
        if container.contains(.toolDetail) {
            if let flag = try? container.decode(Bool.self, forKey: .toolDetail) {
                toolDetail = flag
            } else if let list = try? container.decode([String].self, forKey: .toolDetail) {
                toolDetail = !list.isEmpty
            } else {
                toolDetail = false
            }
        } else {
            toolDetail = features.contains("tool_detail")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandReceipts, forKey: .commandReceipts)
        try container.encode(sessionCreateReceipts, forKey: .sessionCreateReceipts)
        try container.encode(toolDetail, forKey: .toolDetail)
        try container.encode(sessionRestart, forKey: .sessionRestart)
        try container.encode(desktopLayout, forKey: .desktopLayout)
        try container.encode(terminalStream, forKey: .terminalStream)
        try container.encode(userPrompts, forKey: .userPrompts)
        try container.encode(projectShell, forKey: .projectShell)
    }
}

/// Host reply shape for `command.status` (and optional receipt fields on `input.*`).
nonisolated struct CommandStatusResponse: Codable, Sendable, Equatable {
    let commandID: String?
    let status: String?
    /// Host-provided human failure text (already localized on the host).
    /// Present on rejected/unknown receipts; nil on delivered/unseen.
    /// Never carries session content — safe to show under the bubble / composer.
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case status
        case detail
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandID = container.decodeFlexibleOptionalString(forKey: .commandID)
        status = container.decodeFlexibleOptionalString(forKey: .status)
        detail = container.decodeFlexibleOptionalString(forKey: .detail)
            ?? container.decodeFlexibleOptionalString(forKey: .message)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(commandID, forKey: .commandID)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    /// Pull status from a loosely typed RPC payload (top-level or nested `receipt`).
    static func statusString(from payload: Any?) -> String? {
        guard let dict = payload as? [String: Any] else { return nil }
        if let status = dict["status"] as? String, !status.isEmpty {
            return status
        }
        if let receipt = dict["receipt"] as? [String: Any],
           let status = receipt["status"] as? String,
           !status.isEmpty {
            return status
        }
        return nil
    }

    /// Pull the full receipt (status + host detail) from a loosely typed RPC payload.
    static func receipt(from payload: Any?) -> CommandStatusResponse? {
        guard let dict = payload as? [String: Any] else { return nil }
        let status = statusString(from: payload)
        let nested = dict["receipt"] as? [String: Any]
        let detail = [dict["detail"], dict["message"], nested?["detail"], nested?["message"]]
            .compactMap { $0 as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard status != nil || detail != nil else { return nil }
        return CommandStatusResponse(commandID: nil, status: status, detail: detail)
    }

    init(commandID: String?, status: String?, detail: String? = nil) {
        self.commandID = commandID
        self.status = status
        self.detail = detail
    }
}

/// A successful RPC envelope may still contain a rejected or ambiguous command receipt.
/// Keep delivery uncertainty separate from an authoritative host refusal.
enum CommandDeliveryError: Error, LocalizedError, Sendable {
    case rejected(String)
    case unconfirmed(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let detail), .unconfirmed(let detail): detail
        }
    }
}
