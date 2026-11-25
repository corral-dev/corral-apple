import SwiftUI

/// Single-session menu shared across the sidebar row context menu, pane
/// surface context menu, and pane bottom bar kebab button.
struct MacSessionMenuItems: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    let session: SessionSummary

    /// `.tint(nil)` keeps the symbols template images: an inherited tint is
    /// baked into them, so a highlighted row's icon vanished into the
    /// same-colour highlight while its text inverted (owner report 0.3.127).
    var body: some View {
        items.labelStyle(.titleAndIcon).tint(nil)
    }

    private var connected: Bool { appModel.client?.state == .ready }
    /// A read-only pairing still switches views, exports sessions and copies paths;
    /// mutating session actions are unavailable.
    private var readonly: Bool { SessionActionsMenu.isReadonly(access: appModel.connectedAccess) }
    private var canMutate: Bool { connected && !readonly }

    private var currentMode: MacWorkspace.PaneMode { workspace.mode(for: session.key) }
    private var targetMode: MacWorkspace.PaneMode { currentMode == .chat ? .terminal : .chat }
    private var isShownPane: Bool { workspace.isShownPane(session.key) }

    /// TUI pin semantics: a split member's pin belongs to the whole split.
    private var isSplit: Bool { workspace.layout.group(containing: session.key) != nil }
    private var pinned: Bool { workspace.layout.isPinned(session.key) }
    private var pinTitle: LocalizedStringKey {
        if isSplit { return pinned ? "mac.group.unpin" : "mac.group.pin" }
        return pinned ? "mac.session.unpin" : "mac.session.pin"
    }

    @ViewBuilder
    private var items: some View {
        Button {
            workspace.switchModeAndOpen(targetMode, for: session)
        } label: {
            Label(
                targetMode == .terminal ? "mac.pane.switch_to_terminal" : "mac.pane.switch_to_chat",
                systemImage: targetMode == .terminal ? "terminal" : "bubble.left.and.text.bubble.right"
            )
        }
        Divider()
        Button {
            workspace.addPane(session.key, project: session.cwd)
        } label: {
            Label("mac.session.open_in_split", systemImage: "rectangle.split.2x1")
        }
        .disabled(workspace.paneKeys.isEmpty || isShownPane || !workspace.canAddSessionToSplit(session))
        Button {
            Task { await workspace.togglePin(session.key) }
        } label: {
            Label(pinTitle, systemImage: pinned ? "pin.slash" : "pin")
        }
        .disabled(!canMutate)
        Divider()
        Button {
            Task { await workspace.fork(session) }
        } label: {
            Label("session.actions.copy", systemImage: SessionActionsMenu.forkSymbol)
        }
        .disabled(!canMutate)
        Menu {
            if workspace.runtimeCatalog.isLoading {
                Text("session.actions.handoff.loading")
            } else if let error = workspace.runtimeCatalog.errorMessage {
                Text(verbatim: error)
                Button("action.retry", systemImage: "arrow.clockwise") {
                    Task { await workspace.retryRuntimes() }
                }
            } else if !workspace.runtimeCatalog.isLoaded {
                Button("action.retry", systemImage: "arrow.clockwise") {
                    Task { await workspace.retryRuntimes() }
                }
            } else if SessionActionsMenu.handoffTargets(from: workspace.runtimes).isEmpty {
                Text("session.actions.handoff.empty")
            }
            ForEach(SessionActionsMenu.handoffTargets(from: workspace.runtimes)) { runtime in
                Button {
                    Task { await workspace.handoff(session, to: runtime.id) }
                } label: {
                    Text(verbatim: runtime.name ?? runtime.id)
                }
            }
        } label: {
            Label("mac.session.continue_with", systemImage: SessionActionsMenu.handoffSymbol)
        }
        .disabled(!canMutate)
        Button {
            Task { await workspace.exportSession(session.key) }
        } label: {
            Label("mac.session.export", systemImage: "square.and.arrow.up")
        }
        .disabled(!connected || appModel.client?.hostCapabilities.sessionExport != true)
        Button {
            Task { await workspace.restart(session.key) }
        } label: {
            Label("session.actions.restart", systemImage: "arrow.clockwise")
        }
        .disabled(!canMutate || appModel.client?.hostCapabilities.sessionRestart != true)
        if session.live {
            Button {
                Task { await workspace.stop(session.key) }
            } label: {
                Label("sessions.action.stop", systemImage: "stop.fill")
            }
            .disabled(!canMutate || workspace.isStopping(session.key))
        }
        Divider()
        let corralID = session.resolvedCorralID
        Button {
            workspace.copyCorralID(corralID, key: session.key)
        } label: {
            Label("session.actions.copy_corral_id", systemImage: "doc.on.doc")
            if !corralID.isEmpty {
                Text(verbatim: corralID)
            }
        }
        .disabled(corralID.isEmpty)
        Button {
            PlatformPasteboard.copy(SessionPresentation.fullWorkspacePath(from: session))
        } label: {
            Label("session.workspace.copy_path", systemImage: "folder")
        }
        Button {
            workspace.requestClose(session.key)
        } label: {
            Label("mac.pane.close", systemImage: "xmark")
        }
        .disabled(!isShownPane)
        Divider()
        Button(role: .destructive) {
            workspace.requestDelete([session])
        } label: {
            Label("sessions.action.delete", systemImage: "trash")
        }
        .disabled(!canMutate || workspace.batch.isRunning)
    }
}

