import CoreGraphics
import Foundation

/// 会话输入发送互斥：先清空再发，避免连点把同一条发出去。
enum ComposerSendPolicy {
    static let maxAttachments = 6

    static func trimmedSendableText(_ text: String, isBusy: Bool) -> String? {
        guard !isBusy else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func canStartAction(isBusy: Bool) -> Bool {
        !isBusy
    }

    /// Send is allowed when there is non-empty text and/or at least one staged image.
    static func canSend(text: String, attachmentCount: Int, isBusy: Bool) -> Bool {
        guard !isBusy else { return false }
        if attachmentCount > 0 { return true }
        return trimmedSendableText(text, isBusy: false) != nil
    }

    /// Recovery must retain anything typed while the previous send was awaiting delivery.
    static func restoredDraft(failedText: String, currentDraft: String) -> String {
        guard !currentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failedText
        }
        guard currentDraft != failedText else { return currentDraft }
        return failedText + "\n" + currentDraft
    }

    /// A bubble retry never cleared the composer, so its failure must leave the
    /// draft untouched. `didClearComposer` carries the send's clearDraftOnStart:
    /// only a send that cleared the composer restores its payload on failure.
    static func restoredDraft(failedText: String, currentDraft: String, didClearComposer: Bool) -> String {
        guard didClearComposer else { return currentDraft }
        return restoredDraft(failedText: failedText, currentDraft: currentDraft)
    }

    /// After a partial multi-image failure, only the failed/not-yet-attempted
    /// suffix returns to the composer. Acknowledged successes must not be sent
    /// a second time. The suffix keeps its staged elements untouched (including
    /// any receipt command ID) so the user's explicit retry reuses the
    /// original ID. Element-generic so portable tests need no UIKit.
    static func unsentImageSuffix<Element>(images: [Element], sentCount: Int) -> [Element] {
        guard sentCount < images.count else { return [] }
        return Array(images.dropFirst(max(0, sentCount)))
    }
}
