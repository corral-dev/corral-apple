import Foundation
@testable import Corral
import XCTest

/// One send is one bubble (owner report 2026-11-15).
///
/// The host attaches phone images by pasting a saved path
/// (`<cwd>/.corral-pastes/paste-….jpg`) into the agent composer, so the
/// confirmed user turn reads `"<path><typed text>"`. Echo de-duplication and
/// the bubble body must treat that path as the attachment, otherwise one
/// image+text send shows three bubbles: the typed text, `[image]`, and the
/// confirmed turn (screenshot order).
@MainActor
final class ConversationEchoAttachmentTests: XCTestCase {
    private let pastePath = "/Users/example/Codes/Corral/.corral-pastes/paste-moofu3ap.jpg"
    private let typed = "这不对 最新消息早就不是这条报错了"

    // MARK: - Body derivation

    func testPastedPathIsAnAttachmentNotBodyText() {
        let text = pastePath + typed
        XCTAssertEqual(HostPasteAttachment.paths(in: text), [pastePath])
        XCTAssertEqual(HostPasteAttachment.body(text), typed)
        XCTAssertTrue(HostPasteAttachment.isAttachmentOnly(pastePath))
    }

    func testBodyCoversTempFallbackAndMidSentencePastes() {
        let temp = "/var/folders/x/T/corral-pastes/paste-a1b2c3d4.png"
        XCTAssertEqual(HostPasteAttachment.body("看这个\(temp)然后继续"), "看这个然后继续")
        XCTAssertEqual(HostPasteAttachment.body("\(temp) \(pastePath)"), "")
        // Ordinary prose that merely mentions a file is untouched.
        XCTAssertEqual(HostPasteAttachment.body("看 /tmp/notes.jpg 这个"), "看 /tmp/notes.jpg 这个")
        XCTAssertEqual(HostPasteAttachment.paths(in: "普通的句子"), [])
    }

    // MARK: - Echo merge

    func testOneImageTextSendEndsAsOneBubble() {
        let official = RichMessage(seq: 9, role: "user", text: pastePath + typed)
        var echo = RichMessage(
            seq: -1, role: "user", text: typed, delivery: .accepted, localAfterSeq: 8
        )
        echo.localImageData = [Data([0xFF, 0xD8])]

        let merged = ConversationMessageMerge.combining([echo], with: [official])
        XCTAssertEqual(merged.map(\.seq), [9])
    }

    func testImageOnlySendEndsAsOneBubble() {
        let official = RichMessage(seq: 9, role: "user", text: pastePath)
        var echo = RichMessage(seq: -1, role: "user", text: "", delivery: .accepted, localAfterSeq: 8)
        echo.localImageData = [Data([0xFF, 0xD8])]

        let merged = ConversationMessageMerge.combining([echo], with: [official])
        XCTAssertEqual(merged.map(\.seq), [9])
    }

    func testTwoImagesStageOneBubbleAndKeepTheirReceipts() async throws {
        let coordinator = ConversationSendCoordinator()
        let store = FakeSendStore()
        store.supportsCommandReceipts = true
        let display = FakeSendDisplay()
        let images = [
            StagedSendImage(id: UUID(), base64: "a", commandID: nil),
            StagedSendImage(id: UUID(), base64: "b", commandID: nil),
        ]

        let plan = try XCTUnwrap(coordinator.beginComposerSend(
            store: store, display: display, text: "看图", images: images,
            isBusy: false, isHostReady: true
        ))
        // One bubble for the whole send, carrying both images and the text.
        XCTAssertEqual(store.messages.count, 1)
        let bubble = try XCTUnwrap(store.messages.first)
        XCTAssertEqual(bubble.text, "看图")
        XCTAssertEqual(bubble.localImageData.count, 2)
        XCTAssertEqual(plan.echoSeq, bubble.seq)
        XCTAssertFalse(store.messages.contains { $0.text == "[image]" })

        await coordinator.runComposerSend(plan, store: store, display: display)

        XCTAssertEqual(store.orderedEvents, ["image:a", "image:b", "text:看图"])
        // Both image identities and the text identity belong to this one send.
        XCTAssertEqual(Set(plan.ownCommandIDs).count, 3)
        XCTAssertEqual(store.messages.count, 1)
    }

    func testImageOnlySendStagesOneBubbleWithItsImages() async throws {
        let coordinator = ConversationSendCoordinator()
        let store = FakeSendStore()
        store.supportsCommandReceipts = false
        let display = FakeSendDisplay()
        let images = [StagedSendImage(id: UUID(), base64: "a", commandID: nil)]

        let plan = try XCTUnwrap(coordinator.beginComposerSend(
            store: store, display: display, text: "", images: images,
            isBusy: false, isHostReady: true
        ))
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "")
        XCTAssertEqual(store.messages.first?.localImageData.count, 1)
        XCTAssertEqual(plan.echoSeq, store.messages.first?.seq)

        await coordinator.runComposerSend(plan, store: store, display: display)