/// Multi-selection menu shown from the sidebar context menu and bottom bar
/// Actions menu when two or more sessions are selected.
struct MacBatchSessionMenuItems: View {
    @Environment(MacWorkspace.self) private var workspace
    let targets: [SessionSummary]
    let canMutate: Bool
    let perform: (MacSessionBatch.Action, [SessionSummary]) -> Void

    var body: some View {
        items.labelStyle(.titleAndIcon).tint(nil)
    }

    @ViewBuilder
    private var items: some View {
        Button {
            workspace.openSplit(targets)
        } label: {
            Label("mac.session.open_in_split", systemImage: "rectangle.split.2x1")
        }
        .disabled(!workspace.canOpenAsSplit(targets))
        let corralIDs = batchCorralIDs(from: targets)
        Button {
            workspace.copyCorralIDs(corralIDs)
        } label: {
            Label("mac.sessions.copy_corral_ids", systemImage: "doc.on.doc")
        }
        .disabled(corralIDs.isEmpty)
        Button {
            var seen: Set<String> = []
            let paths = targets.map(SessionPresentation.fullWorkspacePath)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            PlatformPasteboard.copy(paths.joined(separator: "\n"))
        } label: {
            Label("mac.sessions.copy_paths", systemImage: "folder")
        }
        Divider()
        let pinned = targets.filter { workspace.layout.isPinned($0.key) }
        let unpinned = targets.filter { !workspace.layout.isPinned($0.key) }
        let busy = workspace.batch.isRunning
        if !unpinned.isEmpty {
            Button { perform(.pin, unpinned) } label: {
                Label(pinTitle(pinning: true, targets: unpinned), systemImage: "pin")
            }
            .disabled(!canMutate || busy)
        }
        if !pinned.isEmpty {
            Button { perform(.unpin, pinned) } label: {
                Label(pinTitle(pinning: false, targets: pinned), systemImage: "pin.slash")
            }
            .disabled(!canMutate || busy)
        }
        Divider()
        let live = targets.filter(\.live)
        if !live.isEmpty {
            Button { perform(.stop, live) } label: {
                Label("mac.sessions.stop \(live.count)", systemImage: "stop.fill")
            }
            .disabled(!canMutate || busy)
        }
        Button(role: .destructive) {
            workspace.requestDelete(targets)
        } label: {
            Label("mac.sessions.delete \(targets.count)", systemImage: "trash")
        }
        .disabled(!canMutate || busy)
    }

    private func batchCorralIDs(from targets: [SessionSummary]) -> [String] {
        var seen: Set<String> = []
        return targets.map(\.resolvedCorralID)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// TUI semantics: a split is one pin unit. A selection made entirely from
    /// one split therefore names the split action.
    private func pinTitle(pinning: Bool, targets: [SessionSummary]) -> LocalizedStringKey {
        let groupIDs = Set(targets.compactMap { workspace.layout.group(containing: $0.key)?.id })
        let hasIndependent = targets.contains { workspace.layout.group(containing: $0.key) == nil }
        if groupIDs.count == 1, !hasIndependent {
            return pinning ? "mac.group.pin" : "mac.group.unpin"
        }
        return pinning
            ? LocalizedStringKey("mac.sessions.pin \(targets.count)")
            : LocalizedStringKey("mac.sessions.unpin \(targets.count)")
    }
}
