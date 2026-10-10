import Foundation

// MARK: - 富消息

nonisolated struct ToolQuestionGroup: Codable, Sendable, Equatable {
    var summary: String?
    var options: [String]

    enum CodingKeys: String, CodingKey {
        case summary, options
    }

    init(summary: String?, options: [String]) {
        self.summary = summary
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = container.decodeFlexibleOptionalString(forKey: .summary)
        if let options = try? container.decodeIfPresent([String].self, forKey: .options) {
            self.options = options
        } else if let raw = try? container.decodeIfPresent([FailableDecodable<String>].self, forKey: .options) {
            self.options = raw.compactMap(\.value)
        } else {
            self.options = []
        }
    }
}

nonisolated struct ToolCall: Codable, Sendable, Identifiable, Equatable {
    let callID: String
    let name: String
    let kind: String
    let summary: String
    var detail: String?
    var status: String
    var output: String?
    var options: [String]?
    var questions: [ToolQuestionGroup]?
    /// Host says bodies exist server-side; omitted/false when already embedded or none.
    var hasDetail: Bool

    var id: String { callID }

    /// Bodies still missing while the host advertised them (needs session.toolDetail).
    var needsDetailFetch: Bool {
        hasDetail && (detail?.isEmpty ?? true) && (output?.isEmpty ?? true)
    }

    enum CodingKeys: String, CodingKey {
        case callID = "id"
        case name, kind, summary, detail, status, output, options, questions
        case hasDetail = "has_detail"
    }

    init(
        callID: String,
        name: String,
        kind: String,
        summary: String,
        detail: String? = nil,
        status: String = "",
        output: String? = nil,
        options: [String]? = nil,
        questions: [ToolQuestionGroup]? = nil,
        hasDetail: Bool = false
    ) {
        self.callID = callID
        self.name = name
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.status = status
        self.output = output
        self.options = options
        self.questions = questions
        self.hasDetail = hasDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = container.decodeFlexibleString(forKey: .callID)
        let decodedName = container.decodeFlexibleString(forKey: .name)
        // 至少要有 id 或 name，否则卡片无法稳定标识。
        guard !decodedID.isEmpty || !decodedName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .callID,
                in: container,
                debugDescription: "工具调用缺少 id/name"
            )
        }
        callID = decodedID.isEmpty ? decodedName : decodedID
        name = decodedName
        kind = container.decodeFlexibleString(forKey: .kind, default: "other")
        summary = container.decodeFlexibleString(forKey: .summary)
        detail = container.decodeFlexibleOptionalString(forKey: .detail)
        // Empty when host omits status (normal tools); questions still send "running".
        status = container.decodeFlexibleString(forKey: .status, default: "")
        output = container.decodeFlexibleOptionalString(forKey: .output)
        if let options = try? container.decodeIfPresent([String].self, forKey: .options) {
            self.options = options
        } else if let raw = try? container.decodeIfPresent([FailableDecodable<String>].self, forKey: .options) {
            self.options = raw.compactMap(\.value)
        } else {
            self.options = nil
        }
        if let groups = try? container.decodeIfPresent([ToolQuestionGroup].self, forKey: .questions) {
            questions = groups
        } else if let wrapped = try? container.decodeIfPresent(
            [FailableDecodable<ToolQuestionGroup>].self,
            forKey: .questions
        ) {
            questions = wrapped.compactMap(\.value)
        } else {
            questions = nil
        }
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .hasDetail) {
            hasDetail = flag
        } else {
            // Legacy hosts embed bodies on the wire with no has_detail flag.
            hasDetail = !(detail?.isEmpty ?? true) || !(output?.isEmpty ?? true)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callID, forKey: .callID)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(detail, forKey: .detail)
        if !status.isEmpty {
            try container.encode(status, forKey: .status)
        }
        try container.encodeIfPresent(output, forKey: .output)
        try container.encodeIfPresent(options, forKey: .options)
        try container.encodeIfPresent(questions, forKey: .questions)
        try container.encode(hasDetail, forKey: .hasDetail)
    }

    /// Merge fetched bodies onto a summary row without dropping prompt fields.
    func mergingDetail(from other: ToolCall) -> ToolCall {
        var merged = self
        if let detail = other.detail, !detail.isEmpty {
            merged.detail = detail
        }
        if let output = other.output, !output.isEmpty {
            merged.output = output
        }
        if !other.status.isEmpty {
            merged.status = other.status
        }
        merged.hasDetail = merged.hasDetail || other.hasDetail
            || !(merged.detail?.isEmpty ?? true)
            || !(merged.output?.isEmpty ?? true)
        return merged
    }

    /// Persist text/summary cache without tool bodies.
    func strippingBodies() -> ToolCall {
        var slim = self
        let keepQuestionDetail = kind == "question"
        if !keepQuestionDetail {
            slim.detail = nil
        }
        slim.output = nil
        if !(detail?.isEmpty ?? true) || !(output?.isEmpty ?? true) {
            slim.hasDetail = true
        }
        return slim
    }
}

