import Foundation
@testable import Corral
import XCTest

@MainActor
final class ConversationTimelineTests: XCTestCase {
    func testToolGroupIdentitySurvivesPrependingAndAppending() throws {
        let tail = try [message(seq: 20, role: "assistant", tools: [tool(id: "20", name: "read")])]
        let initial = ConversationMessagePolicy.timelineItems(from: tail)
        let expanded = try [message(seq: 19, role: "assistant", tools: [tool(id: "19", name: "read")])] + tail
        let prepended = ConversationMessagePolicy.timelineItems(from: expanded, preserving: initial)
        XCTAssertEqual(prepended.first?.id, initial.first?.id)
        let appended = ConversationMessagePolicy.timelineItems(
            from: expanded + [try message(seq: 21, role: "assistant", tools: [tool(id: "21", name: "read")])],
            preserving: prepended)
        XCTAssertEqual(appended.first?.id, initial.first?.id)
        let split = ConversationMessagePolicy.timelineItems(
            from: [expanded[0], try message(seq: 20, role: "assistant", text: "Explanation", tools: [tool(id: "20", name: "read")])],
            preserving: appended)
        XCTAssertEqual(Set(split.map(\.id)).count, split.count)
    }

    func testTimelineKeepsOnlyHumanMessagesAndGroupsTools() throws {
        let messages = try [
            message(seq: 4, role: "assistant", text: "答案"),
            message(seq: 2, role: "assistant", tools: [tool(id: "read-1", name: "read")]),
            message(seq: 1, role: "user", text: "请检查这个问题"),
            message(seq: 3, role: "assistant", tools: [tool(id: "shell-1", name: "shell")]),
            message(seq: 5, role: "user", text: "<system-reminder>内部注入</system-reminder>"),
        ]

        let items = ConversationMessagePolicy.timelineItems(from: messages)

        XCTAssertEqual(items.count, 3)
        guard case .message(let first) = items[0] else {
            return XCTFail("第一项应是真人消息")
        }
        XCTAssertEqual(first.role, "user")
        XCTAssertEqual(first.text, "请检查这个问题")

        guard case .toolGroup(let firstToolSeq, let sourceSeqs, let firstTools) = items[1] else {
            return XCTFail("第二项应是合并后的工具操作组")
        }
        XCTAssertEqual(firstToolSeq, 2)
        XCTAssertEqual(sourceSeqs, [2, 3])
        XCTAssertEqual(firstTools.map(\.callID), ["read-1", "shell-1"])

        guard case .message(let last) = items[2] else {
            return XCTFail("第三项应是助手消息")
        }
        XCTAssertEqual(last.text, "答案")
    }

    func testTimelineAssistantTextBreaksConsecutiveToolMerge() throws {
        let messages = try [
            message(seq: 1, role: "user", text: "开始"),
            message(seq: 2, role: "assistant", tools: [tool(id: "a", name: "read")]),
            message(seq: 3, role: "assistant", text: "中间说明"),
            message(seq: 4, role: "assistant", tools: [tool(id: "b", name: "shell")]),
            message(seq: 5, role: "assistant", tools: [tool(id: "c", name: "grep")]),
        ]

        let items = ConversationMessagePolicy.timelineItems(from: messages)
        XCTAssertEqual(items.count, 4)

        guard case .toolGroup(let firstID, let firstSeqs, let firstTools) = items[1] else {
            return XCTFail("正文前应有一组工具")
        }
        XCTAssertEqual(firstID, 2)
        XCTAssertEqual(firstSeqs, [2])
        XCTAssertEqual(firstTools.map(\.callID), ["a"])

        guard case .message(let mid) = items[2] else {
            return XCTFail("中间应是助手正文")
        }
        XCTAssertEqual(mid.text, "中间说明")

        guard case .toolGroup(let secondID, let secondSeqs, let secondTools) = items[3] else {
            return XCTFail("正文后连续工具应再合成一组")
        }
        XCTAssertEqual(secondID, 4)
        XCTAssertEqual(secondSeqs, [4, 5])
        XCTAssertEqual(secondTools.map(\.callID), ["b", "c"])
    }

    func testUserPromptsListsHumanPromptsOldestFirstAndSkipsInjected() throws {
        let messages = try [
            message(seq: 3, role: "user", text: "第二句"),
            message(seq: 1, role: "user", text: "第一句"),
            message(seq: 2, role: "assistant", text: "好的"),
            message(seq: 4, role: "user", text: "You are picking up a session from Claude"),
            message(seq: 5, role: "user", text: "第二句"),
        ]

        let prompts = ConversationMessagePolicy.userPrompts(from: messages)
        XCTAssertEqual(prompts.map(\.text), ["第一句", "第二句"])
    }

