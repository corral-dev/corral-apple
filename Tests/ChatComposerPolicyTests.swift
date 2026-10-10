import XCTest
@testable import Corral

/// Platform-neutral stand-in for a staged image: identity + payload + receipt.
/// Lets the suffix tests prove ID/commandID retention with no UIKit.
private struct StagedImage: Equatable {
    let id: UUID
    let base64: String
    let commandID: String?
}

@MainActor
final class ChatComposerPolicyTests: XCTestCase {
    func testTrimmedSendableTextRejectsEmptyWhitespaceAndBusy() {
        XCTAssertNil(ComposerSendPolicy.trimmedSendableText("  \n", isBusy: false))
        XCTAssertNil(ComposerSendPolicy.trimmedSendableText("hello", isBusy: true))
        XCTAssertEqual(ComposerSendPolicy.trimmedSendableText("  hello \n", isBusy: false), "hello")
    }

    func testCannotStartAnotherActionWhileBusy() {
        XCTAssertTrue(ComposerSendPolicy.canStartAction(isBusy: false))
        XCTAssertFalse(ComposerSendPolicy.canStartAction(isBusy: true))
    }

    func testCanSendWithAttachmentsEvenWithoutText() {
        XCTAssertTrue(ComposerSendPolicy.canSend(text: "", attachmentCount: 1, isBusy: false))
        XCTAssertTrue(ComposerSendPolicy.canSend(text: "hi", attachmentCount: 0, isBusy: false))
        XCTAssertFalse(ComposerSendPolicy.canSend(text: "  ", attachmentCount: 0, isBusy: false))
        XCTAssertFalse(ComposerSendPolicy.canSend(text: "hi", attachmentCount: 2, isBusy: true))
    }

    func testFailedSendKeepsTheLaterDraft() {
        XCTAssertEqual(
            ComposerSendPolicy.restoredDraft(failedText: "First message", currentDraft: "Next message"),
            "First message\nNext message"
        )
        XCTAssertEqual(
            ComposerSendPolicy.restoredDraft(failedText: "First message", currentDraft: "First message"),
            "First message"
        )
        XCTAssertEqual(
            ComposerSendPolicy.restoredDraft(failedText: "First message", currentDraft: "  \n"),
            "First message"
        )
    }

    func testUnsentImageSuffixDropsAcknowledgedSuccesses() {
        let images = [
            StagedImage(id: UUID(), base64: "a", commandID: "cmd-a"),
            StagedImage(id: UUID(), base64: "b", commandID: "cmd-b"),
            StagedImage(id: UUID(), base64: "c", commandID: "cmd-c"),
        ]
        let suffix = ComposerSendPolicy.unsentImageSuffix(images: images, sentCount: 1)
        XCTAssertEqual(suffix.map(\.base64), ["b", "c"])
        // The uncertain failure keeps its receipt ID so an explicit retry is idempotent.
        XCTAssertEqual(suffix.map(\.commandID), ["cmd-b", "cmd-c"] as [String?])
        XCTAssertEqual(suffix.map(\.id), [images[1].id, images[2].id])
    }

    func testUnsentImageSuffixBounds() {
        let images = [StagedImage(id: UUID(), base64: "a", commandID: nil)]
        XCTAssertTrue(ComposerSendPolicy.unsentImageSuffix(images: images, sentCount: 1).isEmpty)
        XCTAssertTrue(ComposerSendPolicy.unsentImageSuffix(images: images, sentCount: 9).isEmpty)
        XCTAssertEqual(ComposerSendPolicy.unsentImageSuffix(images: images, sentCount: 0).count, 1)
        XCTAssertEqual(ComposerSendPolicy.unsentImageSuffix(images: [StagedImage](), sentCount: 0).count, 0)
    }

    func testFailedBubbleRetryLeavesDraftUntouched() {
        // A fails while B is typed, so the draft holds A plus B. Retrying
        // bubble A never cleared the composer: its failure must keep the
        // draft instead of prepending A again.
        XCTAssertEqual(
            ComposerSendPolicy.restoredDraft(
                failedText: "A",
                currentDraft: "A\nB",
                didClearComposer: false
            ),
            "A\nB"
        )
        XCTAssertEqual(
            ComposerSendPolicy.restoredDraft(failedText: "A", currentDraft: "B", didClearComposer: false),
            "B"
        )
    }

    func testClearedComposerStillRestoresOnFailure() {
        XCTAssertEqual(
            ComposerSendPolicy.restoredDraft(
                failedText: "A",
                currentDraft: "B",
                didClearComposer: true
            ),
            "A\nB"
        )
        XCTAssertEqual(
            ComposerSendPolicy.restoredDraft(
                failedText: "A",
                currentDraft: "  \n",
                didClearComposer: true
            ),
            "A"
        )
    }
}
