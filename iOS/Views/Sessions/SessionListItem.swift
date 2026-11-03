#if os(iOS)
import SwiftUI

/// The native row and swipe controls used by the host list, its search
/// results and its isolated UI fixture. `row` defaults to the list row.
struct SessionListItem<Row: View>: View {
    let session: SessionSummary
    let onPin: () -> Void
    let onStop: () -> Void
    let onDelete: (SessionSummary) -> Void
    @ViewBuilder let row: () -> Row

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
                Button(action: onStop) {
                    Label("sessions.action.stop", systemImage: "stop.fill")
                }
                .tint(.gray)
            }
            // Secondary click on iPad (and long press on iPhone): the swipe
            // actions as a menu, as in the Mac session menu (owner request 2026-11-01).
            .contextMenu {
                pinButton
                Button(action: onStop) {
                    Label("sessions.action.stop", systemImage: "stop.fill")
                }
                Divider()
                Button(role: .destructive) { confirmation.wrappedValue = true } label: {
                    Label("sessions.action.delete", systemImage: "trash")
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
        onDelete: @escaping (SessionSummary) -> Void
    ) {
        self.init(session: session, onPin: onPin, onStop: onStop, onDelete: onDelete) {
            SessionRowView(session: session)
        }
    }
}
#endif
