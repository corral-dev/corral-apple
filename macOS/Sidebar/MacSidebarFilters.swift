import AppKit
import SwiftUI

/// Native controls over the unfiltered host window; selections only narrow presentation.
struct MacSidebarFilters: View {
    let sessions: [SessionSummary]
    @Binding var quickFilter: SessionQuickFilter
    @Binding var runtimes: Set<SessionRuntimeFilter>
    @Binding var projects: Set<SessionProjectFilter>
    var hostRuntimes: [RuntimeEntry] = []
    @State private var showProjects = false
    @State private var choices: [SessionProjectOption] = []
    @State private var extraChoices: [SessionProjectOption] = []
    #if DEBUG
    @State private var didInspectQuickFilter = false
    #endif

    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let activeRuntimes = SessionListFiltering.visibleRuntimes(
            hostRuntimes: hostRuntimes,
            sessions: sessions,
            selected: runtimes
        )
        VStack(alignment: .leading, spacing: 6 * interfaceScale) {
            MacFilterScrollView { viewportWidth in
                AdaptiveFilterRowLayout(
                    viewportWidth: viewportWidth,
                    dividerIndex: 1,
                    dividerGap: 2.5 * interfaceScale,
                    itemGap: 2.5 * interfaceScale,
                    minItemWidth: 23 * interfaceScale,
                    maxItemWidth: 42 * interfaceScale
                ) {
                    MacQuickFilterButton(selected: quickFilter != .all, sidebar: true) {
                        Text(LocalizedStringKey(quickFilter.titleKey))
                        Text(verbatim: quickFilter.count(sessions: sessions).formatted()).monospacedDigit().opacity(0.75)
                    } action: { advanceQuickFilter() }
                    .fixedSize()
                    .accessibilityLabel(Text(LocalizedStringKey(quickFilter.titleKey)))
                    .accessibilityValue(Text(verbatim: quickFilter.count(sessions: sessions).formatted()))
                    .accessibilityIdentifier("corral.filter.attention")
                    if !activeRuntimes.isEmpty {
                        // HStack gives SwiftUI Divider its vertical-hairline orientation inside a custom Layout.
                        HStack(spacing: 0) { Divider() }.interfaceFrame(width: 1, height: 16)
                    }
                    ForEach(activeRuntimes, id: \.self) { runtime in
                        MacQuickFilterButton(selected: runtimes.contains(runtime), sidebar: true, flexibleWidth: true, labelWidth: 18) {
                            if let logo = Palette.runtimeLogoName(runtime.rawValue) {
                                Image(logo)
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .interfaceFrame(width: 17, height: 17)
                                    // All assistant logos ship as monochrome light/dark
                                    // pairs; the flipped scheme picks the contrasting
                                    // variant on the accent fill. No per-assistant cases.
                                    .environment(\.colorScheme, logoScheme(selected: runtimes.contains(runtime)))
                            }
                        } action: {
                            SessionListFiltering.toggle(runtime, all: .all, in: &runtimes)
                        }
                        .accessibilityLabel(Text(verbatim: Palette.runtimeDisplayName(runtime.rawValue)))
                        .help(Text(verbatim: Palette.runtimeDisplayName(runtime.rawValue)))
                        .accessibilityIdentifier("corral.filter.runtime." + runtime.rawValue)
                    }
                }
            }
            .accessibilityLabel(Text("sessions.filter.runtime"))

            HStack(spacing: Space.xs * interfaceScale) {
                MacFilterChoices(spacing: Space.xs * interfaceScale) {
                    ForEach(projectRowOptions, id: \.path) { option in projectButton(option) }
                }
                MacQuickFilterButton(selected: !projects.isEmpty, sidebar: true) {
                    summaryLabel
                } action: {
                    showProjects = true
                }
                .layoutPriority(1)
                .accessibilityLabel(Text("sessions.filter.project"))
                .accessibilityValue(summaryLabel.title)
                .help(summaryLabel.title)
                .popover(isPresented: $showProjects) {
                    MacProjectFilterPopover(
                        options: SessionListFiltering.allOptions(sessions: sessions),
                        hasNoProject: SessionListFiltering.hasNoProject(sessions: sessions),
                        selected: $projects
                    )
                }
            }
            .accessibilityLabel(Text("sessions.filter.project"))
        }
        .onChange(of: sessions, initial: true) { _, next in
            choices = SessionListFiltering.reconcileChoices(current: choices, sessions: next)
        }
        .onChange(of: projects, initial: true) { _, _ in rememberSelectedProjects() }
        .focusEffectDisabled()
        #if DEBUG
        .task(id: choices) {
            guard !choices.isEmpty else { return }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-CorralInspectSelectedFilters") {
                quickFilter = .attention
                runtimes = [.codex]
                projects = [.project(path: choices[0].path)]
            } else if arguments.contains("-CorralInspectMultiFilters") {
                runtimes = [.claude, .codex]
                projects = Set(choices.prefix(2).map { .project(path: $0.path) })
            }
            if arguments.contains("-CorralInspectLastProjectFilter"), let last = choices.last {
                projects = [.project(path: last.path)]
            }
            if arguments.contains("-CorralInspectAllFilters") {
                quickFilter = .attention
                runtimes = Set(SessionRuntimeFilter.ordered.filter { $0 != .all })
                projects = Set(choices.prefix(2).map { .project(path: $0.path) })
            }
            if arguments.contains("-CorralInspectDarkFilters") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if arguments.contains("-CorralInspectProjectPicker") { showProjects = true }
        }
        .task(id: sessions.isEmpty) {
            guard !sessions.isEmpty else { return }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-CorralInspectQuickFilterCycle"), !didInspectQuickFilter {
                didInspectQuickFilter = true
                for step in 0...3 {
                    if step > 0 { advanceQuickFilter() }
                    let evidence: [String: Any] = [
                        "step": step, "mode": quickFilter.rawValue,
                        "titleKey": quickFilter.titleKey,
                        "selected": quickFilter != .all,
                        "count": quickFilter.count(sessions: sessions),
                        "visibleKeys": quickFilter.apply(sessions: sessions, runtimes: runtimes, projects: projects).map(\.key),
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/corral-quick-filter-\(step).json"), options: .atomic)
                    }
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                }
            }
        }
        #endif
    }

    private func advanceQuickFilter() {
        quickFilter.advance()
    }

    private func logoScheme(selected: Bool) -> ColorScheme {
        guard selected else { return colorScheme }
        #if DEBUG
        if InspectionLaunchOptions.forcesKeyWindowControls { return colorScheme == .dark ? .light : .dark }
        #endif
        return activeState == .inactive ? colorScheme : (colorScheme == .dark ? .light : .dark)
    }

    private func projectButton(_ option: SessionProjectOption) -> some View {
        let selected = option.path.isEmpty ? projects.contains(.noProject) : projects.contains(.project(path: option.path))
        return MacQuickFilterButton(selected: selected, sidebar: true) {
            Group {
                if option.path.isEmpty { Text("sessions.filter.project.none") }
                else if option.label == "~" { Text("sessions.project.home") }
                else { Text(verbatim: option.label) }
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: 120 * interfaceScale)
        } action: {
            let choice: SessionProjectFilter = option.path.isEmpty ? .noProject : .project(path: option.path)
            SessionListFiltering.toggle(choice, all: .all, in: &projects)
        }
        .help(Text(verbatim: option.path))
        .accessibilityLabel(option.path.isEmpty ? Text("sessions.filter.project.none") : Text(verbatim: option.label))
    }

    /// Selection changes colors only; new More choices append and stay after deselection.
    private var projectRowOptions: [SessionProjectOption] {
        let visible = Set(choices.map(\.path))
        return choices + extraChoices.filter { !visible.contains($0.path) }
    }

    private var summaryLabel: ProjectFilterSummaryLabel {
        ProjectFilterSummaryLabel(selected: projects, options: projectRowOptions, maximumNameWidth: 108 * interfaceScale)
    }

    private func rememberSelectedProjects() {
        let visible = Set(choices.map(\.path))
        let candidates = projects.compactMap { project -> SessionProjectOption? in
            switch project {
            case .project(let path):
                guard !visible.contains(path) else { return nil }
                return SessionListFiltering.option(for: path, sessions: sessions)
            case .noProject: return SessionProjectOption(path: "", label: "")
            case .all: return nil
            }
        }.sorted { $0.path < $1.path }
        extraChoices = SessionListFiltering.appendingChoices(current: extraChoices, candidates: candidates)
    }

}

