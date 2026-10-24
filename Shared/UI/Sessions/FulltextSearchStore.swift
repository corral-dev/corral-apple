import Foundation
import Observation

/// Owns one full-text search surface's requests (Mac ⌘F panel, iPhone list
/// search), including failures and loading cleanup.
@MainActor
@Observable
final class FulltextSearchStore {
    private(set) var result: FulltextSearchResponse?
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    /// The host predates `search.fulltext`; callers keep their older search.
    private(set) var isUnsupported = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private weak var resultClient: RemoteClient?
    @ObservationIgnored private var resultQuery = ""

    /// Feedback starts with the edit, before the debounce timer fires.
    func prepare(_ text: String, client: RemoteClient?) {
        generation = UUID()
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed == resultQuery, resultClient === client, result != nil {
            isSearching = false
            return
        }
        result = nil
        isSearching = !trimmed.isEmpty && !(isUnsupported && resultClient === client)
    }

    func invalidate() {
        generation = UUID()
        isUnsupported = false
        result = nil
        errorMessage = nil
        isSearching = false
        resultClient = nil
        resultQuery = ""
    }

    /// Closing a search surface cancels work, not the accepted search context.
    func cancelPending() {
        generation = UUID()
        isSearching = false
    }

    func search(_ text: String, client: RemoteClient?, isCurrentClient: (RemoteClient) -> Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == resultQuery, resultClient === client, result != nil, !Task.isCancelled { return }
        prepare(text, client: client)
        let mine = generation
        guard !trimmed.isEmpty, !Task.isCancelled else { return }
        if isUnsupported, resultClient === client { return }
        guard let client else {
            errorMessage = String(localized: String.LocalizationValue("error.not_connected"))
            isSearching = false
            return
        }
        isSearching = true
        defer {
            if generation == mine { isSearching = false }
        }
        for attempt in 0..<3 {
            do {
                let response = try await client.call(
                    WireProtocol.mSearchFulltext, params: ["q": trimmed, "top": 40], as: FulltextSearchResponse.self
                )
                guard generation == mine, !Task.isCancelled, isCurrentClient(client) else { return }
                result = response
                resultQuery = trimmed
                resultClient = client
                return
            } catch {
                guard generation == mine, !Task.isCancelled, isCurrentClient(client) else { return }
                if let remote = error as? RemoteCallError, remote.code == WireProtocol.eUsage {
                    // Hosts before CLI 0.24.255 answer unknown methods with usage_error.
                    isUnsupported = true
                    resultClient = client
                    return
                }
                if attempt == 2 {
                    errorMessage = SessionActionsMenu.failureMessage(for: error)
                    return
                }
                // Search is read-only. A ready connection can still be attaching
                // its data plane, or recovering between the query and its reply.
                do { try await Task.sleep(for: .milliseconds(200 * (attempt + 1))) }
                catch { return }
                guard generation == mine, !Task.isCancelled, isCurrentClient(client) else { return }
            }
        }
    }
}
