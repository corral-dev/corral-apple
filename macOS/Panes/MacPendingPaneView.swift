import SwiftUI

/// A reserved split pane while the host session is still being created
/// (owner request 2026-11-07: the split appears immediately; hosting, the
/// control channel and the first frame follow asynchronously).
///
/// Presentation only: no conversation store, no composer, no terminal surface
/// and no close affordance yet — there is no session to close until creation
/// completes and the pane is promoted in place.
struct MacPendingPaneView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(MacWorkspace.self) private var workspace
    let pending: MacWorkspace.PendingPane

    private var isFocused: Bool { workspace.showsFocus(pending.key) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // The body is an empty terminal canvas; the phase lives in the
            // bottom title strip only, matching the TUI's pending pane.
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Text(verbatim: pending.title)
                    .interfaceFont(.system(size: 15, weight: isFocused ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                Spacer(minLength: Space.sm)
            }
            .chatReadableColumn()
            .interfacePadding(.horizontal, Space.md)
            .interfaceFrame(height: 40)
            .modifier(MacPaneReorderHandle(key: pending.key))
            .background(headerSurface)
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.focus(pending.key) }
        .modifier(MacPaneMoveActions(key: pending.key))
        .accessibilityLabel(Text(verbatim: pending.title))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var headerSurface: some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(Color.primary.opacity(isFocused ? 0.06 : 0.03))
    }
}
