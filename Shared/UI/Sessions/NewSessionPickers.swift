import SwiftUI
#if os(macOS)
import AppKit
#endif

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
/// Assistant choice with each official logo beside its name. SwiftUI's
/// segmented picker shows text or image, never both (Apple DTS), so this is
/// the AppKit segmented control itself.
struct RuntimeSegmentedControl: NSViewRepresentable {
    let runtimes: [RuntimeEntry]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    /// Fills the row's width, never wider, so the form keeps its margins;
    /// height stays native.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? natural.width, height: natural.height)
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        let ids = runtimes.map(\.id)
        if coordinator.ids != ids {
            coordinator.ids = ids
            control.segmentCount = runtimes.count
            for (index, runtime) in runtimes.enumerated() {
                let name = runtime.name ?? runtime.id
                control.setLabel(name, forSegment: index)
                control.setImage(Self.logo(runtime.id), forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
        }
        control.selectedSegment = ids.firstIndex(of: selection) ?? -1
        control.isEnabled = context.environment.isEnabled
    }

    private static func logo(_ runtimeID: String) -> NSImage? {
        let source = Palette.runtimeLogoName(runtimeID).flatMap { NSImage(named: $0) }
            ?? NSImage(systemSymbolName: Palette.runtimeSymbol(runtimeID), accessibilityDescription: nil)
        // A copy, so resizing never touches the catalog's shared image.
        guard let image = source?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var ids: [String] = []

        init(selection: Binding<String>) { self.selection = selection }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard ids.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = ids[sender.selectedSegment]
        }
    }
}

/// The system search field above the project list. It takes focus when the
/// sheet opens so typing filters at once; ↑/↓ move the list selection while
/// the caret stays here, and Return starts the session.
struct ProjectSearchField: NSViewRepresentable {
    @Binding var text: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusingSearchField()
        field.placeholderString = String(localized: "session.new.project.search")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ProjectSearchField

        init(parent: ProjectSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            default: return false
            }
            return true
        }
    }

    private final class FocusingSearchField: NSSearchField {
        private var focusedOnce = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !focusedOnce, window != nil else { return }
            focusedOnce = true
            // After the sheet picks its own first responder.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }
}
#endif