/// Native buttons; macOS `.bordered` ignores tint, so a selected choice is
/// the accent-filled `.borderedProminent` capsule. When macOS mutes an
/// inactive window's fill, the label contrast keeps the selection readable.
/// Shared with the New Session dialog.
struct MacQuickFilterButton<Content: View>: View {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var labelContentWidth: CGFloat = 0
    @State private var usesCapsuleShape = false
    let selected: Bool
    var sidebar = false
    var flexibleWidth = false
    var labelWidth: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        Group {
            if selected {
                button.buttonStyle(.borderedProminent)
            } else if sidebar {
                button.buttonStyle(.borderless)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        // Native AppKit `.borderedProminent .capsule` enforces a 27-pt floor; switch
        // smoothly to `.circle` below 27 pt so narrow sidebars stay unclipped.
        .buttonBorderShape(flexibleWidth && !usesCapsuleShape ? .circle : .capsule)
        .controlSize(.small)
        .tint(Palette.accent)
        // A borderless native button has less intrinsic padding. Reserve the
        // bordered button's footprint so a selection never shifts its peers.
        .frame(width: flexibleWidth ? nil : reservedSidebarWidth)
        .frame(maxWidth: flexibleWidth ? .infinity : nil)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if flexibleWidth { usesCapsuleShape = width >= 26.8 * interfaceScale }
        }
        .frame(minHeight: (sidebar ? MacSidebarMetrics.sidebarFilterHeight : MacSidebarMetrics.filterHeight) * interfaceScale)
        .accessibilityAddTraits(selected ? .isSelected : [])
        #if DEBUG
        .environment(\.controlActiveState, InspectionLaunchOptions.forcesKeyWindowControls ? .key : activeState)
        #endif
    }

