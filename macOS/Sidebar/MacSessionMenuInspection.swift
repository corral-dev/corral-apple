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
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { menu.cancelTracking() }
    }
}
#endif
