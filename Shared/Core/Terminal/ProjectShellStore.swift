import Foundation

/// A login shell the host runs in a project folder (`shell.list` row). Its
/// screen is a `RemoteTerminalStream` on `key`.
nonisolated struct ProjectShell: Decodable, Sendable, Equatable, Identifiable {
    let key: String
    /// Folder the shell started in.
    let project: String
    /// Last path component of `project`.
    let name: String
    let cwd: String
    /// Foreground program (`zsh` when idle).
    let command: String
    /// A program other than the shell is running: closing asks first.
    let busy: Bool
    let created: Int

    var id: String { key }

    /// Stream keys of project shells (`shell:<id>`); everything else is an agent session.
    static func isShellKey(_ key: String) -> Bool { key.hasPrefix("shell:") }

    /// Tab title: the folder, plus the running program when it is not the shell.
    var title: String {
        busy && !command.isEmpty ? "\(name) · \(command)" : name
    }
}

private nonisolated struct ShellListPayload: Decodable, Sendable {
    let shells: [ProjectShell]
}

private nonisolated struct ShellOpenPayload: Decodable, Sendable {
    let shell: ProjectShell
}

/// The project terminal's shells on the selected machine and the one shown.
/// Shells live on the host; this store only mirrors `shell.list` and keeps the
/// selection. One store per machine: `reset()` on machine switch.
@MainActor
@Observable
final class ProjectShellStore {
    private(set) var shells: [ProjectShell] = []
    private(set) var isWorking = false
    var selectedKey: String?
    /// Host error text from the last failed open or close.
    var failure: String?

    var selected: ProjectShell? { shells.first { $0.key == selectedKey } }

    /// In-flight list fetch, so N shell panes reconnecting at once share one RPC.
    private var refreshTask: Task<Bool, Never>?

    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        shells = []
        selectedKey = nil
        failure = nil
        isWorking = false
    }

    @discardableResult
    func refresh(client: RemoteClient) async -> Bool {
        // Coalesce concurrent refreshes (one per shell pane per reconnect)
        // into a single host RPC.
        if let inFlight = refreshTask {
            return await inFlight.value
        }
        let task = Task { () -> Bool in
            do {
                let payload = try await client.call(WireProtocol.mShellList, as: ShellListPayload.self)
                apply(payload.shells)
                return true
            } catch {
                return false
            }
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// Shows the project's shell: the selected one when it is already in that
    /// folder, else the newest shell of the folder, else a new one there.
    func show(project: String, client: RemoteClient) async {
        await refresh(client: client)
        if let selected, selected.project == project || project.isEmpty { return }
        if let existing = shells.last(where: { $0.project == project }) {
            selectedKey = existing.key
            return
        }
        if project.isEmpty, let last = shells.last {
            selectedKey = last.key
            return
        }
        await open(project: project, client: client)
    }

    /// Starts a new shell in `project` (the host's home folder when empty) and selects it.
    @discardableResult
    func open(project: String, grid: TerminalGrid? = nil, client: RemoteClient) async -> ProjectShell? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            var params: [String: Any] = ["cwd": project]
            if let grid {
                // Start at the size the view will vote, so the first screen needs no resize.
                params["cols"] = grid.cols
                params["rows"] = grid.rows
            }
            let payload = try await client.call(WireProtocol.mShellOpen, params: params, as: ShellOpenPayload.self)
            failure = nil
            if !shells.contains(where: { $0.key == payload.shell.key }) {
                shells.append(payload.shell)
            }
            selectedKey = payload.shell.key
            return payload.shell
        } catch {
            failure = Self.message(for: error)
            return nil
        }
    }

    func shell(for key: String) -> ProjectShell? { shells.first { $0.key == key } }

    /// Whether `key` is running a program right now (fresh from the host), so
    /// closing can ask first.
    func isBusy(_ key: String, client: RemoteClient) async -> Bool {
        await refresh(client: client)
        return shells.first { $0.key == key }?.busy ?? false
    }

    func close(_ key: String, client: RemoteClient) async {
        do {
            _ = try await client.call(WireProtocol.mShellClose, params: ["key": key])
            removeEnded(key)
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// The shell exited (`ended` on its stream) or was closed: drop it and
    /// select its neighbour.
    func removeEnded(_ key: String) {
        guard let index = shells.firstIndex(where: { $0.key == key }) else { return }
        shells.remove(at: index)
        if selectedKey == key {
            selectedKey = shells.indices.contains(index) ? shells[index].key : shells.last?.key
        }
    }

    func select(offset: Int) {
        guard !shells.isEmpty else { return }
        let current = shells.firstIndex { $0.key == selectedKey } ?? 0
        selectedKey = shells[(current + offset + shells.count) % shells.count].key
    }

    private func apply(_ next: [ProjectShell]) {
        shells = next
        if let selectedKey, !next.contains(where: { $0.key == selectedKey }) {
            self.selectedKey = next.last?.key
        }
    }

    static func message(for error: Error) -> String {
        if let remote = error as? RemoteCallError, !remote.message.isEmpty { return remote.message }
        if let described = error as? LocalizedError, let text = described.errorDescription, !text.isEmpty {
            return text
        }
        return String(localized: String.LocalizationValue("error.unknown"))
    }
}
