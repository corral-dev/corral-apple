import SwiftUI

/// One project in the New Session pickers: the name, then the muted path that
/// tells apart projects with similar names.
struct NewSessionProjectRow: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let project: ProjectEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * interfaceScale) {
            Text(verbatim: project.displayName)
                .lineLimit(1)
            if !project.path.isEmpty {
                #if os(macOS)
                Text(verbatim: (project.path as NSString).abbreviatingWithTildeInPath)
                    .interfaceFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                #else
                Text(verbatim: project.path)
                    .interfaceFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                #endif
            }
        }
    }
}

#if os(iOS)
/// An assistant's official logo sized for a system menu item. Menus take a
/// plain image, so the light or dark variant is resolved here and drawn at
/// menu size in its own colors.
struct RuntimeMenuIcon: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    let runtimeID: String

    var body: some View {
        if let image = Self.image(runtimeID, dark: colorScheme == .dark) {
            Image(uiImage: image)
        } else {
            Image(systemName: Palette.runtimeSymbol(runtimeID))
        }
    }

    private static func image(_ runtimeID: String, dark: Bool) -> UIImage? {
        guard let name = Palette.runtimeLogoName(runtimeID),
              let source = UIImage(
                named: name,
                in: nil,
                compatibleWith: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
              ) else { return nil }
        let side: CGFloat = 22
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        .withRenderingMode(.alwaysOriginal)
    }
}

/// Searchable complete project list pushed from the New Session sheet; a tap
/// chooses the project and returns to the sheet.
struct NewSessionProjectList: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.dismiss) private var dismiss
    let projects: [ProjectEntry]
    @Binding var selection: String
    @State private var query = ""

    var body: some View {
        let visible = ProjectEntry.matching(projects, query: query)
        content(visible)
            #if DEBUG
            .onAppear {
                if let preset = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PROJECT_QUERY"] {
                    query = preset
                }
            }
            #endif
    }

    private func content(_ visible: [ProjectEntry]) -> some View {
        List(visible) { project in
            Button {
                selection = project.path
                HapticFeedback.shared.emit(.selection)
                dismiss()
            } label: {
                HStack(spacing: Space.sm * interfaceScale) {
                    NewSessionProjectRow(project: project)
                        .foregroundStyle(.primary)
                    Spacer(minLength: Space.sm * interfaceScale)
                    if project.path == selection {
                        Image(systemName: "checkmark")
                            .interfaceFont(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                    }
                }
                .interfaceFrame(minHeight: TouchTarget.minimum)
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(project.path == selection ? .isSelected : [])
        }
        .overlay {
            if visible.isEmpty { ContentUnavailableView.search(text: query) }
        }
        // Rows read as content, not as accent-colored buttons.
        .tint(.primary)
        .searchable(text: $query, prompt: Text("session.new.project.search"))
        .navigationTitle("session.new.project")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

#if os(macOS)
import AppKit

/// One row of a Mac project picker popover. It has no leading control and no
/// separator: the name sits over its muted path, and a trailing checkmark
/// marks the choice without shifting the labels when it is empty.
struct MacProjectPickerRow: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let title: Text
    var path = ""
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm * interfaceScale) {
            VStack(alignment: .leading, spacing: 2 * interfaceScale) {
                title
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !path.isEmpty {
                    Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                        .interfaceFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.sm * interfaceScale)
            Image(systemName: "checkmark")
                .interfaceFont(.caption.weight(.semibold))
                .opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .interfaceFrame(minHeight: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The whole project catalog behind the New Session dialog's More button:
/// searchable, and one click (or Return on the first match) chooses and closes.
struct MacNewSessionProjectPopover: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceScale) private var interfaceScale
    let projects: [ProjectEntry]
    @Binding var selection: String
    @State private var query = ""

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: 1,
            leading: Space.md * interfaceScale,
            bottom: 1,
            trailing: Space.md * interfaceScale
        )
    }

    var body: some View {
        let visible = ProjectEntry.matching(projects, query: query)
        VStack(spacing: 0) {
            MacPopoverSearchField(text: $query, prompt: String(localized: "session.new.project.search")) {
                if let first = visible.first { choose(first) }
            }
            .padding(Space.md)
            Divider()
            List(visible) { project in
                Button {
                    choose(project)
                } label: {
                    MacProjectPickerRow(
                        title: Text(verbatim: project.displayName),
                        path: project.path,
                        selected: project.path == selection
                    )
                    .interfacePadding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(project.path == selection ? .isSelected : [])
            }
            .listStyle(.plain)
            .overlay {
                if visible.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .frame(width: 360, height: 420)
        .tint(.primary)
        .focusEffectDisabled()
        #if DEBUG
        .onAppear {
            if let preset = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PROJECT_QUERY"] {
                query = preset
            }
        }
        #endif
    }

    private func choose(_ project: ProjectEntry) {
        selection = project.path
        dismiss()
    }
}

/// The system search field heading a popover list. A popover has no window
/// toolbar, so `.searchable` (and a navigation title) would surface in the
/// main window's toolbar instead. It takes focus when the popover opens.
struct MacPopoverSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusingSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacPopoverSearchField

        init(parent: MacPopoverSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }

    private final class FocusingSearchField: NSSearchField {
        private var focusedOnce = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !focusedOnce, window != nil else { return }
            focusedOnce = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }
}
#endif
