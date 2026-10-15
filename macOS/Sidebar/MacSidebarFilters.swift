import AppKit
import SwiftUI

/// Native controls over the unfiltered host window; selections only narrow presentation.
struct MacSidebarFilters: View {
    let sessions: [SessionSummary]
    /// Sessions with waiting, working or recent activity; unread alone is excluded.
    let activeCount: Int
    @Binding var activeOnly: Bool
    @Binding var runtimes: Set<SessionRuntimeFilter>
    @Binding var projects: Set<SessionProjectFilter>
    @State private var showProjects = false
    @State private var choices: [SessionProjectOption] = []
    @State private var extraChoices: [SessionProjectOption] = []

    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * interfaceScale) {
            HStack(spacing: 4 * interfaceScale) {
                MacQuickFilterButton(selected: activeOnly, sidebar: true) {
                    Text("sessions.filter.active")
                    Text(verbatim: activeCount.formatted()).monospacedDigit().opacity(0.75)
                } action: { activeOnly.toggle() }
                .fixedSize()
                .accessibilityLabel(Text("sessions.filter.active"))
                .accessibilityValue(Text(verbatim: activeCount.formatted()))
                .accessibilityIdentifier("corral.filter.active")
                Divider().interfaceFrame(width: 1, height: 16)
                HStack(spacing: 4 * interfaceScale) {
                    ForEach(SessionRuntimeFilter.ordered.filter { $0 != .all }, id: \.self) { runtime in
                        MacQuickFilterButton(selected: runtimes.contains(runtime), sidebar: true, labelWidth: 20) {
                            if let logo = Palette.runtimeLogoName(runtime.rawValue) {
                                Image(logo)
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .interfaceFrame(width: 18, height: 18)
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
                Spacer(minLength: 0)
            }
            .accessibilityLabel(Text("sessions.filter.runtime"))

            HStack(spacing: 6 * interfaceScale) {
                MacFilterChoices {
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
                activeOnly = true
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
                activeOnly = true
                runtimes = Set(SessionRuntimeFilter.ordered.filter { $0 != .all })
                projects = Set(choices.prefix(2).map { .project(path: $0.path) })
            }
            if arguments.contains("-CorralInspectDarkFilters") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if arguments.contains("-CorralInspectProjectPicker") { showProjects = true }
        }
        #endif
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

/// Native capsules; macOS `.bordered` ignores tint, so a selected choice is
/// the accent-filled `.borderedProminent` capsule. When macOS mutes an
/// inactive window's fill, the label contrast keeps the selection readable.
/// Shared with the New Session dialog.
struct MacQuickFilterButton<Content: View>: View {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.interfaceScale) private var interfaceScale
    let selected: Bool
    var sidebar = false
    var labelWidth: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        Group {
            if selected {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(Palette.accent)
        .interfaceFrame(height: MacSidebarMetrics.filterHeight)
        .accessibilityAddTraits(selected ? .isSelected : [])
        #if DEBUG
        .environment(\.controlActiveState, InspectionLaunchOptions.forcesKeyWindowControls ? .key : activeState)
        #endif
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
            HStack(spacing: Space.xs) { content() }
                .frame(width: labelWidth.map { $0 * interfaceScale })
                .interfaceFont(.callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Keep choices on one line and reveal overflow without a second picker step.
struct MacFilterChoices<Content: View>: View {
    @Namespace private var coordinateSpace
    @State private var contentFrame: CGRect = .zero
    @State private var viewportWidth: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        let space = coordinateSpace
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { content() }
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

/// Adapted from the iPhone's searchable project picker with Mac controls. It
/// stays open for repeated toggles and closes on a click outside or Esc.
struct MacProjectFilterPopover: View {
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
                Button {
                    selected.removeAll()
                } label: {
                    HStack {
                        Label("sessions.filter.all", systemImage: "line.3.horizontal.decrease")
                        Spacer()
                        if selected.isEmpty { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(visibleOptions, id: \.path) { option in
                    Toggle(isOn: selection(.project(path: option.path))) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            if option.label == "~" { Text("sessions.project.home") }
                            else { Text(verbatim: option.label) }
                            Text(verbatim: option.path)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if hasNoProject {
                    Toggle(isOn: selection(.noProject)) {
                        Label("sessions.filter.project.none", systemImage: "folder.badge.questionmark")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 360, height: 420)
        .tint(.primary)
        .focusEffectDisabled()
    }

    private func selection(_ project: SessionProjectFilter) -> Binding<Bool> {
        Binding(
            get: { selected.contains(project) },
            set: { enabled in
                if enabled { selected.insert(project) } else { selected.remove(project) }
            }
        )
    }
}
