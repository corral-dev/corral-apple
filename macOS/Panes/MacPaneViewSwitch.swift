import AppKit
import SwiftUI

/// The pane's native chat/terminal switch (design: MACOS_CLIENT_DESIGN.md,
/// Pane header composition). The control keeps its native bezel but replaces
/// the accent-tinted selected symbol with a light neutral pill; the two SF
/// Symbols are the only labels, as the pane contract requires.
struct MacPaneViewSwitch: NSViewRepresentable {
    @Environment(\.interfaceScale) private var interfaceScale
    @Binding var mode: MacWorkspace.PaneMode

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.focusRingType = .none
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setImage(NSImage(systemSymbolName: "bubble.left.and.text.bubble.right",
                                 accessibilityDescription: String(localized: "mac.pane.chat")),
                         forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "terminal",
                                 accessibilityDescription: String(localized: "mac.pane.terminal")),
                         forSegment: 1)
        control.setLabel("", forSegment: 0)
        control.setLabel("", forSegment: 1)
        control.selectedSegment = mode == .chat ? 0 : 1
        control.setAccessibilityLabel(String(localized: "mac.pane.view"))
        control.toolTip = String(localized: "mac.pane.view.help")
        configure(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        configure(control)
        let index = mode == .chat ? 0 : 1
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Native controls select a supported size at large interface scales
    /// instead of being stretched geometrically.
    private func configure(_ control: NSSegmentedControl) {
        control.controlSize = interfaceScale >= 1.25 ? .regular : .small
        control.cell?.isBordered = true
        control.focusRingType = .none
        control.selectedSegmentBezelColor = Self.selectedBezel
        let segmentWidth: CGFloat = interfaceScale >= 1.25 ? 34 : 28
        for segment in 0..<control.segmentCount where control.width(forSegment: segment) != segmentWidth {
            control.setWidth(segmentWidth, forSegment: segment)
        }
    }

    /// A borderless control draws its selected symbol in the system accent
    /// colour; a neutral light pill keeps the switch out of the attention
    /// palette and still shows which view is active.
    private static let selectedBezel = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.23, green: 0.23, blue: 0.235, alpha: 1)
            : NSColor(srgbRed: 0.90, green: 0.90, blue: 0.905, alpha: 1)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MacPaneViewSwitch

        init(_ parent: MacPaneViewSwitch) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            parent.mode = sender.selectedSegment == 0 ? .chat : .terminal
        }
    }
}
