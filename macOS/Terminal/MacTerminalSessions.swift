import AppKit
import Observation

/// Terminals opened in this window outlive the panes that show them, as tabs
/// do in a terminal app (owner correction 2026-10-25): each keeps its emulator
/// screen and its host stream while hidden, so showing it again re-parents the
/// same view instead of attaching anew. A hidden terminal keeps receiving
/// output (SwiftTerm draws nothing without a window), keeps its last size vote
/// without claiming the grid, and owns no focus or hit target.
/// See docs/design/MACOS_CLIENT_DESIGN.md#terminals-outlive-their-panes-owner-correction-2026-10-25.
@MainActor
@Observable
final class MacTerminalSessions {
    /// One agent or project-shell terminal: the emulator and its host stream.
    @MainActor
    @Observable
    final class Terminal {
        let key: String
        @ObservationIgnored let view: TerminalHostView
        private(set) var stream: RemoteTerminalStream
        @ObservationIgnored fileprivate var lastShown: UInt64 = 0

        fileprivate init(key: String, client: RemoteClient) {
            self.key = key
            view = TerminalHostView()
            stream = RemoteTerminalStream(sessionKey: key, client: client)
            view.bind(stream)
            stream.start()
        }

        /// A new host stream on the same emulator: its last screen stays on
        /// display until the new stream's snapshot replaces it.
        fileprivate func replaceStream(client: RemoteClient) {
            stream.stop()
            stream = RemoteTerminalStream(sessionKey: key, client: client)
            view.bind(stream)
            stream.start()
        }

        fileprivate func close() {
            stream.stop()
            view.unbind()
            view.removeFromSuperview()
        }
    }

    /// Terminals kept alive per window; the least recently shown one closes
    /// first, and a terminal on screen is never closed for room.
    static let capacity = 16

    private var terminals: [String: Terminal] = [:]
    @ObservationIgnored private var clock: UInt64 = 0

    /// The live terminal for `key` on `client`, without creating one.
    func terminal(for key: String, client: RemoteClient?) -> Terminal? {
        guard let client, let terminal = terminals[key],
              terminal.stream.clientIdentity == ObjectIdentifier(client) else { return nil }
        return terminal
    }

    /// The terminal for `key`, opened on first use and marked as just shown.
    @discardableResult
    func open(_ key: String, client: RemoteClient) -> Terminal {
        clock &+= 1
        if let terminal = terminals[key] {
            if terminal.stream.clientIdentity != ObjectIdentifier(client) {
                terminal.replaceStream(client: client)
            }
            terminal.lastShown = clock
            return terminal
        }
        let terminal = Terminal(key: key, client: client)
        terminal.lastShown = clock
        terminals[key] = terminal
        closeLeastRecentlyShown()
        return terminal
    }

    /// The session was started again: attach a new stream to the same emulator.
    @discardableResult
    func restart(_ key: String, client: RemoteClient) -> Terminal {
        guard let terminal = terminals[key] else { return open(key, client: client) }
        clock &+= 1
        terminal.lastShown = clock
        terminal.replaceStream(client: client)
        return terminal
    }

    func close(_ key: String) {
        terminals.removeValue(forKey: key)?.close()
    }

    /// Another machine: none of these terminals belong to it.
    func reset() {
        for terminal in terminals.values { terminal.close() }
        terminals.removeAll()
    }

    private func closeLeastRecentlyShown() {
        while terminals.count > Self.capacity,
              let oldest = terminals.values.filter({ !$0.view.isShown }).min(by: { $0.lastShown < $1.lastShown }) {
            close(oldest.key)
        }
    }

    #if DEBUG
    var inspectionCount: Int { terminals.count }
    #endif
}
