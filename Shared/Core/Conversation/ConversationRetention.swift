import Foundation

/// Conservative byte estimates for rebuildable conversation state.
///
/// Native clients keep a few inactive panes warm for instant switching. Those
/// caches must bound the whole retained payload — visible text, tool bodies,
/// question prompts and per-message objects — not only the message text a
/// person happens to see. These numbers drive eviction policy; they are not
/// heap measurements and never change history content.
enum ConversationRetention {
    /// Decoded struct, array slot, identifiers and CoW bookkeeping per message.
    nonisolated static let messageOverheadBytes = 256
    /// Per-tool struct, identifiers and optional containers.
    nonisolated static let toolOverheadBytes = 160
    /// Per-prompt struct and its option arrays.
    nonisolated static let promptOverheadBytes = 256
    /// Per-option struct inside a prompt.
    nonisolated static let promptOptionOverheadBytes = 96

    nonisolated static func estimatedBytes(of message: RichMessage) -> Int {
        var total = messageOverheadBytes
        total += message.text?.utf8.count ?? 0
        total += message.failureDetail?.utf8.count ?? 0
        total += message.commandID?.utf8.count ?? 0
        for tool in message.tools ?? [] {
            total += toolOverheadBytes
            total += tool.callID.utf8.count
            total += tool.name.utf8.count
            total += tool.kind.utf8.count
            total += tool.summary.utf8.count
            total += tool.detail?.utf8.count ?? 0
            total += tool.output?.utf8.count ?? 0
            for option in tool.options ?? [] { total += option.utf8.count }
            for group in tool.questions ?? [] {
                total += group.summary?.utf8.count ?? 0
                for option in group.options { total += option.utf8.count }
            }
        }
        return total
    }

    nonisolated static func estimatedBytes(of messages: [RichMessage]) -> Int {
        messages.reduce(0) { $0 + estimatedBytes(of: $1) }
    }

    nonisolated static func estimatedBytes(of prompt: SessionPrompt) -> Int {
        var total = promptOverheadBytes
        for value in [prompt.id, prompt.name, prompt.summary, prompt.detail, prompt.prompt,
                      prompt.header, prompt.requestID, prompt.questionID] {
            total += value?.utf8.count ?? 0
        }
        for option in prompt.options { total += option.utf8.count }
        for detail in prompt.optionDetails {
            total += promptOptionOverheadBytes
            total += detail.id.utf8.count + detail.label.utf8.count
            total += detail.description?.utf8.count ?? 0
        }
        return total
    }

    nonisolated static func estimatedBytes(of prompts: [SessionPrompt]) -> Int {
        prompts.reduce(0) { $0 + estimatedBytes(of: $1) }
    }

    /// Everything a warm pane retains in its conversation store.
    @MainActor
    static func estimatedBytes(of store: ConversationStore) -> Int {
        estimatedBytes(of: store.visibleMessages) + estimatedBytes(of: store.prompts)
    }
}

extension ConversationStore {
    /// Rebuildable payload retained with this store. Used by dormant-pane
    /// admission; reading it never triggers a history read.
    var retainedByteEstimate: Int {
        ConversationRetention.estimatedBytes(of: self)
    }
}
