import AppKit
import SwiftTerm

extension MacWorkspace {
    /// Read only product-owned native views; no framework hierarchy rewriting.
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews {
            if let result = descendant(type, in: child) { return result }
        }
        return nil
    }

    func rememberReadingPosition() {
        guard let key = focusedKey, let entry = paneSurfaces.existingEntry(for: key) else { return }
        if mode(for: key) == .terminal,
           let terminal = descendant(StreamTerminalView.self, in: entry.view) {
            navigation.host.reading[key] = .terminal(row: terminal.terminalStateSnapshot().viewportRow,
                followsLatest: !terminal.canScroll || terminal.scrollPosition >= 1)
        } else if let scroll = descendant(MacConversationTable.ConversationScrollView.self, in: entry.view),
                  let coordinator = scroll.coordinator {
            let position = coordinator.navigationPosition
            navigation.host.reading[key] = .chat(id: position.id, offset: Double(position.offset),
                followsLatest: position.followsLatest, generation: entry.store?.promptHistoryGeneration ?? 0)
        }
    }

    func navigateHistory(by step: Int) async {
        await navigateHistory(to: navigation.host.history.index + step)
    }

    func navigateHistory(to index: Int) async {
        guard let feed, !navigation.isNavigating else { return }
        let state = navigation.host
        for key in state.history.keys where feed.listStore.isDeleted(key) { state.history.remove(key) }
        let history = state.history
        guard history.keys.indices.contains(index) else { return }
        let key = history.keys[index]
        let request = UUID()
        navigation.requestID = request
        navigation.isNavigating = true
        defer { if navigation.requestID == request { navigation.isNavigating = false } }
        if ProjectShell.isShellKey(key), shells.shell(for: key) != nil {
            state.history.move(to: index)
            open(key, sessions: feed.listStore.windowSessions, takeKeys: true)
            await restoreReadingPosition(for: key, state: state)
            return
        }
        do {
            guard let session = try await resolveNavigationSession(key), navigation.host === state,
                  navigation.requestID == request, state.history == history else { return }
            feed.listStore.revealSession(session)
            state.history.move(to: index)
            if session.key != key { state.history.replace(key, with: session.key) }
            open(session.key, sessions: feed.listStore.windowSessions, takeKeys: true)
            navigation.reveal(session.key)
            await restoreReadingPosition(for: session.key, state: state)
        } catch {
            guard navigation.host === state, navigation.requestID == request else { return }
            actionError = SessionActionsMenu.failureMessage(for: error)
        }
    }

    private func restoreReadingPosition(for key: String, state: MacNavigationState.HostState) async {
        guard let position = state.reading[key] else { return }
        var loadedEarlier = false
        for _ in 0..<200 {
            guard !Task.isCancelled, navigation.host === state, focusedKey == key else { return }
            if let entry = paneSurfaces.existingEntry(for: key), entry.lifetime.isPresented {
                switch position {
                case let .terminal(row, followsLatest):
                    if let terminal = descendant(StreamTerminalView.self, in: entry.view),
                       terminal.bounds.height > 0, followsLatest || terminal.canScroll {
                        if followsLatest { terminal.scroll(toPosition: 1) }
                        else { terminal.scrollTo(row: row) }
                        return
                    }
                case let .chat(id, offset, followsLatest, generation):
                    if let store = entry.store, !store.messages.isEmpty {
                        guard generation == 0 || store.promptHistoryGeneration == generation else { return }
                        if let scroll = descendant(MacConversationTable.ConversationScrollView.self, in: entry.view),
                           scroll.coordinator?.restoreNavigationPosition(id: id, offset: CGFloat(offset),
                               followsLatest: followsLatest) == true { return }
                        if !loadedEarlier, let id, let seq = id.split(separator: "-").last.flatMap({ Int($0) }) {
                            loadedEarlier = true
                            await store.loadEarlier(through: seq)
                        }
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
    }
}
