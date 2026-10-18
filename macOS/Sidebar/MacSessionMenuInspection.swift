#if DEBUG
import AppKit

/// Observes the production native menu opened by its own target/action.
/// No pointer/key event is posted and no menu action is performed.
@MainActor
final class MacSessionMenuInspection: NSObject {
    private let output: URL
    private let evidence: () -> [String: Any]

    init(output: URL, evidence: @escaping () -> [String: Any]) {
        self.output = output
        self.evidence = evidence
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)),
                                              name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    func stop() { NotificationCenter.default.removeObserver(self) }

    @objc private func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        var snapshot = evidence()
        snapshot["menuItems"] = menu.items.filter { !$0.isSeparatorItem }.map {
            ["title": $0.title, "hasImage": $0.image != nil, "enabled": $0.isEnabled] as [String: Any]
        }
        snapshot["menuFont"] = menu.font.pointSize
        snapshot["separatorCount"] = menu.items.filter(\.isSeparatorItem).count
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
        let selectedCount = snapshot["selectedCount"] as? Int
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            menu.cancelTracking()
            guard ProcessInfo.processInfo.arguments.contains("-CorralInspectBulkDeleteConfirmation"),
                  let count = selectedCount,
                  let index = menu.items.firstIndex(where: {
                      $0.title == String(localized: "mac.sessions.delete \(count)") && $0.isEnabled
                  }) else { return }
            // The production Delete item only presents its native confirmation.
            // Never invoke the destructive confirmation button or mutate history.
            DispatchQueue.main.async {
                menu.performActionForItem(at: index)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    try? Data("confirmation presented".utf8).write(
                        to: self.output.appendingPathExtension("confirmation"), options: .atomic)
                }
            }
        }
    }
}
#endif
