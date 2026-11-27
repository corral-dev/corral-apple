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
    private var resumeClients: [String: ObjectIdentifier] = [:]
    private var resumingKeys: Set<String> = []
    private var resumedKeys: Set<String> = []
    private var failedStartKeys: Set<String> = []
    @ObservationIgnored private var resumeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var clock: UInt64 = 0

    /// Returns the live retained terminal for `key` on `client`, without creating one.
    func terminal(for key: String, client: RemoteClient?) -> Terminal? {
        guard let client, let terminal = terminals[key],
              terminal.stream.clientIdentity == ObjectIdentifier(client) else { return nil }
        return terminal
    }

    func isResuming(_ key: String, client: RemoteClient?) -> Bool {
        guard let client else { return false }
        return resumingKeys.contains(key) && resumeClients[key] == ObjectIdentifier(client)
    }

    func hasResumed(_ key: String, client: RemoteClient?) -> Bool {
        guard let client else { return false }
        return resumedKeys.contains(key) && resumeClients[key] == ObjectIdentifier(client)
    }

    func hasFailedStart(_ key: String, client: RemoteClient?) -> Bool {
        guard let client else { return false }
        return failedStartKeys.contains(key) && resumeClients[key] == ObjectIdentifier(client)
    }

    /// Starts (or joins) a host-side `session.resume` owned by this pool so
    /// transient `NavigationSplitView` compact push `.onDisappear` events never
    /// cancel an in-flight resume and strand the terminal on `连接中...`.
    func resume(
        _ key: String,
        client: RemoteClient,
        fontSize: CGFloat = ShellTerminalHost.fontSize,
        force: Bool = false
    ) {
        let clientID = ObjectIdentifier(client)
        if resumingKeys.contains(key), resumeClients[key] == clientID {
            return
        }
        if !force, resumedKeys.contains(key), resumeClients[key] == clientID {
            return
        }
        resumeTasks.removeValue(forKey: key)?.cancel()
        resumeClients[key] = clientID
        resumingKeys.insert(key)
        failedStartKeys.remove(key)
        if force {
            resumedKeys.remove(key)
        }
        resumeTasks[key] = Task { @MainActor [weak self, weak client] in
            defer {
                if let self, self.resumeClients[key] == clientID {
                    self.resumingKeys.remove(key)
                    self.resumeTasks[key] = nil
                }
            }
            var attempt = 0
            while !Task.isCancelled, let self, let client,
                  self.resumeClients[key] == clientID, client.state != .disconnected {
                if !force, let existing = self.terminals[key],
                   existing.stream.clientIdentity == clientID,
                   existing.stream.phase != .ended {
                    self.resumedKeys.insert(key)
                    return
                }
                do {
                    _ = try await client.call(WireProtocol.mSessionResume, params: ["key": key])
                    guard !Task.isCancelled, self.resumeClients[key] == clientID else { return }
                    self.resumedKeys.insert(key)
                    self.failedStartKeys.remove(key)
                    self.restart(key, client: client, fontSize: fontSize)
                    return
                } catch {
                    guard !Task.isCancelled, self.resumeClients[key] == clientID,
                          client.state != .disconnected else { return }
                    switch RemoteRecoveryPolicy.classify(error) {
                    case .retryable:
                        let delay = RemoteRecoveryPolicy.backoffDuration(attempt: attempt)
                        attempt += 1
                        try? await Task.sleep(for: delay)
                        continue
                    case .notFound, .permanent:
                        self.failedStartKeys.insert(key)
                        return
                    }
                }
            }
        }
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
    func restart(_ key: String, client: RemoteClient, fontSize: CGFloat = ShellTerminalHost.fontSize) -> Terminal {
        guard let terminal = terminals[key] else { return open(key, client: client, fontSize: fontSize) }
        clock &+= 1
        terminal.lastShown = clock
        terminal.replaceStream(client: client)
        return terminal
    }

    func close(_ key: String) {
        resumeTasks.removeValue(forKey: key)?.cancel()
        resumeClients.removeValue(forKey: key)
        resumingKeys.remove(key)
        resumedKeys.remove(key)
        failedStartKeys.remove(key)
        terminals.removeValue(forKey: key)?.close()
    }

    /// Follows provisional-to-canonical key promotion without opening a second stream.
    func migrate(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        if let oldClient = resumeClients.removeValue(forKey: oldKey) {
            if resumeClients[newKey] == nil {
                resumeClients[newKey] = oldClient
            }
        }
        if let oldTask = resumeTasks.removeValue(forKey: oldKey) {
            if resumeTasks[newKey] == nil {
                resumeTasks[newKey] = oldTask
            } else {
                oldTask.cancel()
            }
        }
        if resumingKeys.remove(oldKey) != nil { resumingKeys.insert(newKey) }
        if resumedKeys.remove(oldKey) != nil { resumedKeys.insert(newKey) }
        if failedStartKeys.remove(oldKey) != nil { failedStartKeys.insert(newKey) }
        guard let terminal = terminals.removeValue(forKey: oldKey) else { return }
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
        for task in resumeTasks.values { task.cancel() }
        resumeTasks.removeAll()
        resumeClients.removeAll()
        resumingKeys.removeAll()
        resumedKeys.removeAll()
        failedStartKeys.removeAll()
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