/// 本地发出的气泡送达状态。远端解码缺省为已送达，避免旧包没有该字段。
///
/// With `command_receipts`: pending → accepted → sent(delivered); unknown → needsReview.
/// Without the capability, successful RPC still maps to `.sent` (legacy, not a durable claim).
nonisolated enum MessageDelivery: String, Codable, Sendable, Equatable {
    case pending
    case accepted
    case sent
    case failed
    case needsReview
}

nonisolated struct RichMessage: Codable, Sendable, Identifiable, Equatable {
    let seq: Int
    let role: String
    var text: String?
    var timestamp: Double?
    var tools: [ToolCall]?
    /// 远端正式消息恒为已送达；只有负序号本地气泡会改这个值。
    var delivery: MessageDelivery
    /// Stable outgoing identity when host advertises `command_receipts`; local cache only.
    var commandID: String?
    /// Host-provided human failure text for this local bubble (receipt `detail`).
    /// Local cache only — never on the wire. Shown under failed bubbles.
    var failureDetail: String?
    /// Local-only: display after this official seq (0 = before any official). Nil on wire.
    var localAfterSeq: Int?

    var id: Int { seq }

    /// 本地回显用唯一负序号，避免与远端 seq=0 / seq>0 撞车。
    nonisolated var isLocal: Bool { seq < 0 }

    init(
        seq: Int,
        role: String,
        text: String?,
        delivery: MessageDelivery = .sent,
        timestamp: Double? = nil,
        tools: [ToolCall]? = nil,
        commandID: String? = nil,
        failureDetail: String? = nil,
        localAfterSeq: Int? = nil
    ) {
        self.seq = seq
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.tools = tools
        self.delivery = delivery
        self.commandID = commandID
        self.failureDetail = failureDetail
        self.localAfterSeq = localAfterSeq
    }

    enum CodingKeys: String, CodingKey {
        case seq, role, text
        case timestamp = "ts"
        case tools
        case delivery
        case commandID = "command_id"
        case failureDetail = "failure_detail"
        case localAfterSeq = "local_after_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = container.decodeFlexibleInt(forKey: .seq)
        let decodedRole = container
            .decodeFlexibleOptionalString(forKey: .role)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let decodedRole, decodedRole == "user" || decodedRole == "assistant" else {
            throw DecodingError.dataCorruptedError(
                forKey: .role,
                in: container,
                debugDescription: "富消息角色不是 user 或 assistant"
            )
        }
        role = decodedRole
        text = container.decodeFlexibleOptionalString(forKey: .text)
        if container.contains(.timestamp) {
            timestamp = container.decodeFlexibleDouble(forKey: .timestamp)
        } else {
            timestamp = nil
        }
        if let wrapped = try? container.decodeIfPresent([FailableDecodable<ToolCall>].self, forKey: .tools) {
            let decoded = wrapped.compactMap(\.value)
            tools = decoded.isEmpty ? nil : decoded
        } else {
            tools = nil
        }
        if let raw = container.decodeFlexibleOptionalString(forKey: .delivery),
           let parsed = MessageDelivery(rawValue: raw) {
            delivery = parsed
        } else {
            delivery = .sent
        }
        if let id = container.decodeFlexibleOptionalString(forKey: .commandID), !id.isEmpty {
            commandID = id
        } else {
            commandID = nil
        }
        if container.contains(.localAfterSeq) {
            localAfterSeq = container.decodeFlexibleInt(forKey: .localAfterSeq)
        } else {
            localAfterSeq = nil
        }
        // Local-only field: missing on the wire and in old caches.
        failureDetail = container.decodeFlexibleOptionalString(forKey: .failureDetail)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(tools, forKey: .tools)
        if delivery != .sent || commandID != nil {
            try container.encode(delivery, forKey: .delivery)
        }
        try container.encodeIfPresent(commandID, forKey: .commandID)
        // Local-only: do not write failureDetail for official (seq > 0) messages
        // so history payloads stay wire-clean; local bubbles keep it for display.
        if seq < 0 {
            try container.encodeIfPresent(failureDetail, forKey: .failureDetail)
        }
        try container.encodeIfPresent(localAfterSeq, forKey: .localAfterSeq)
    }
}
