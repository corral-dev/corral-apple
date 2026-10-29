import Foundation

// MARK: - 列表响应

nonisolated struct SessionsListResponse: Codable, Sendable {
    let sessions: [SessionSummary]
    let version: String?
    let unchanged: Bool
    let hasMore: Bool?
    let total: Int?
    /// Monotonic host metadata revision when supported by newer hosts.
    let revision: UInt64?
    /// Host-authoritative provisional → canonical keys, repeated on every list
    /// reply (including `unchanged`) so a visit key retained without the list
    /// feed can still follow the promoted session.
    let aliases: [String: String]?
    /// Exact host reconciliation of explicit visits outside its bounded window.
    let retainedSessions: [SessionSummary]?
    let missingKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case sessions, version, unchanged
        case hasMore = "has_more"
        case total
        case revision, epoch
        case aliases
        case retainedSessions = "retained_sessions"
        case missingKeys = "missing_keys"
    }

    init(
        sessions: [SessionSummary],
        version: String? = nil,
        unchanged: Bool = false,
        hasMore: Bool? = nil,
        total: Int? = nil,
        revision: UInt64? = nil,
        aliases: [String: String]? = nil,
        retainedSessions: [SessionSummary]? = nil,
        missingKeys: [String]? = nil
    ) {
        self.sessions = sessions
        self.version = version
        self.unchanged = unchanged
        self.hasMore = hasMore
        self.total = total
        self.revision = revision
        self.aliases = aliases
        self.retainedSessions = retainedSessions
        self.missingKeys = missingKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unchanged = container.decodeFlexibleBool(forKey: .unchanged)
        version = container.decodeFlexibleOptionalString(forKey: .version)
        hasMore = container.contains(.hasMore) ? container.decodeFlexibleBool(forKey: .hasMore) : nil
        if container.contains(.total) {
            total = Int(container.decodeFlexibleDouble(forKey: .total))
        } else {
            total = nil
        }
        if container.contains(.revision) {
            revision = UInt64(max(0, container.decodeFlexibleDouble(forKey: .revision)))
        } else if container.contains(.epoch) {
            revision = UInt64(max(0, container.decodeFlexibleDouble(forKey: .epoch)))
        } else {
            revision = nil
        }
        // Hosts repeat aliases on every reply, including `unchanged`.
        aliases = (try? container.decodeIfPresent([String: String].self, forKey: .aliases)) ?? nil
        retainedSessions = (try? container.decodeIfPresent(
            [FailableDecodable<SessionSummary>].self, forKey: .retainedSessions
        ))?.compactMap(\.value)
        missingKeys = try? container.decodeIfPresent([String].self, forKey: .missingKeys)
        if unchanged {
            sessions = []
            return
        }
        // 单条坏会话跳过，避免整表空白。
        if let wrapped = try? container.decodeIfPresent(
            [FailableDecodable<SessionSummary>].self,
            forKey: .sessions
        ) {
            sessions = wrapped.compactMap(\.value)
        } else {
            sessions = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(unchanged, forKey: .unchanged)
        try container.encodeIfPresent(hasMore, forKey: .hasMore)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encodeIfPresent(aliases, forKey: .aliases)
        try container.encodeIfPresent(retainedSessions, forKey: .retainedSessions)
        try container.encodeIfPresent(missingKeys, forKey: .missingKeys)
    }
}

nonisolated struct SessionMessagesResponse: Codable, Sendable {
    let messages: [RichMessage]
    let version: Int
    let kind: String
    let oldestSeq: Int
    let newestSeq: Int
    let hasMore: Bool
    /// `"replay"` 只补缺口；缺省或 `"tail"` 为当前尾部窗口。旧开发机不带此字段。
    let resume: String
    let generation: Int
    let attention: AttentionKind?
    let live: Bool?

    enum CodingKeys: String, CodingKey {
        case messages, version, kind, resume, generation, attention, live
        case oldestSeq = "oldest_seq"
        case newestSeq = "newest_seq"
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let wrapped = try? container.decodeIfPresent([FailableDecodable<RichMessage>].self, forKey: .messages) {
            messages = wrapped.compactMap(\.value)
        } else {
            messages = []
        }
        version = container.decodeFlexibleInt(forKey: .version, default: 1)
        kind = container.decodeFlexibleString(forKey: .kind, default: "snapshot")
        oldestSeq = container.decodeFlexibleInt(forKey: .oldestSeq)
        newestSeq = container.decodeFlexibleInt(forKey: .newestSeq)
        hasMore = container.decodeFlexibleBool(forKey: .hasMore)
        let resumeRaw = container.decodeFlexibleString(forKey: .resume, default: "tail")
        resume = resumeRaw == "replay" ? "replay" : "tail"
        generation = container.decodeFlexibleInt(forKey: .generation, default: 0)
        attention = try? container.decodeIfPresent(AttentionKind.self, forKey: .attention)
        live = try? container.decodeIfPresent(Bool.self, forKey: .live)
    }
}

nonisolated struct SessionToolDetailResponse: Codable, Sendable {
    let seq: Int
    let tools: [ToolCall]
    let offset: Int
    let hasMore: Bool
    let total: Int
    let unavailable: String?

    enum CodingKeys: String, CodingKey {
        case seq, tools, offset, total, unavailable
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = container.decodeFlexibleInt(forKey: .seq)
        if let wrapped = try? container.decodeIfPresent([FailableDecodable<ToolCall>].self, forKey: .tools) {
            tools = wrapped.compactMap(\.value)
        } else {
            tools = []
        }
        offset = container.decodeFlexibleInt(forKey: .offset)
        hasMore = container.decodeFlexibleBool(forKey: .hasMore)
        total = container.decodeFlexibleInt(forKey: .total)
        unavailable = container.decodeFlexibleOptionalString(forKey: .unavailable)
    }
}