    func testRichMessageRejectsUnknownOrMissingRole() {
        XCTAssertThrowsError(
            try RemoteJSONDecoder.decode(
                RichMessage.self,
                from: ["seq": 1, "role": "system", "text": "内部状态"]
            )
        )
        XCTAssertThrowsError(
            try RemoteJSONDecoder.decode(
                RichMessage.self,
                from: ["seq": 2, "text": "没有角色"]
            )
        )
    }

    func testWireMessageCompressionRoundTrip() throws {
        var message = WireMessage.request(id: 7, method: WireProtocol.mSessionWatch)
        message["payload"] = String(repeating: "连续助手输出", count: 2000)
        let raw = try WireMessage.dumps(message)
        let packed = try WireMessage.pack(message, compression: true)

        XCTAssertLessThan(packed.count, raw.count)
        XCTAssertEqual(try WireMessage.unpack(packed)["m"] as? String, WireProtocol.mSessionWatch)
        XCTAssertEqual(try WireMessage.unpack(packed)["payload"] as? String, message["payload"] as? String)
        XCTAssertEqual(try WireMessage.unpack(raw)["m"] as? String, WireProtocol.mSessionWatch)
        XCTAssertNotEqual(packed[8], 0x78)
    }

    func testUnpacksHostRawDeflatePayload() throws {
        // 开发机 raw DEFLATE（wbits=-15）产出的真实载荷，用来锁两端压缩格式。
        let hex = "4352010100000a73edcb410a80301043d1bb64ad6e85de666c0714aba3ada022dedd59788c2cdf0f797020a0e88e065342e81b2c1eaad63ad9da9d72c4d1a70de1c1acb74fd1925e418688d7bbdcd9c47f1835676ba39522b925088220088220881f783f"
        var data = Data()
        var start = hex.startIndex
        while start < hex.endIndex {
            let end = hex.index(start, offsetBy: 2)
            data.append(UInt8(String(hex[start..<end]), radix: 16)!)
            start = end
        }
        let message = try WireMessage.unpack(data)
        XCTAssertEqual(message["m"] as? String, WireProtocol.mSessionWatch)
        XCTAssertEqual(message["p"] as? [String: String], ["key": "codex:abc"])
    }

    func testSessionMessagesResponseReadsWindowMetadata() throws {
        let response = try RemoteJSONDecoder.decode(
            SessionMessagesResponse.self,
            from: [
                "version": 1,
                "kind": "snapshot",
                "messages": [["seq": 4, "role": "assistant", "text": "已完成"]],
                "oldest_seq": 4,
                "newest_seq": 4,
                "has_more": true,
            ]
        )

        XCTAssertEqual(response.oldestSeq, 4)
        XCTAssertEqual(response.newestSeq, 4)
        XCTAssertTrue(response.hasMore)
        XCTAssertEqual(response.messages.first?.text, "已完成")
        XCTAssertEqual(response.resume, "tail")
        XCTAssertEqual(response.generation, 0)
    }

    func testSessionMessagesResponseReadsReplayResume() throws {
        let response = try RemoteJSONDecoder.decode(
            SessionMessagesResponse.self,
            from: [
                "version": 1,
                "kind": "snapshot",
                "messages": [["seq": 5, "role": "assistant", "text": "新一句"]],
                "oldest_seq": 5,
                "newest_seq": 5,
                "has_more": false,
                "resume": "replay",
                "generation": 2,
            ]
        )
        XCTAssertEqual(response.resume, "replay")
        XCTAssertEqual(response.generation, 2)
        XCTAssertEqual(response.messages.first?.text, "新一句")
    }

    func testReplayMustMergeAndEmptyReplayMustNotClear() throws {
        let existing = try [
            message(seq: 1, role: "user", text: "已有问题"),
            message(seq: 2, role: "assistant", text: "已有答案"),
        ]
        let gap = try [message(seq: 3, role: "user", text: "断线期间的追问")]
        let merged = ConversationWatchApply.messages(
            local: existing,
            incoming: gap,
            resume: "replay"
        )
        XCTAssertEqual(merged.map(\.seq), [1, 2, 3])
        XCTAssertEqual(merged[2].text, "断线期间的追问")

        let caughtUp = ConversationWatchApply.messages(
            local: existing,
            incoming: [],
            resume: "replay"
        )
        XCTAssertEqual(caughtUp.map(\.seq), [1, 2], "空 replay 不得被理解成清空")
        XCTAssertEqual(caughtUp[0].text, "已有问题")
    }

