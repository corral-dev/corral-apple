import SwiftUI

/// A single safe-area owner keeps the composer above the keyboard and reserves
/// its full height for the conversation, including attachments and error banners.
struct ChatScreen<Content: View, Composer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var composer: Composer

    var body: some View {
        content
            .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
    }
}
