import SwiftUI

/// One request to scroll a conversation to a message; the token makes a
/// repeated request for the same message fire again.
struct ChatScrollRequest: Hashable {
    let messageID: String
    let token = UUID()
}

extension EnvironmentValues {
    @Entry var promptJumpAnimated = true
}
