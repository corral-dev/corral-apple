#if os(iOS)
import SwiftUI

/// Bottom search is always the system's minimized search icon; tapping expands it.
/// The system owns rendering, expansion, editing and keyboard placement.
/// Switching this behavior on scroll is not animated by the system, so it stays constant.
struct SessionListSystemSearchPlacement: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.searchToolbarBehavior(.minimize)
        } else {
            content
        }
    }
}
#endif
