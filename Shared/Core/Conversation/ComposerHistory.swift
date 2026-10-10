import Foundation

/// Up/Down recall of this session's own prompts in the composer, shell style.
/// Entries are oldest first; browsing starts at the newest and stepping past it
/// restores the draft that was there before browsing began.
nonisolated struct ComposerHistory: Equatable, Sendable {
    /// Index into the entries currently shown; nil while not browsing.
    private(set) var index: Int?
    private var savedDraft = ""
    private var shown: String?

    var isBrowsing: Bool { index != nil }

    /// True when the field still shows the recalled entry untouched.
    func isShowingUnchanged(_ text: String) -> Bool {
        index != nil && shown == text
    }

    /// One step older; nil when there is nothing older to show.
    mutating func older(entries: [String], current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        let next: Int
        if let index {
            next = min(index, entries.count) - 1
        } else {
            savedDraft = current
            next = entries.count - 1
        }
        guard next >= 0 else { return nil }
        return show(entries[next], at: next)
    }

    /// One step newer; past the newest entry the saved draft comes back.
    /// Nil when not browsing.
    mutating func newer(entries: [String]) -> String? {
        guard let index else { return nil }
        let next = index + 1
        guard next < entries.count else {
            let draft = savedDraft
            reset()
            return draft
        }
        return show(entries[next], at: next)
    }

    mutating func reset() {
        index = nil
        savedDraft = ""
        shown = nil
    }

    private mutating func show(_ entry: String, at position: Int) -> String {
        index = position
        shown = entry
        return entry
    }
}
