#if os(iOS)
import Foundation
import Observation

/// Agent terminals opened for the active host outlive transient detail mounts
/// (Back navigation, session switching, Chat toggles, and split-column relocation),
/// matching `MacTerminalSessions` on macOS. Each keeps its emulator screen,
/// scrollback, and live host stream so returning renders on frame 0 without
/// reconnecting.
@MainActor
@Observable
final class MobileTerminalSessions {
    @MainActor
    @Observable
    final class Terminal {
        fileprivate(set) var key: String
        @ObservationIgnored let view: ShellTerminalHost
        private(set) var stream: RemoteTerminalStream
        var sampledBackground: TerminalRGB?
        @ObservationIgnored fileprivate var lastShown: UInt64 = 0

        fileprivate init(key: String, client: RemoteClient, fontSize: CGFloat) {
            self.key = key
            view = ShellTerminalHost(frame: .zero, fontSize: fontSize)
            // Start unpresented until a slot adopts this host so first adoption
            // runs the full reveal + fit + claimSize path.
            view.setPresented(false)
            stream = RemoteTerminalStream(sessionKey: key, client: client)
            view.bind(stream)
            stream.start()
        }

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

    static let capacity = 16

    private var terminals: [String: Terminal] = [:]
    @ObservationIgnored private var clock: UInt64 = 0

    /// Returns the live retained terminal for `key` on `client`, without creating one.
    func terminal(for key: String, client: RemoteClient?) -> Terminal? {
        guard let client, let terminal = terminals[key],
              terminal.stream.clientIdentity == ObjectIdentifier(client) else { return nil }
        return terminal
    }

    /// Returns (or opens) the retained terminal for `key` and marks it most recently shown.
    @discardableResult
    func open(_ key: String, client: RemoteClient, fontSize: CGFloat = ShellTerminalHost.fontSize) -> Terminal {
        clock &+= 1
        if let terminal = terminals[key] {
            if terminal.stream.clientIdentity != ObjectIdentifier(client) {
                terminal.replaceStream(client: client)
            }
            terminal.lastShown = clock
            return terminal
        }
        let terminal = Terminal(key: key, client: client, fontSize: fontSize)
        terminal.lastShown = clock
        terminals[key] = terminal
        closeLeastRecentlyShown()
        return terminal
    }

    /// Replaces the stream on an existing retained terminal after an explicit restart/resume.
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

    /// Follows provisional-to-canonical key promotion without opening a second stream.
    func migrate(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, let terminal = terminals.removeValue(forKey: oldKey) else { return }
        if terminals[newKey] != nil {
            terminal.close()
            return
        }
        terminal.key = newKey
        terminals[newKey] = terminal
    }

    func reconcileAliases(resolve: (String) -> String) {
        for key in Array(terminals.keys) {
            let canonical = resolve(key)
            if !canonical.isEmpty, canonical != key {
                migrate(from: key, to: canonical)
            }
        }
    }

    /// Drops every terminal when leaving or switching paired hosts.
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
}
#endif
