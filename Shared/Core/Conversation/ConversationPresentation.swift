import Foundation
import Observation

/// A selected conversation, independent of transient native detail-view mounts.
/// Only a real selection/host/client change retires its watch.
@MainActor
@Observable
final class ConversationPresentation {
    private(set) var store: ConversationStore?
    @ObservationIgnored private var sessionKey: String?
    @ObservationIgnored private var hostID: String?
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var suspension: Task<Void, Never>?

    @discardableResult
    func present(
        sessionKey: String,
        hostID: String,
        client: RemoteClient?,
        live: Bool,
        attention: AttentionKind
    ) -> ConversationStore {
        if self.sessionKey == sessionKey, self.hostID == hostID,
           let store, store.boundClient === client {
            return store
        }
        dismiss()
        let next = ConversationStore(
            sessionKey: sessionKey, client: client, live: live,
            attention: attention, hostID: hostID
        )
        self.sessionKey = sessionKey
        self.hostID = hostID
        store = next
        let previous = suspension
        // A rendering task may already be cancelled by split-column relocation.
        // Selection owns this task; caller cancellation must not cancel its load.
        activation = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.store === next else { return }
            await next.start()
        }
        return next
    }

    func dismiss() {
        activation?.cancel()
        activation = nil
        sessionKey = nil
        hostID = nil
        guard let previousStore = store else { return }
        store = nil
        let previous = suspension
        suspension = Task {
            await previous?.value
            await previousStore.stop()
        }
    }
}
