import SwiftUI

/// The session menu, opened from the session's title: a split pane's title
/// button and the window title menu of a lone pane (design: Window top bar).
struct MacSessionMenuItems: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    let session: SessionSummary
    let runtimes: [RuntimeEntry]
    let promptsCount: Int
    @Binding var promptsOpen: Bool
    @Binding var mode: MacWorkspace.PaneMode
    let onClose: () -> Void

    var body: some View {
        items.labelStyle(.titleAndIcon)
    }

    /// A read-only pairing still switches views, reads prompts and copies the
    /// path; session actions are unavailable.
    private var readonly: Bool { SessionActionsMenu.isReadonly(access: appModel.connectedAccess) }

    @ViewBuilder
    private var items: some View {
        Picker(selection: $mode) {
            Label("mac.pane.chat", systemImage: "bubble.left.and.text.bubble.right")
                .tag(MacWorkspace.PaneMode.chat)
            Label("mac.pane.terminal", systemImage: "terminal")
                .tag(MacWorkspace.PaneMode.terminal)
        } label: {
            Text("mac.pane.view")
        }
        .pickerStyle(.inline)
        .labelsHidden()
        if promptsCount > 0 || promptsOpen {
            Toggle(isOn: $promptsOpen) {
                Label("mac.prompts.title \(promptsCount)", systemImage: "list.bullet")
            }
        }
        Divider()
        Button {
            Task { await workspace.togglePin(session.key) }
        } label: {
            Label(workspace.layout.pinnedSessions[session.key] == nil ? "mac.session.pin" : "mac.session.unpin",
                  systemImage: workspace.layout.pinnedSessions[session.key] == nil ? "pin" : "pin.slash")
        }
        .disabled(readonly)
        Button {
            Task { await workspace.fork(session) }
        } label: {
            Label("session.actions.copy", systemImage: "doc.on.doc")
        }
        .disabled(readonly)
        Menu {
            ForEach(SessionActionsMenu.handoffTargets(from: runtimes)) { runtime in
                Button {
                    Task { await workspace.handoff(session, to: runtime.id) }
                } label: {
                    Label {
                        Text(verbatim: runtime.name ?? runtime.id)
                    } icon: {
                        if let logo = Palette.runtimeLogoName(runtime.id) { Image(logo) }
                        else { Image(systemName: Palette.runtimeSymbol(runtime.id)) }
                    }
                }
            }
        } label: {
            Label("mac.session.continue_with", systemImage: "arrow.triangle.branch")
        }
        .disabled(runtimes.isEmpty || readonly)
        Button {
            Task { await workspace.restart(session.key) }
        } label: {
            Label("session.actions.restart", systemImage: "arrow.clockwise")
        }
        .disabled(readonly || appModel.client?.hostCapabilities.sessionRestart != true)
        if session.live {
            Button {
                Task { await workspace.stop(session.key) }
            } label: {
                Label("sessions.action.stop", systemImage: "stop.fill")
            }
            .disabled(readonly)
        }
        Divider()
        Button {
            PlatformPasteboard.copy(SessionPresentation.fullWorkspacePath(from: session))
        } label: {
            Label("session.workspace.copy_path", systemImage: "folder")
        }
        Button(action: onClose) {
            Label("mac.pane.close", systemImage: "xmark")
        }
    }
}
