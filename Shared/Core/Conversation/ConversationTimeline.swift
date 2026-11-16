import Foundation

/// 对话页真正展示的时间线元素。
enum ConversationTimelineItem: Identifiable, Equatable, Sendable {
    case message(RichMessage)
    /// Consecutive tool-only assistant turns collapse into one card.
    /// `id` is the first source seq; `sourceSeqs` lists every host message for detail fetch.
    case toolGroup(id: Int, sourceSeqs: [Int], tools: [ToolCall])

    var id: String {
        switch self {
        case .message(let message): "message-\(message.seq)"
        case .toolGroup(let id, _, _): "tools-\(id)"
        }
    }
}

/// 将远端富消息收敛成用户可读的对话时间线。
enum ConversationMessagePolicy {
    /// 本会话真人提示词（旧→新），与电脑端 Your prompts 同过滤规则。
    ///
    /// 已被正式历史确认的本地气泡不再重复列出：自己发的一句在确认前后都是同一条
    /// 提问，不能因为回显与正式消息同时存在就变成两行（owner report 2026-11-15）。
    static func userPrompts(from messages: [RichMessage]) -> [RichMessage] {
        ConversationMessageMerge.consumingLocalEchoes(humanPrompts(from: messages))
    }

    /// 真人提示词过滤本身：只要真人 user 轮次、正文非空、不是运行时注入。
    private static func humanPrompts(from messages: [RichMessage]) -> [RichMessage] {
        var prompts: [RichMessage] = []
        for message in ConversationMessageMerge.displayOrdered(messages) {
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard role == "user" else { continue }
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, !isInjectedUserPrompt(text) else { continue }
            if let last = prompts.last,
               (last.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == text
            {
                // 相邻同文折叠（Codex 等会把同一句写两遍）。
                continue
            }
            prompts.append(message)
        }
        return prompts
    }

    /// Your prompts across the whole session. The host's list is the authority
    /// up to its newest prompt: it applies the host's injected-input filter,
    /// the same one the terminal UI and host prompt navigation use, so this
    /// client keeps no second copy of those rules. A loaded message wins for
    /// the same seq; only prompts newer than the list use the local filter.
    static func userPrompts(loaded: [RichMessage], session: [RichMessage]) -> [RichMessage] {
        let listed = session.filter { $0.seq > 0 }
        guard let newest = listed.map(\.seq).max() else { return userPrompts(from: loaded) }
        var loadedBySeq: [Int: RichMessage] = [:]
        for message in loaded { loadedBySeq[message.seq] = message }
        let hosted = listed.compactMap { prompt -> RichMessage? in
            guard let current = loadedBySeq[prompt.seq] else { return prompt }
            let role = current.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = current.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return role == "user" && !text.isEmpty ? current : nil
        }
        // 本地回显在历史确认前也算一条提问；确认之后它是同一条，不是第二条。
        let local = humanPrompts(from: loaded.filter { $0.seq > newest || $0.seq < 0 })
        return ConversationMessageMerge.consumingLocalEchoes(hosted + local)
    }

    static func timelineItems(
        from messages: [RichMessage],
        preserving previous: [ConversationTimelineItem] = []
    ) -> [ConversationTimelineItem] {
        // A page can extend the first tool group backwards. Retain its existing
        // source sequence identity so the scroll anchor and expanded state survive.
        let previousToolIDs = Set(previous.compactMap { item -> Int? in
            if case .toolGroup(let id, _, _) = item { return id }
            return nil
        })
        var result: [ConversationTimelineItem] = []
        var pendingTools: [ToolCall] = []
        var pendingSourceSeqs: [Int] = []
        var pendingToolID: Int?

        func flushTools() {
            guard let id = pendingToolID, !pendingTools.isEmpty else { return }
            let stableID = pendingSourceSeqs.first(where: previousToolIDs.contains) ?? id
            result.append(.toolGroup(id: stableID, sourceSeqs: pendingSourceSeqs, tools: pendingTools))
            pendingTools.removeAll(keepingCapacity: true)
            pendingSourceSeqs.removeAll(keepingCapacity: true)
            pendingToolID = nil
        }

        for message in ConversationMessageMerge.displayOrdered(messages) {
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tools = message.tools ?? []

            switch role {
            case "user":
                // Runtimes write internal context as user turns; it must not look
                // like a human bubble. Corral's own handoff prompt is a human
                // prompt here and stays visible (see `isInjectedUserPrompt`).
                // A send with only images has no body of its own: the host's
                // pasted paths (official) or the staged payloads (echo) are it.
                let carriesImages = !message.localImageData.isEmpty
                    || !HostPasteAttachment.paths(in: text).isEmpty
                guard !text.isEmpty || carriesImages, !isInjectedUserPrompt(text) else { continue }
                flushTools()
                result.append(.message(message))

            case "assistant":
                if !text.isEmpty {
                    flushTools()
                    result.append(.message(message))
                }
                if !tools.isEmpty {
                    // Merge consecutive tool-only turns into one activity card.
                    // Assistant text (above) or a human bubble breaks the run.
                    if pendingToolID == nil {
                        pendingToolID = message.seq
                    }
                    pendingSourceSeqs.append(message.seq)
                    pendingTools.append(contentsOf: tools)
                }

            default:
                // 未知角色、系统事件和工具结果不进入聊天时间线。
                continue
            }
        }

        flushTools()
        return result
    }

    /// Runtime-injected user turns, which must not render as human bubbles.
    ///
    /// Corral's own cross-runtime handoff prompt is deliberately absent: the
    /// owner treats it as a normal user message, the host's Your prompts list
    /// keeps it, and the TUI keeps it. Do not re-add the handoff intro or task
    /// prefix here just because it is long or repeats another session's excerpt.
    static func isInjectedUserPrompt(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        if [
            "Implement the plan.",
            "只回复 OK。",
            "只回复 RESUMED。",
        ].contains(raw) {
            return true
        }

        if raw.hasPrefix("原始任务：") && (
            raw.contains("用户最新补充") || raw.contains("【本轮回复契约】")
        ) {
            return true
        }

        let prefixes = [
            "<turn_aborted>",
            "<subagent_notification>",
            "<skill>",
            "<local-command",
            "<command-name>",
            "<command-message>",
            "<system-reminder>",
            "<environment_context>",
            "<user_info>",
            "<user_action>",
            "<task-notification>",
            "# AGENTS.md instructions",
            "你是 OpenConductor 的",
            "你将看到一批编程助手会话的摘录",
            "No response requested.",
            "Reply with exactly:",
            "【权威对话账本",
        ]
        if prefixes.contains(where: raw.hasPrefix) { return true }

        let markers = [
            "Implement the plan as specified, it is attached for your reference",
            "Do NOT edit the plan file itself",
            "To-do's from the plan have already been created",
            "Briefly inform the user about the task result",
            "【本轮回复契约】",
        ]
        return markers.contains(where: raw.contains)
    }
}

/// 按序号合并对话消息。后到的覆盖先到的。
///
/// 禁止用 `Dictionary(uniqueKeysWithValues:)`：快照或实时批次里只要有两条相同序号，
/// 会触发断言，App 直接闪退。本地负序号气泡在正式消息按「同角色 + 正文」到达后丢掉。
nonisolated enum ConversationMessageMerge: Sendable {
    static func combining(_ existing: [RichMessage], with incoming: [RichMessage]) -> [RichMessage] {
        var bySequence: [Int: RichMessage] = [:]
        bySequence.reserveCapacity(existing.count + incoming.count)
        for message in existing {
            bySequence[message.seq] = message
        }
        for message in incoming {
            bySequence[message.seq] = message
        }
        return consumingLocalEchoes(displayOrdered(Array(bySequence.values)))
    }

    /// 正式消息（seq>0）吃掉对应的本地负序号气泡。
    ///
    /// 手机发出的图片由宿主落盘后把路径粘进用户消息正文，历史里的正文因此带
    /// `<cwd>/.corral-pastes/paste-….jpg` 前缀。比较必须用去掉该路径的正文，
    /// 否则回显永远匹配不上：一条带图消息会留下「正文 + [image] + 正式」三条
    /// 气泡（owner report 2026-11-15，截图同序）。
    ///
    /// 正式消息按 seq 升序配对，本地气泡只认「发出之后」的正式用户消息
    /// （`localAfterSeq`），同一句连发不会互相抢占。
    static func consumingLocalEchoes(_ messages: [RichMessage]) -> [RichMessage] {
        var officialTextKeys: Set<String> = []
        var officialUsers: [(seq: Int, key: String, hasAttachments: Bool)] = []
        for message in messages where message.seq > 0 {
            let role = normalizedRole(message.role)
            let body = displayBody(message)
            let key = identityKey(role: role, text: body)
            if role == "user" {
                officialUsers.append((message.seq, key, !HostPasteAttachment.paths(in: message.text).isEmpty))
            } else if !body.isEmpty {
                officialTextKeys.insert(key)
            }
        }
        officialUsers.sort { $0.seq < $1.seq }
        var claimed: Set<Int> = []

        return messages.filter { message in
            guard message.seq < 0 else { return true }
            let role = normalizedRole(message.role)
            let body = displayBody(message)
            guard !body.isEmpty || message.hasLocalImages else { return true }
            let key = identityKey(role: role, text: body)
            guard role == "user" else { return !officialTextKeys.contains(key) }
            guard let match = officialUsers.first(where: { official in
                official.seq > (message.localAfterSeq ?? 0)
                    && official.key == key
                    && !claimed.contains(official.seq)
                    // An attachment-only echo needs the confirmed turn to carry
                    // the image; an empty official turn would be a different send.
                    && (official.hasAttachments || !message.hasLocalImages)
            }) else { return true }
            claimed.insert(match.seq)
            return false
        }
    }

    /// The readable body of a message. A user turn's host-pasted attachment
    /// paths are images, not text, so they never reach the bubble or an echo key.
    static func displayBody(_ message: RichMessage) -> String {
        let text = normalizedText(message.text)
        guard normalizedRole(message.role) == "user" else { return text }
        return HostPasteAttachment.body(text)
    }

    static func normalizedRole(_ role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 正式消息按 seq 升序；本地负序号插在 `localAfterSeq` 之后（发出时的最新正式序号），
    /// 这样助手正式回复先到时，用户刚发的气泡不会被整段甩到时间线末尾。
    static func displayOrdered(_ messages: [RichMessage]) -> [RichMessage] {
        messages.sorted { lhs, rhs in
            let left = displayRank(lhs)
            let right = displayRank(rhs)
            if left.bucket != right.bucket { return left.bucket < right.bucket }
            if left.phase != right.phase { return left.phase < right.phase }
            return left.tie < right.tie
        }
    }

    /// Official seq N → (N, 0, *); local after N → (N, 1, *) so it sits between N and N+1.
    private static func displayRank(_ message: RichMessage) -> (bucket: Int, phase: Int, tie: Int) {
        if message.seq > 0 {
            return (message.seq, 0, 0)
        }
        let after = message.localAfterSeq ?? 0
        // More negative local seq = later send → higher tie within the same after slot.
        return (after, 1, -message.seq)
    }

    static func normalizedText(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func identityKey(role: String, text: String) -> String {
        "\(normalizedRole(role))\n\(collapsedWhitespace(text))"
    }

    /// 回显配对用的空白归一：任何空白串折成一个空格。
    ///
    /// 开发机是经 tmux bracketed paste 把提示词送进窗格的，粘贴会把制表符展开成
    /// 空格，所以正式记录与本机回显不可能逐字节相同（owner report 2026-11-15：
    /// 输入里的 tab 入库后变成四个空格，Your prompts 因此多出一行）。
    static func collapsedWhitespace(_ text: String) -> String {
        normalizedText(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Result of applying a `session.watch` / history page to the local conversation store.
struct ConversationWatchApplyResult: Equatable, Sendable {
    var messages: [RichMessage]
    var oldestSequence: Int
    var newestSequence: Int
    var hasMoreHistory: Bool
    var generation: Int
}

/// 按 `session.watch` 的 resume 决定如何把回包应用到本地消息。
///
/// replay：必须 merge，空包也不得清空。
/// tail：空包且本地已有内容则不覆盖；非空尾部在 **同 generation** 且与本地更早页
/// **首尾相接** 时保留已同步的更早正式消息（零往返复用），否则只保留尾部 + 本地气泡。
/// generation 变化视为历史被替换，丢弃本地正式消息。
nonisolated enum ConversationWatchApply: Sendable {
    static func messages(
        local: [RichMessage],
        incoming: [RichMessage],
        resume: String
    ) -> [RichMessage] {
        apply(
            local: local,
            localOldest: Self.oldestOfficial(in: local),
            localNewest: Self.newestOfficial(in: local),
            localHasMore: false,
            localGeneration: 0,
            incoming: incoming,
            incomingOldest: Self.oldestOfficial(in: incoming),
            incomingNewest: Self.newestOfficial(in: incoming),
            incomingHasMore: false,
            incomingGeneration: 0,
            resume: resume
        ).messages
    }

    static func apply(
        local: [RichMessage],
        localOldest: Int,
        localNewest: Int,
        localHasMore: Bool,
        localGeneration: Int,
        incoming: [RichMessage],
        incomingOldest: Int,
        incomingNewest: Int,
        incomingHasMore: Bool,
        incomingGeneration: Int,
        resume: String
    ) -> ConversationWatchApplyResult {
        let locals = local.filter(\.isLocal)
        let generationChanged = localGeneration > 0
            && incomingGeneration > 0
            && localGeneration != incomingGeneration

        if generationChanged {
            let merged = ConversationMessageMerge.combining(locals, with: incoming)
            return ConversationWatchApplyResult(
                messages: merged,
                oldestSequence: incomingOldest > 0 ? incomingOldest : oldestOfficial(in: merged),
                newestSequence: incomingNewest > 0 ? incomingNewest : newestOfficial(in: merged),
                hasMoreHistory: incomingHasMore,
                generation: incomingGeneration
            )
        }

        let resumeKind = resume == "replay" ? "replay" : "tail"
        if resumeKind == "replay" {
            let merged = ConversationMessageMerge.combining(local, with: incoming)
            let oldest = oldestOfficial(in: merged)
            let newest = newestOfficial(in: merged)
            return ConversationWatchApplyResult(
                messages: merged,
                oldestSequence: oldest > 0 ? oldest : localOldest,
                newestSequence: max(newest, localNewest, incomingNewest),
                hasMoreHistory: localHasMore,
                generation: incomingGeneration > 0 ? incomingGeneration : localGeneration
            )
        }

        if incoming.isEmpty && !local.isEmpty {
            return ConversationWatchApplyResult(
                messages: local,
                oldestSequence: localOldest > 0 ? localOldest : oldestOfficial(in: local),
                newestSequence: localNewest > 0 ? localNewest : newestOfficial(in: local),
                hasMoreHistory: localHasMore,
                generation: localGeneration
            )
        }

        let windowOldest = incomingOldest > 0 ? incomingOldest : oldestOfficial(in: incoming)
        let earlierOfficial = local.filter { message in
            message.seq > 0 && windowOldest > 0 && message.seq < windowOldest
        }
        let abutSeq = earlierOfficial.map(\.seq).max() ?? 0
        let contiguousEarlier = !earlierOfficial.isEmpty && abutSeq + 1 == windowOldest
        let retainedEarlier = contiguousEarlier ? earlierOfficial : []
        let merged = ConversationMessageMerge.combining(retainedEarlier + locals, with: incoming)
        let oldest = oldestOfficial(in: merged)
        let newest = newestOfficial(in: merged)
        let hasMore: Bool
        if contiguousEarlier {
            hasMore = localHasMore
        } else {
            hasMore = incomingHasMore
        }
        return ConversationWatchApplyResult(
            messages: merged,
            oldestSequence: oldest > 0 ? oldest : (windowOldest > 0 ? windowOldest : localOldest),
            newestSequence: max(newest, localNewest, incomingNewest),
            hasMoreHistory: hasMore,
            generation: incomingGeneration > 0 ? incomingGeneration : localGeneration
        )
    }

    private static func oldestOfficial(in messages: [RichMessage]) -> Int {
        messages.lazy.map(\.seq).filter { $0 > 0 }.min() ?? 0
    }

    private static func newestOfficial(in messages: [RichMessage]) -> Int {
        messages.lazy.map(\.seq).filter { $0 > 0 }.max() ?? 0
    }
}

/// 输入条上方的当前提问：只取仍在等待、且后面没有新动作的那一次。
enum ConversationPromptPolicy {
    static func pendingPrompts(from messages: [RichMessage]) -> [SessionPrompt] {
        for message in messages.reversed() {
            let running = (message.tools ?? []).filter { tool in
                (tool.kind == "question" || !(tool.options ?? []).isEmpty || !(tool.questions ?? []).isEmpty)
                    && tool.status == "running"
            }
            if !running.isEmpty {
                return running.flatMap(prompts(from:))
            }
            if supersedesPrompts(message) {
                return []
            }
        }
        return []
    }

    private static func prompts(from tool: ToolCall) -> [SessionPrompt] {
        let groups = tool.questions ?? []
        if groups.count > 1 {
            return groups.enumerated().map { index, group in
                SessionPrompt(
                    id: "\(tool.callID):\(index)",
                    name: tool.name,
                    summary: (group.summary?.isEmpty == false) ? group.summary : tool.summary,
                    detail: tool.detail,
                    options: group.options
                )
            }
        }
        if let only = groups.first, !only.options.isEmpty {
            return [
                SessionPrompt(
                    id: tool.callID,
                    name: tool.name,
                    summary: (only.summary?.isEmpty == false) ? only.summary : tool.summary,
                    detail: tool.detail,
                    options: only.options
                )
            ]
        }
        return [
            SessionPrompt(
                id: tool.callID,
                name: tool.name,
                summary: tool.summary,
                detail: tool.detail,
                options: tool.options ?? []
            )
        ]
    }

    private static func supersedesPrompts(_ message: RichMessage) -> Bool {
        if !(message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        for tool in message.tools ?? [] {
            let isRunningQuestion = tool.kind == "question" && tool.status == "running"
            if !isRunningQuestion {
                return true
            }
        }
        return false
    }
}
