#if os(iOS)
import SwiftUI

/// The native row and swipe controls used by the host list and its isolated UI fixture.
struct SessionListItem: View {
    let session: SessionSummary
    let onPin: () -> Void
    let onStop: () -> Void
    let onDelete: (SessionSummary) -> Void

    var body: some View {
        SessionDeletionRow(session: session, onDelete: onDelete) { confirmation in
            NavigationLink(value: SessionRoute(key: session.key)) {
                SessionRowView(session: session)
            }
            .listRowSeparator(.visible, edges: .bottom)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + SessionListLayout.separatorLeading
            }
            .listRowInsets(SessionListLayout.rowInsets)
            .swipeActions(edge: .leading) {
                let isPinned = session.pinned == true || session.group?.pinned == true
                Button(action: onPin) {
                    Label(isPinned ? "sessions.action.unpin" : "sessions.action.pin",
                          systemImage: isPinned ? "pin.slash" : "pin")
                }
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
        }
    }
}
#endif
