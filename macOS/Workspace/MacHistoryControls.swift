import SwiftUI

/// Native toolbar navigation; the context menus expose longer visit histories.
struct MacHistoryControls: View {
    @Environment(MacWorkspace.self) private var workspace

    var body: some View {
        let history = workspace.navigation.host.history
        ControlGroup {
            Button {
                Task { await workspace.navigateHistory(by: -1) }
            } label: { Label("mac.navigation.back", systemImage: "chevron.backward") }
                .disabled(!history.canGoBack || workspace.navigation.isNavigating)
                .help(Text("mac.navigation.back"))
                .contextMenu { visits(Array(history.keys.indices.filter { $0 < history.index }.reversed())) }
                .accessibilityIdentifier("corral.navigation.back")
            Button {
                Task { await workspace.navigateHistory(by: 1) }
            } label: { Label("mac.navigation.forward", systemImage: "chevron.forward") }
                .disabled(!history.canGoForward || workspace.navigation.isNavigating)
                .help(Text("mac.navigation.forward"))
                .contextMenu { visits(history.keys.indices.filter { $0 > history.index }) }
                .accessibilityIdentifier("corral.navigation.forward")
        }
        .controlGroupStyle(.navigation)
    }

    @ViewBuilder private func visits(_ indexes: [Int]) -> some View {
        ForEach(indexes, id: \.self) { index in
            let key = workspace.navigation.host.history.keys[index]
            if let session = workspace.feed?.listStore.session(for: key) {
                Button(SessionPresentation.displayTitle(for: session)) {
                    Task { await workspace.navigateHistory(to: index) }
                }
            }
        }
    }
}
