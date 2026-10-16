import SwiftUI

/// The persistent row owns its native confirmation and the selected session.
/// Refreshes of sibling rows do not change this presentation binding.
struct SessionDeletionRow<Content: View>: View {
    let session: SessionSummary
    let onDelete: (SessionSummary) -> Void
    @ViewBuilder let content: (Binding<Bool>) -> Content
    @State private var isPresented = false

    var body: some View {
        content($isPresented)
            .confirmationDialog(
                "sessions.delete_confirm.title",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button("sessions.action.delete", role: .destructive) { onDelete(session) }
                Button("action.cancel", role: .cancel) {}
            }
    }
}
