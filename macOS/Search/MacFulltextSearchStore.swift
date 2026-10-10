import Foundation
import Observation

/// Owns one search panel's requests, including failures and loading cleanup.
@MainActor
@Observable
final class MacFulltextSearchStore {
    private(set) var result: FulltextSearchResponse?
    private(set) var isSearching = false
    private(set) var errorMessage: String?
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
        isSearching = !trimmed.isEmpty
    }

    func invalidate() {
        generation = UUID()
        result = nil
        errorMessage = nil
        isSearching = false
        resultClient = nil
        resultQuery = ""
    }

    func search(_ text: String, client: RemoteClient?, isCurrentClient: (RemoteClient) -> Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == resultQuery, resultClient === client, result != nil, !Task.isCancelled { return }
        prepare(text, client: client)
        let mine = generation
        guard !trimmed.isEmpty, !Task.isCancelled else { return }
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
