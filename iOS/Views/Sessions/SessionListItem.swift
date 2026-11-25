#if os(iOS)
import SwiftUI

struct SessionListContextActions {
    var runtimes: [RuntimeEntry] = []
    var runtimesLoaded = false
    var runtimesLoading = false
    var runtimesError: String? = nil
    var onRetryRuntimes: () -> Void = {}
    var access: String? = nil
    var clientReady = false
    var isBusy = false
    var supportsTerminal = false
    var supportsExport = false
    var supportsRestart = false
    var rememberedMode: SessionDetailMode = .chat
    var onSelectMode: ((SessionDetailMode) -> Void)? = nil
    var onFork: (() -> Void)? = nil
    var onHandoff: ((RuntimeEntry) -> Void)? = nil
    var onExport: (() -> Void)? = nil
    var onRestart: (() -> Void)? = nil
    var onCopyCorralID: (() -> Void)? = nil
    var onCopyPath: (() -> Void)? = nil
}

/// The native row and swipe controls used by the host list, its search
/// results and its isolated UI fixture. `row` defaults to the list row.
struct SessionListItem<Row: View>: View {
    let session: SessionSummary
    let onPin: () -> Void
    let onStop: () -> Void
    let onDelete: (SessionSummary) -> Void
    var contextActions: SessionListContextActions? = nil
    @ViewBuilder let row: () -> Row

    @State private var pendingHandoff: RuntimeEntry?

    var body: some View {
        SessionDeletionRow(session: session, onDelete: onDelete) { confirmation in
            NavigationLink(value: SessionRoute(key: session.key)) {
                row()
            }
            .listRowSeparator(.visible, edges: .bottom)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + SessionListLayout.separatorLeading
            }
            .listRowInsets(SessionListLayout.rowInsets)
            .swipeActions(edge: .leading) {
                pinButton
                    .tint(Palette.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // This action asks; only the dialog's destructive action deletes.
                Button { confirmation.wrappedValue = true } label: {
                    Label("sessions.action.delete", systemImage: "trash")
                }
                .tint(.red)
                if session.live {
                    Button(action: onStop) {
                        Label("sessions.action.stop", systemImage: "stop.fill")
                    }
                    .tint(.gray)
                }
            }
            // Secondary click on iPad (and long press on iPhone): matches the
            // session More menu actions (owner request 2026-11-19).
            .contextMenu {
                if let contextActions {
                    SessionMenuItems(
                        session: session,
                        runtimes: contextActions.runtimes,
                        runtimesLoaded: contextActions.runtimesLoaded,
                        runtimesLoading: contextActions.runtimesLoading,
                        runtimesError: contextActions.runtimesError,
                        onRetryRuntimes: contextActions.onRetryRuntimes,
                        access: contextActions.access,
                        clientReady: contextActions.clientReady,
                        isBusy: contextActions.isBusy,
                        supportsExport: contextActions.supportsExport,
                        supportsRestart: contextActions.supportsRestart,
                        onPin: onPin,
                        onCopy: contextActions.onFork,
                        onHandoff: contextActions.onHandoff,
                        onPendingHandoff: { pendingHandoff = $0 },
                        onExport: contextActions.onExport,
                        onRestart: contextActions.onRestart,
                        onStop: onStop,
                        onCopyCorralID: contextActions.onCopyCorralID,
                        onCopyPath: contextActions.onCopyPath,
                        onRequestDelete: { confirmation.wrappedValue = true },
                        displayMode: contextActions.supportsTerminal && contextActions.onSelectMode != nil ? Binding(
                            get: { contextActions.rememberedMode },
                            set: { contextActions.onSelectMode?($0) }
                        ) : nil
                    )
                } else {
                    pinButton
                    if session.live {
                        Button(action: onStop) {
                            Label("sessions.action.stop", systemImage: "stop.fill")
                        }
                    }
                    Divider()
                    Button(role: .destructive) { confirmation.wrappedValue = true } label: {
                        Label("sessions.action.delete", systemImage: "trash")
                    }
                }
            }
            .confirmationDialog(
                "session.actions.handoff.confirm_title",
                isPresented: Binding(
                    get: { pendingHandoff != nil },
                    set: { if !$0 { pendingHandoff = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("session.actions.handoff.confirm") {
                    if let target = pendingHandoff {
                        pendingHandoff = nil
                        contextActions?.onHandoff?(target)
                    }
                }
                Button("action.cancel", role: .cancel) { pendingHandoff = nil }
            } message: {
                if let target = pendingHandoff {
                    let name = target.name?.isEmpty == false ? target.name! : Palette.runtimeDisplayName(target.id)
                    if SessionActionsMenu.needsKimiNotice(runtimeID: target.id) {
                        Text("session.actions.handoff.kimi_notice")
                    } else {
                        Text(String(
                            localized: "session.actions.handoff.confirm_message",
                            defaultValue: "Start a new \(name) session from this conversation?"
                        ))
                    }
                }
            }
        }
    }

    private var pinButton: some View {
        let isPinned = session.pinned == true || session.group?.pinned == true
        return Button(action: onPin) {
            Label(isPinned ? "sessions.action.unpin" : "sessions.action.pin",
                  systemImage: isPinned ? "pin.slash" : "pin")
        }
    }
}

extension SessionListItem where Row == SessionRowView {
    init(
        session: SessionSummary,
        onPin: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onDelete: @escaping (SessionSummary) -> Void,
        contextActions: SessionListContextActions? = nil
    ) {
        self.init(
            session: session,
            onPin: onPin,
            onStop: onStop,
            onDelete: onDelete,
            contextActions: contextActions
        ) {
            SessionRowView(session: session)
        }
    }
}
#endif
