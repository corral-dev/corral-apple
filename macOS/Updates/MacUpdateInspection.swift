#if DEBUG && CORRAL_DIRECT_DOWNLOAD
import AppKit
import SwiftUI

/// Debug-only acceptance through the public native menu and Settings action.
struct MacUpdateInspection: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            let arguments = CommandLine.arguments
            if arguments.contains("-CorralInspectUpdateSettings") {
                openSettings()
            }
            if arguments.contains("-CorralInspectUpdateCheck") {
                try? await Task.sleep(for: .seconds(1))
                invokeUpdateCommand(in: NSApp.mainMenu)
            }
        }
    }

    private func invokeUpdateCommand(in menu: NSMenu?) {
        guard let menu else { return }
        let title = String(localized: "mac.updates.check")
        for (index, item) in menu.items.enumerated() {
            if item.title == title {
                menu.performActionForItem(at: index)
                return
            }
            invokeUpdateCommand(in: item.submenu)
        }
    }
}
#endif
