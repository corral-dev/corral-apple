import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Local pane identity, never a transcript, file path or agent input.
nonisolated struct MacPaneDrag: Codable, Transferable, Identifiable {
    let workspaceID: UUID
    let hostID: String?
    let key: String
    let paneKeys: [String]
    var id: String { key }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.x0c.corral.pane-position"))
            .visibility(.ownProcess)
    }

    /// The target's final slot, not a swap or an insertion offset before removal.
    func reorderedKeys(workspaceID: UUID, hostID: String?, current: [String], target: String) -> [String]? {
        guard self.workspaceID == workspaceID, self.hostID == hostID,
              paneKeys == current, current.count > 1, key != target,
              let sourceIndex = current.firstIndex(of: key),
              let targetIndex = current.firstIndex(of: target) else { return nil }
        var result = current
        result.remove(at: sourceIndex)
        result.insert(key, at: targetIndex)
        return result
    }
}

/// Native dragging is limited to identity/title/blank space, not trailing actions.
struct MacPaneDragSource: ViewModifier {
    @Environment(MacWorkspace.self) private var workspace
    let key: String

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .draggable(MacPaneDrag.self, item: workspace.paneDrag(for: key))
            .dragConfiguration(DragConfiguration(
                operationsWithinApp: .init(allowCopy: false, allowMove: true),
                operationsOutsideApp: .init(allowCopy: false)))
    }
}

struct MacPaneDragGrip: View {
    @Environment(MacWorkspace.self) private var workspace

    var body: some View {
        if workspace.paneKeys.count > 1 {
            Image(systemName: "line.3.horizontal")
                .interfaceFont(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .interfacePadding(.horizontal, 6)
                .help(Text("mac.pane.reorder"))
                .accessibilityHidden(true)
        }
    }
}

/// Only the header accepts pane drops; text/file drops in content keep their meaning.
struct MacPaneDropTarget: ViewModifier {
    @Environment(MacWorkspace.self) private var workspace
    let key: String
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(targeted ? Palette.accent.opacity(0.15) : Color.clear)
            .dropDestination(for: MacPaneDrag.self) { items, _ in
                guard items.count == 1, let item = items.first else { return false }
                return workspace.reorderPane(item, to: key)
            } isTargeted: { targeted = $0 }
            .accessibilityAction(named: Text("mac.pane.move_left")) { move(by: -1) }
            .accessibilityAction(named: Text("mac.pane.move_right")) { move(by: 1) }
    }

    private func move(by offset: Int) {
        guard let index = workspace.paneKeys.firstIndex(of: key),
              workspace.paneKeys.indices.contains(index + offset),
              let drag = workspace.paneDrag(for: key) else { return }
        workspace.reorderPane(drag, to: workspace.paneKeys[index + offset])
    }
}