    private var reservedSidebarWidth: CGFloat? {
        guard sidebar else { return nil }
        let contentWidth = labelWidth.map { $0 * interfaceScale } ?? labelContentWidth
        guard contentWidth > 0 else { return nil }
        // `.controlSize(.small)` capsule bezel adds ~20 pt independent of interfaceScale.
        return contentWidth + 20
    }

    /// On the accent fill the on-accent colour; on the muted inactive fill primary.
    private var labelColor: Color {
        guard selected else { return .secondary }
        #if DEBUG
        if InspectionLaunchOptions.forcesKeyWindowControls { return Palette.onAccent }
        #endif
        return activeState == .inactive ? .primary : Palette.onAccent
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: flexibleWidth ? 0 : (sidebar ? 3 : Space.xs)) { content() }
                .frame(
                    minWidth: flexibleWidth ? nil : labelWidth.map { $0 * interfaceScale },
                    maxWidth: flexibleWidth ? .infinity : nil
                )
                .interfaceFont(sidebar
                    ? .system(size: 13, weight: selected ? .semibold : .medium)
                    : .callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .fixedSize(horizontal: !flexibleWidth, vertical: false)
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if sidebar && labelWidth == nil && !flexibleWidth { labelContentWidth = width }
                }
        }
    }
}

/// Edge-faded horizontal scroller exposing the live viewport width so adaptive
/// rows can distribute extra space rather than stranding trailing margin.
private struct MacFilterScrollView<Content: View>: View {
    @Namespace private var coordinateSpace
    @State private var contentFrame: CGRect = .zero
    @State private var viewportWidth: CGFloat = 0
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        let space = coordinateSpace
        return ScrollView(.horizontal, showsIndicators: false) {
            content(viewportWidth)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: {
                    contentFrame = $0
                }
        }
        .coordinateSpace(name: space)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [contentFrame.minX < -0.5 ? .clear : .white, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 16)
                Rectangle().fill(.white)
                LinearGradient(colors: [.white, contentFrame.maxX > viewportWidth + 0.5 ? .clear : .white], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 16)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keep choices on one line and reveal overflow without a second picker step.
struct MacFilterChoices<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        MacFilterScrollView { _ in
            HStack(spacing: spacing) { content() }
        }
    }
}

/// Adapted from the iPhone's searchable project picker with Mac controls. It
/// stays open for repeated toggles and closes on a click outside or Esc.
struct MacProjectFilterPopover: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let options: [SessionProjectOption]
    let hasNoProject: Bool
    @Binding var selected: Set<SessionProjectFilter>
    @State private var query = ""

    private var visibleOptions: [SessionProjectOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.label.localizedCaseInsensitiveContains(needle) || $0.path.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPopoverSearchField(text: $query, prompt: String(localized: "sessions.filter.project.search"))
                .padding(Space.md)
            Divider()
            List {
                pickerRow(title: Text("sessions.filter.all"), selected: selected.isEmpty) {
                    selected.removeAll()
                }
                ForEach(visibleOptions, id: \.path) { option in
                    pickerRow(
                        title: option.label == "~" ? Text("sessions.project.home") : Text(verbatim: option.label),
                        path: option.path,
                        selected: selected.contains(.project(path: option.path))
                    ) {
                        toggle(.project(path: option.path))
                    }
                }
                if hasNoProject {
                    pickerRow(
                        title: Text("sessions.filter.project.none"),
                        selected: selected.contains(.noProject)
                    ) {
                        toggle(.noProject)
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 360, height: 420)
        .tint(.primary)
        .focusEffectDisabled()
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: 1,
            leading: Space.md * interfaceScale,
            bottom: 1,
            trailing: Space.md * interfaceScale
        )
    }

    private func pickerRow(
        title: Text,
        path: String = "",
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            MacProjectPickerRow(title: title, path: path, selected: selected)
                .interfacePadding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ project: SessionProjectFilter) {
        if selected.contains(project) { selected.remove(project) } else { selected.insert(project) }
    }
}