        // Legacy host: the acknowledged image settles the single bubble.
        XCTAssertEqual(store.messages.first?.delivery, .sent)
        XCTAssertEqual(store.sentTexts.map(\.text), [""])
    }

    func testTimelineKeepsAttachmentOnlyBubbles() {
        var echo = RichMessage(seq: -1, role: "user", text: "", delivery: .pending)
        echo.localImageData = [Data([0xFF, 0xD8])]
        let official = RichMessage(seq: 9, role: "user", text: pastePath)

        let items = ConversationMessagePolicy.timelineItems(from: [echo, official])
        XCTAssertEqual(items.compactMap { item -> Int? in
            guard case .message(let message) = item else { return nil }
            return message.seq
        }, [-1, 9])
    }

    func testSameTextSentTwicePairsEchoesInOrder() {
        let first = RichMessage(seq: -1, role: "user", text: "继续", delivery: .accepted, localAfterSeq: 4)
        let second = RichMessage(seq: -2, role: "user", text: "继续", delivery: .pending, localAfterSeq: 4)
        let official = RichMessage(seq: 5, role: "user", text: "继续")

        let merged = ConversationMessageMerge.combining([first, second], with: [official])
        // Only the confirmed first send is consumed; the pending second stays.
        XCTAssertEqual(merged.map(\.seq), [-2, 5])
    }

    func testEchoBeforeSendAnchorIsNotConsumed() {
        let pending = RichMessage(seq: -1, role: "user", text: "继续", delivery: .pending, localAfterSeq: 7)
        let older = RichMessage(seq: 6, role: "user", text: "继续")

        let merged = ConversationMessageMerge.combining([pending], with: [older])
        XCTAssertEqual(Set(merged.map(\.seq)), [-1, 6])
    }

    func testImageReceiptSettlesTheSharedBubble() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-echo-pending-\(UUID().uuidString)", isDirectory: true)
        PendingCommandStore.directoryOverride = root
        defer {
            PendingCommandStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let store = ConversationStore(sessionKey: "k", client: nil, live: false, hostID: "host")
        let seq = store.enqueueLocalUser(
            "", commandID: "image-1", reusingSeq: nil, images: [Data([0xFF, 0xD8])]
        )
        // The second image's identity is not on the bubble; the pending record
        // still resolves its late receipt to the single bubble.
        store.recordPendingCommand(commandID: "image-2", text: "", localSeq: seq)
        store.applyCommandStatus(commandID: "image-2", status: "rejected", failureDetail: "upload failed")

        XCTAssertEqual(store.messages.first?.delivery, .failed)
        XCTAssertEqual(store.messages.first?.failureDetail, "upload failed")
    }

    // MARK: - Legacy cache

    func testLegacyImagePlaceholdersAreDroppedOnCacheLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-echo-cache-\(UUID().uuidString)", isDirectory: true)
        ConversationTailCache.directoryOverride = root
        defer {
            ConversationTailCache.directoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let official = RichMessage(seq: 9, role: "user", text: pastePath + typed)
        // A cache written by the previous build: one `[image]` bubble per image
        // plus the text bubble, neither able to pair with the confirmed turn.
        let legacy = [
            RichMessage(seq: -1, role: "user", text: typed, delivery: .accepted, localAfterSeq: 8),
            RichMessage(seq: -2, role: "user", text: "[image]", delivery: .sent, localAfterSeq: 8),
            official,
        ]
        ConversationTailCache.save(ConversationTailSnapshot(
            hostID: "host", sessionKey: "k", messages: legacy,
            oldestSequence: 9, newestSequence: 9, hasMoreHistory: false,
            generation: 1, savedAt: Date()
        ))

        let store = ConversationStore(sessionKey: "k", client: nil, live: false, hostID: "host")
        let userSeqs = store.visibleMessages.filter { $0.role == "user" }.map(\.seq)
        XCTAssertEqual(userSeqs, [9])
    }

    func testFilePastePathsStripCleanlyAndKeepFileOnlyTurnsVisible() {
        let pastedFile = "/Users/example/project/.corral-pastes/paste-ab12cd34-设计方案.md"
        let multiDot = "/Users/example/project/.corral-pastes/paste-xy99zz11-archive.tar.gz"
        XCTAssertEqual(HostPasteAttachment.filePaths(in: pastedFile + "帮我看看"), [pastedFile])
        XCTAssertEqual(HostPasteAttachment.filePaths(in: multiDot + " please check"), [multiDot])
        XCTAssertEqual(HostPasteAttachment.displayName(forPastedFilePath: multiDot), "archive.tar.gz")
        XCTAssertEqual(HostPasteAttachment.body(multiDot + " please check"), "please check")
        XCTAssertEqual(HostPasteAttachment.displayName(forPastedFilePath: pastedFile), "设计方案.md")
        XCTAssertEqual(HostPasteAttachment.body(pastedFile + "帮我看看"), "帮我看看")
        XCTAssertTrue(HostPasteAttachment.isAttachmentOnly(pastedFile))
        XCTAssertFalse(HostPasteAttachment.isAttachmentOnly(pastedFile + " 帮我看看"))

        let officialFileOnly = RichMessage(seq: 11, role: "user", text: pastedFile)
        let echoFileOnly = RichMessage(
            seq: -1,
            role: "user",
            text: "",
            delivery: .pending,
            localFiles: [LocalFileAttachment(name: "spec.pdf", byteCount: 1024)]
        )
        let rows = ConversationMessagePolicy.timelineItems(from: [officialFileOnly, echoFileOnly])
        XCTAssertEqual(rows.compactMap { row -> Int? in
            if case let .message(msg) = row { return msg.seq }
            return nil
        }, [-1, 11])
    }
}