    func testTailEmptyMustNotClearLocalMessages() throws {
        let existing = try [message(seq: 1, role: "user", text: "本地已有")]
        let kept = ConversationWatchApply.messages(
            local: existing,
            incoming: [],
            resume: "tail"
        )
        XCTAssertEqual(kept.map(\.seq), [1])
        // Orphan seq 1 does not abut window starting at 9 — drop it to avoid gaps.
        let replaced = ConversationWatchApply.messages(
            local: existing,
            incoming: [try message(seq: 9, role: "assistant", text: "新尾部")],
            resume: "tail"
        )
        XCTAssertEqual(replaced.map(\.seq), [9])
    }

    func testTailSameGenerationKeepsContiguousEarlierPages() throws {
        let local = try (50...120).map { seq in
            try message(seq: seq, role: seq % 2 == 0 ? "user" : "assistant", text: "m\(seq)")
        }
        let incoming = try (121...140).map { seq in
            try message(seq: seq, role: seq % 2 == 0 ? "user" : "assistant", text: "m\(seq)")
        }
        let applied = ConversationWatchApply.apply(
            local: local,
            localOldest: 50,
            localNewest: 120,
            localHasMore: true,
            localGeneration: 4,
            incoming: incoming,
            incomingOldest: 121,
            incomingNewest: 140,
            incomingHasMore: true,
            incomingGeneration: 4,
            resume: "tail"
        )
        XCTAssertEqual(applied.messages.first?.seq, 50)
        XCTAssertEqual(applied.messages.last?.seq, 140)
        XCTAssertEqual(applied.oldestSequence, 50)
        XCTAssertEqual(applied.newestSequence, 140)
        XCTAssertTrue(applied.hasMoreHistory)
        XCTAssertEqual(applied.generation, 4)
    }

    func testTailGenerationChangeDropsEarlierLocalOfficial() throws {
        let local = try [
            message(seq: 50, role: "user", text: "旧代"),
            message(seq: 120, role: "assistant", text: "旧代尾"),
        ]
        let incoming = try [
            message(seq: 1, role: "user", text: "新代"),
            message(seq: 2, role: "assistant", text: "新代尾"),
        ]
        let applied = ConversationWatchApply.apply(
            local: local,
            localOldest: 50,
            localNewest: 120,
            localHasMore: false,
            localGeneration: 3,
            incoming: incoming,
            incomingOldest: 1,
            incomingNewest: 2,
            incomingHasMore: false,
            incomingGeneration: 4,
            resume: "tail"
        )
        XCTAssertEqual(applied.messages.map(\.seq), [1, 2])
        XCTAssertEqual(applied.generation, 4)
        XCTAssertFalse(applied.hasMoreHistory)
    }

    func testTailKeepsUnconsumedLocalPendingWithEarlierPages() throws {
        var pending = try message(seq: -1, role: "user", text: "发送中")
        pending.delivery = .pending
        pending.localAfterSeq = 120
        let local = try (100...120).map { seq in
            try message(seq: seq, role: "assistant", text: "m\(seq)")
        } + [pending]
        let incoming = try (121...130).map { seq in
            try message(seq: seq, role: "user", text: "m\(seq)")
        }
        let applied = ConversationWatchApply.apply(
            local: local,
            localOldest: 100,
            localNewest: 120,
            localHasMore: true,
            localGeneration: 1,
            incoming: incoming,
            incomingOldest: 121,
            incomingNewest: 130,
            incomingHasMore: true,
            incomingGeneration: 1,
            resume: "tail"
        )
        XCTAssertTrue(applied.messages.contains(where: { $0.seq == -1 }))
        XCTAssertEqual(applied.messages.first?.seq, 100)
    }

    func testTimelineMatchesTUIInjectedPromptBoundaries() throws {
        let injected = [
            "Implement the plan.",
            "只回复 OK。",
            "<turn_aborted>用户中断了上一轮</turn_aborted>",
            "你是 OpenConductor 的编排助手",
            "You are picking up a session from another runtime",
            "这是跨运行时接力，不是原生恢复",
            "【本轮回复契约】请只返回结果",
        ]

        let items = ConversationMessagePolicy.timelineItems(from: try injected.enumerated().map { index, text in
            try message(seq: index, role: "user", text: text)
        })

        XCTAssertTrue(items.isEmpty)
    }

