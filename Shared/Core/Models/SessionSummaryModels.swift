import Foundation

// MARK: - 关注状态

nonisolated enum AttentionKind: String, Codable, Sendable, CaseIterable {
    case none
    case unread
    case working
    case waiting
}

// MARK: - 会话摘要

nonisolated struct SessionGroupInfo: Codable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let pinned: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, pinned
    }

    init(id: String, name: String, emoji: String = "", pinned: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 缺 id 时用 name 兜底，避免整条会话因分组字段不完整而解码失败。
        let decodedID = container.decodeFlexibleString(forKey: .id)
        let decodedName = container.decodeFlexibleString(forKey: .name)
        id = decodedID.isEmpty ? decodedName : decodedID
        name = decodedName.isEmpty ? id : decodedName
        emoji = container.decodeFlexibleString(forKey: .emoji)
        pinned = container.decodeFlexibleBool(forKey: .pinned)
        if id.isEmpty, name.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "分组缺少可用标识"
            )
        }
    }
}

nonisolated struct SessionSummary: Codable, Sendable, Identifiable, Equatable, Hashable {
    let key: String
    let runtime: String?
    let sessionID: String?
    let shortID: String?
    var title: String
    let cwd: String
    let cwdDisplay: String
    let mtime: Double
    let time: String
    let sizeKB: Double
    let status: String
    let live: Bool
    let hosted: Bool
    let attention: AttentionKind
    let lastUser: String
    let lastAgent: String
    let rich: Bool
    var group: SessionGroupInfo?
    var pinned: Bool?
    /// Host-computed TUI dot (`waiting` / `working` / `unread` / `recent` / "").
    /// Nil only for older hosts that predate the field.
    let marker: String?
    let completionID: String

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, runtime
        case sessionID = "id"
        case shortID = "short_id"
        case title, cwd
        case cwdDisplay = "cwd_display"
        case mtime, time
        case sizeKB = "size_kb"
        case status, live, hosted, attention
        case lastUser = "last_user"
        case lastAgent = "last_agent"
        case rich, group, pinned, marker
        case completionID = "completion_id"
    }

    init(
        key: String,
        runtime: String? = nil,
        sessionID: String? = nil,
        shortID: String? = nil,
        title: String = "",
        cwd: String = "",
        cwdDisplay: String = "",
        mtime: Double = 0,
        time: String = "",
        sizeKB: Double = 0,
        status: String = "",
        live: Bool = false,
        hosted: Bool = false,
        attention: AttentionKind = .none,
        lastUser: String = "",
        lastAgent: String = "",
        rich: Bool = false,
        group: SessionGroupInfo? = nil,
        pinned: Bool? = nil,
        marker: String? = nil,
        completionID: String = ""
    ) {
        self.key = key
        self.runtime = runtime
        self.sessionID = sessionID
        self.shortID = shortID
        self.title = title
        self.cwd = cwd
        self.cwdDisplay = cwdDisplay
        self.mtime = mtime
        self.time = time
        self.sizeKB = sizeKB
        self.status = status
        self.live = live
        self.hosted = hosted
        self.attention = attention
        self.lastUser = lastUser
        self.lastAgent = lastAgent
        self.rich = rich
        self.group = group
        self.pinned = pinned
        self.marker = marker
        self.completionID = completionID
    }

    /// Preserve metadata when the host promotes a provisional identity to a canonical key.
    func replacingKey(_ newKey: String) -> SessionSummary {
        guard newKey != key else { return self }
        return SessionSummary(
            key: newKey,
            runtime: runtime,
            sessionID: sessionID,
            shortID: shortID,
            title: title,
            cwd: cwd,
            cwdDisplay: cwdDisplay,
            mtime: mtime,
            time: time,
            sizeKB: sizeKB,
            status: status,
            live: live,
            hosted: hosted,
            attention: attention,
            lastUser: lastUser,
            lastAgent: lastAgent,
            rich: rich,
            group: group,
            pinned: pinned,
            marker: marker,
            completionID: completionID
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = container.decodeFlexibleString(forKey: .key)
        // 个别旧载荷可能只给 id；没有 key 就无法定位会话，必须失败好让上层跳过。
        guard !decodedKey.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.key,
                .init(codingPath: container.codingPath, debugDescription: "会话缺少 key")
            )
        }
        key = decodedKey
        runtime = container.decodeFlexibleOptionalString(forKey: .runtime)
        sessionID = container.decodeFlexibleOptionalString(forKey: .sessionID)
        shortID = container.decodeFlexibleOptionalString(forKey: .shortID)
        title = container.decodeFlexibleString(forKey: .title)
        cwd = container.decodeFlexibleString(forKey: .cwd)
        cwdDisplay = container.decodeFlexibleString(forKey: .cwdDisplay)
        mtime = container.decodeFlexibleDouble(forKey: .mtime)
        time = container.decodeFlexibleString(forKey: .time)
        sizeKB = container.decodeFlexibleDouble(forKey: .sizeKB)
        status = container.decodeFlexibleString(forKey: .status)
        live = container.decodeFlexibleBool(forKey: .live)
        hosted = container.decodeFlexibleBool(forKey: .hosted)
        let attentionRaw = container.decodeFlexibleString(forKey: .attention, default: "none")
        attention = AttentionKind(rawValue: attentionRaw) ?? .none
        lastUser = container.decodeFlexibleString(forKey: .lastUser)
        lastAgent = container.decodeFlexibleString(forKey: .lastAgent)
        rich = container.decodeFlexibleBool(forKey: .rich)
        // 分组坏掉时丢掉分组，不要整条会话失败。
        group = try? container.decodeIfPresent(SessionGroupInfo.self, forKey: .group)
        if container.contains(.pinned) {
            pinned = container.decodeFlexibleBool(forKey: .pinned)
        } else {
            pinned = nil
        }
        marker = container.decodeFlexibleOptionalString(forKey: .marker)
        completionID = container.decodeFlexibleString(forKey: .completionID)
    }
}

extension SessionSummary {
    /// 搜索匹配：标题、路径、最近消息片段。
    func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle)
            || cwdDisplay.lowercased().contains(needle)
            || lastUser.lowercased().contains(needle)
            || lastAgent.lowercased().contains(needle)
            || (group?.name.lowercased().contains(needle) ?? false)
    }
}
