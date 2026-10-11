import Foundation

nonisolated struct SessionPrompt: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String?
    let summary: String?
    let detail: String?
    let prompt: String?
    /// Short native label (Claude/Codex `header`, OpenCode field title).
    let header: String?
    let options: [String]
    let requestID: String
    let questionID: String
    let multiSelect: Bool
    let allowCustom: Bool
    /// Typed text is only a note on a chosen option (Claude preview questions).
    let customNeedsChoice: Bool
    let isSecret: Bool
    let optionDetails: [SessionPromptOption]
    /// The host's native picker owns the keyboard (Claude, Codex sync): chat
    /// input is refused until it is answered. Absent on older hosts.
    let blocksInput: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, summary, detail, prompt, header, options
        case requestID = "request_id"
        case questionID = "question_id"
        case multiSelect = "multi_select"
        case allowCustom = "allow_custom"
        case customNeedsChoice = "custom_needs_choice"
        case isSecret = "is_secret"
        case optionDetails = "option_details"
        case blocksInput = "blocks_input"
    }

    init(
        id: String,
        name: String?,
        summary: String?,
        detail: String?,
        options: [String],
        prompt: String? = nil,
        header: String? = nil,
        requestID: String? = nil,
        questionID: String? = nil,
        multiSelect: Bool = false,
        allowCustom: Bool = false,
        customNeedsChoice: Bool = false,
        isSecret: Bool = false,
        optionDetails: [SessionPromptOption] = [],
        blocksInput: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.detail = detail
        self.prompt = prompt
        self.header = header
        self.options = options
        self.requestID = requestID ?? id
        self.questionID = questionID ?? id
        self.multiSelect = multiSelect
        self.allowCustom = allowCustom
        self.customNeedsChoice = customNeedsChoice
        self.isSecret = isSecret
        self.optionDetails = optionDetails
        self.blocksInput = blocksInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = container.decodeFlexibleString(forKey: .id)
        guard !decodedID.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: container.codingPath, debugDescription: "提问缺少 id")
            )
        }
        id = decodedID
        name = container.decodeFlexibleOptionalString(forKey: .name)
        summary = container.decodeFlexibleOptionalString(forKey: .summary)
        detail = container.decodeFlexibleOptionalString(forKey: .detail)
        prompt = container.decodeFlexibleOptionalString(forKey: .prompt)
        header = container.decodeFlexibleOptionalString(forKey: .header)
        // Older hosts send only the legacy id: it names both the request and its one question.
        let decodedRequestID = container.decodeFlexibleString(forKey: .requestID)
        requestID = decodedRequestID.isEmpty ? decodedID : decodedRequestID
        let decodedQuestionID = container.decodeFlexibleString(forKey: .questionID)
        questionID = decodedQuestionID.isEmpty ? decodedID : decodedQuestionID
        multiSelect = container.decodeFlexibleBool(forKey: .multiSelect)
        allowCustom = container.decodeFlexibleBool(forKey: .allowCustom)
        customNeedsChoice = container.decodeFlexibleBool(forKey: .customNeedsChoice)
        isSecret = container.decodeFlexibleBool(forKey: .isSecret)
        blocksInput = container.decodeFlexibleBool(forKey: .blocksInput)
        if let options = try? container.decodeIfPresent([String].self, forKey: .options) {
            self.options = options
        } else if let wrapped = try? container.decodeIfPresent([FailableDecodable<String>].self, forKey: .options) {
            self.options = wrapped.compactMap(\.value)
        } else {
            self.options = []
        }
        if let details = try? container.decodeIfPresent([SessionPromptOption].self, forKey: .optionDetails) {
            optionDetails = details
        } else {
            optionDetails = []
        }
    }
}

nonisolated struct SessionPromptOption: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let label: String
    let description: String?
}

nonisolated struct NativeQuestionAnswer: Codable, Sendable, Equatable {
    let questionID: String
    let selected: [String]
    let text: String

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case selected, text
    }

    func wireValue() -> [String: Any] {
        ["question_id": questionID, "selected": selected, "text": text]
    }
}

enum NativeQuestionSelection {
    static func toggled(
        _ optionID: String,
        in current: Set<String>,
        allowsMultiple: Bool
    ) -> Set<String> {
        if current.contains(optionID) {
            return current.subtracting([optionID])
        }
        return allowsMultiple ? current.union([optionID]) : [optionID]
    }

    /// A question is answered by a choice, or by typed text when text can stand alone.
    static func isAnswered(selected: Set<String>, typed: String, customNeedsChoice: Bool) -> Bool {
        if !selected.isEmpty { return true }
        if customNeedsChoice { return false }
        return !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

nonisolated struct NativeQuestionAnswerResult: Decodable, Sendable, Equatable {
    enum Status: String, Decodable, Sendable {
        case delivered
        case stale
        case unavailable
    }

    let status: Status
    let detail: String?
}

enum NativeQuestionSubmissionStatus: Equatable, Sendable {
    case submitting
    case delivered
    case stale(String?)
    case unavailable(String?)
    case failed(String?)
}

/// Whether chat input must wait for the open question (host `blocks_input`).
enum PendingQuestionGate {
    static func blocksInput(_ prompts: [SessionPrompt], submission: NativeQuestionSubmissionState?) -> Bool {
        guard let current = prompts.first, current.blocksInput else { return false }
        // An answer already delivered releases the keyboard before the host refreshes.
        return !(submission?.requestID == current.requestID && submission?.status == .delivered)
    }
}

struct NativeQuestionSubmissionState: Equatable, Sendable {
    let requestID: String
    let status: NativeQuestionSubmissionStatus
}

nonisolated struct SessionPromptsResponse: Codable, Sendable {
    let prompts: [SessionPrompt]

    enum CodingKeys: String, CodingKey {
        case prompts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let wrapped = try? container.decodeIfPresent([FailableDecodable<SessionPrompt>].self, forKey: .prompts) {
            prompts = wrapped.compactMap(\.value)
        } else {
            prompts = []
        }
    }
}

nonisolated struct ScreenWatchResponse: Codable, Sendable {
    let frame: ScreenFrame?

    enum CodingKeys: String, CodingKey {
        case frame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // frame 为 null / 缺字段 / 半残都当成「暂无首帧」，交给后续事件补齐。
        frame = try? container.decodeIfPresent(ScreenFrame.self, forKey: .frame)
    }
}

struct RemoteEvent: Sendable {
    let channel: String
    let data: [String: Any]

    init(channel: String, data: [String: Any]) {
        self.channel = channel
        self.data = data
    }
}

/// Host reply for `session.userPrompts`: every human prompt of the session, oldest first.
nonisolated struct SessionUserPromptsResponse: Codable, Sendable {
    let prompts: [RichMessage]
    let generation: Int

    enum CodingKeys: String, CodingKey {
        case prompts, generation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wrapped = try? container.decodeIfPresent([FailableDecodable<RichMessage>].self, forKey: .prompts)
        prompts = (wrapped ?? []).compactMap(\.value).filter { $0.seq > 0 && $0.role == "user" }
        generation = (try? container.decodeIfPresent(Int.self, forKey: .generation)) ?? 0
    }
}