    func testTimelineKeepsHumanSkillDefaultPrompts() throws {
        let kept = [
            "对本仓库当前的 git diff 做一次 code review，不要额外限制范围。",
            "先按项目现有规则完成 build/test/lint",
            "请检查这个问题",
        ]
        let items = ConversationMessagePolicy.timelineItems(from: try kept.enumerated().map { index, text in
            try message(seq: index, role: "user", text: text)
        })
        XCTAssertEqual(items.count, 3)
    }

    func testMergeLastWriteWinsOnDuplicateSequenceWithoutTrapping() throws {
        let existing = try [
            message(seq: 1, role: "user", text: "旧问题"),
            message(seq: 1, role: "user", text: "重复序号不应崩"),
            message(seq: 2, role: "assistant", text: "旧答案"),
        ]
        let incoming = try [
            message(seq: 2, role: "assistant", text: "新答案"),
            message(seq: 3, role: "user", text: "追问"),
        ]
        let merged = ConversationMessageMerge.combining(existing, with: incoming)
        XCTAssertEqual(merged.map(\.seq), [1, 2, 3])
        XCTAssertEqual(merged[0].text, "重复序号不应崩")
        XCTAssertEqual(merged[1].text, "新答案")
        XCTAssertEqual(merged[2].text, "追问")
    }

    func testLocalPendingThenOfficialUserKeepsSingleOfficial() throws {
        let local = RichMessage(seq: -1, role: "user", text: "同一句", delivery: .pending)
        let official = try message(seq: 8, role: "user", text: "同一句")
        let merged = ConversationMessageMerge.combining([local], with: [official])
        XCTAssertEqual(merged.map(\.seq), [8])
        XCTAssertEqual(merged[0].delivery, .sent)
        XCTAssertEqual(merged[0].text, "同一句")
    }

    func testEchoDoesNotDuplicateLocalPending() async {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
        let seq = store.enqueueLocalUser("刚刚发出去")
        XCTAssertEqual(seq, -1)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].delivery, .pending)

        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "echo",
            "session": "k",
            "role": "user",
            "text": "刚刚发出去",
        ]))

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].seq, -1)
        XCTAssertEqual(store.messages[0].delivery, .sent)
        XCTAssertEqual(store.messages[0].text, "刚刚发出去")
    }

    func testEmptyReplayKeepsLocalPending() throws {
        let pending = RichMessage(seq: -1, role: "user", text: "在路上", delivery: .pending)
        let existing = [
            try message(seq: 1, role: "assistant", text: "旧答案"),
            pending,
        ]
        let caughtUp = ConversationWatchApply.messages(
            local: existing,
            incoming: [],
            resume: "replay"
        )
        XCTAssertTrue(caughtUp.contains { $0.seq == -1 && $0.delivery == .pending })
        XCTAssertEqual(caughtUp.first { $0.seq == 1 }?.text, "旧答案")
    }

    func testTailReplacementKeepsUnconsumedLocalPending() throws {
        let pending = RichMessage(
            seq: -1,
            role: "user",
            text: "刚发出去",
            delivery: .pending,
            localAfterSeq: 1
        )
        let old = try message(seq: 1, role: "assistant", text: "旧")
        let incoming = try [message(seq: 9, role: "assistant", text: "新尾部")]
        let kept = ConversationWatchApply.messages(
            local: [old, pending],
            incoming: incoming,
            resume: "tail"
        )
        // Local stays after its send-time anchor (1), before newer official seq 9.
        XCTAssertEqual(ConversationMessageMerge.displayOrdered(kept).map(\.seq), [-1, 9])
        XCTAssertEqual(kept.first { $0.seq == -1 }?.delivery, .pending)
    }

    func testLocalPendingStaysBeforeLaterOfficialAssistant() {
        let pending = RichMessage(
            seq: -1,
            role: "user",
            text: "在吗",
            delivery: .pending,
            localAfterSeq: 0
        )
        let assistant = RichMessage(seq: 1, role: "assistant", text: "你好")
        let ordered = ConversationMessageMerge.displayOrdered([assistant, pending])
        XCTAssertEqual(ordered.map(\.seq), [-1, 1])
        let items = ConversationMessagePolicy.timelineItems(from: [assistant, pending])
        guard case .message(let first) = items[0], case .message(let second) = items[1] else {
            return XCTFail("应先用户后助手")
        }
        XCTAssertEqual(first.text, "在吗")
        XCTAssertEqual(second.text, "你好")
    }

    func testTimelineShowsPendingUserBubble() {
        let items = ConversationMessagePolicy.timelineItems(from: [
            RichMessage(seq: -1, role: "user", text: "刚发出去", delivery: .pending),
        ])
        XCTAssertEqual(items.count, 1)
        guard case .message(let first) = items[0] else {
            return XCTFail("pending 用户气泡应进入时间线")
        }
        XCTAssertEqual(first.seq, -1)
        XCTAssertEqual(first.delivery, .pending)
        XCTAssertEqual(first.text, "刚发出去")
    }

    func testPromptPolicySplitsQuestionsAndDropsWhenLaterActivity() throws {
        let asking = try message(
            seq: 1,
            role: "assistant",
            tools: [
                [
                    "id": "q1",
                    "name": "AskQuestion",
                    "kind": "question",
                    "summary": "AskQuestion",
                    "status": "running",
                    "questions": [
                        ["summary": "会补上来吗？", "options": ["A", "B", "C", "D"]],
                        ["summary": "哪个助手？", "options": ["Cursor", "Claude Code", "Codex", "Pi"]],
                    ],
                ]
            ]
        )
        let live = ConversationPromptPolicy.pendingPrompts(from: [asking])
        XCTAssertEqual(live.map(\.id), ["q1:0", "q1:1"])
        XCTAssertEqual(live[0].options.count, 4)
        XCTAssertEqual(live[1].summary, "哪个助手？")

        let later = try message(seq: 2, role: "assistant", tools: [tool(id: "g1", name: "grep")])
        XCTAssertTrue(ConversationPromptPolicy.pendingPrompts(from: [asking, later]).isEmpty)
    }

    func testStoreOfficialUserConsumesMatchingLocalPending() async throws {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
        store.enqueueLocalUser("同一句")
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "delta",
            "session": "k",
            "messages": [["seq": 10, "role": "user", "text": "同一句"]],
        ]))
        XCTAssertEqual(store.messages.map(\.seq), [10])
        XCTAssertEqual(store.messages[0].delivery, .sent)
    }

    func testHistoryResetReplacesRenumberedTailAndRetainsPendingSend() async throws {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
        let old = try RemoteJSONDecoder.decode(SessionMessagesResponse.self, from: [
            "generation": 7, "messages": [
                ["seq": 1, "role": "user", "text": "First"],
                ["seq": 99, "role": "assistant", "text": "Wrong old tail"],
            ],
        ])
        store.applySnapshot(old)
        _ = store.enqueueLocalUser("Still sending")
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "history_reset", "session": "k", "generation": 8,
            "oldest_seq": 1, "newest_seq": 2, "resume": "tail", "messages": [
                ["seq": 1, "role": "user", "text": "First"],
                ["seq": 2, "role": "user", "text": "Latest prompt"],
            ],
        ]))
        XCTAssertEqual(store.messages.filter { $0.seq > 0 }.map(\.text), ["First", "Latest prompt"])
        XCTAssertTrue(store.messages.contains { $0.seq < 0 && $0.text == "Still sending" })
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "history_reset", "session": "k", "generation": 7,
            "messages": [["seq": 99, "role": "assistant", "text": "Stale event"]],
        ]))
        XCTAssertFalse(store.messages.contains { $0.seq == 99 })
    }

    func testWatchSnapshotIncludesCurrentExecutionState() throws {
        let data = Data(#"{"messages":[],"attention":"working","live":true}"#.utf8)
        let page = try JSONDecoder().decode(SessionMessagesResponse.self, from: data)
        XCTAssertEqual(page.attention, .working)
        XCTAssertEqual(page.live, true)
        let legacy = try JSONDecoder().decode(SessionMessagesResponse.self, from: Data(#"{"messages":[]}"#.utf8))
        XCTAssertNil(legacy.attention)
        XCTAssertNil(legacy.live)
    }

    func testAttentionWorkingFlag() async {
        let store = ConversationStore(sessionKey: "k", client: nil, live: true)
        XCTAssertFalse(store.isAssistantWorking)
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "attention",
            "attention": "working",
        ]))
        XCTAssertTrue(store.isAssistantWorking)
        XCTAssertEqual(store.attention, .working)
        await store.handle(RemoteEvent(channel: "session:k", data: [
            "kind": "attention",
            "attention": "none",
        ]))
        XCTAssertFalse(store.isAssistantWorking)
    }

    private func message(
        seq: Int,
        role: String,
        text: String? = nil,
        tools: [[String: Any]] = []
    ) throws -> RichMessage {
        var raw: [String: Any] = ["seq": seq, "role": role]
        if let text { raw["text"] = text }
        if !tools.isEmpty { raw["tools"] = tools }
        return try RemoteJSONDecoder.decode(RichMessage.self, from: raw)
    }

    private func tool(id: String, name: String) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "kind": "other",
            "summary": name,
            "status": "completed",
        ]
    }
}
