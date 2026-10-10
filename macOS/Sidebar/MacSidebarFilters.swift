import SwiftUI

/// Native controls over the unfiltered host window; selections only narrow presentation.
struct MacSidebarFilters: View {
    let sessions: [SessionSummary]
    @Binding var runtimes: Set<SessionRuntimeFilter>
    @Binding var projects: Set<SessionProjectFilter>
    @State private var showProjects = false
    @State private var choices: [SessionProjectOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacFilterChoices {
                ForEach(SessionRuntimeFilter.ordered, id: \.self) { runtime in
                    MacQuickFilterButton(selected: runtime == .all ? runtimes.isEmpty : runtimes.contains(runtime)) {
                        if runtime == .all {
                            Text("sessions.filter.all")
                        } else {
                            if let logo = Palette.runtimeLogoName(runtime.rawValue) {
                                Image(logo)
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .interfaceFrame(width: 16, height: 16)
                                    .accessibilityHidden(true)
                            }
                            Text(verbatim: Palette.runtimeDisplayName(runtime.rawValue))
                        }
                    } action: {
                        SessionListFiltering.toggle(runtime, all: .all, in: &runtimes)
                    }
                }
            }
            .accessibilityLabel(Text("sessions.filter.runtime"))
            HStack(spacing: Space.xs) {
                MacFilterChoices {
                    MacQuickFilterButton(selected: projects.isEmpty) {
                        Text("sessions.filter.all")
                    } action: {
                        projects.removeAll()
                    }
                    if projects.contains(.noProject) {
                        MacQuickFilterButton(selected: true) {
                            Text("sessions.filter.project.none")
                        } action: {
                            projects.remove(.noProject)
                        }
                    }
                    ForEach(selectedOutside + choices, id: \.path) { option in
                        MacQuickFilterButton(selected: projects.contains(.project(path: option.path))) {
                            if option.label == "~" { Text("sessions.project.home") }
                            else { Text(verbatim: option.label) }
                        } action: {
                            SessionListFiltering.toggle(.project(path: option.path), all: .all, in: &projects)
                        }
                        .help(Text(verbatim: option.path))
                    }
                }
                Button {
                    showProjects = true
                } label: {
                    Image(systemName: "ellipsis")
                        .interfaceFont(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .interfaceFrame(width: 28, height: MacSidebarMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("sessions.filter.more"))
                .help(Text("sessions.filter.more"))
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
        .focusEffectDisabled()
        #if DEBUG
        .task(id: choices) {
            guard !choices.isEmpty else { return }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-CorralInspectSelectedFilters") {
                runtimes = [.codex]
                projects = [.project(path: choices[0].path)]
            } else if arguments.contains("-CorralInspectMultiFilters") {
                runtimes = [.claude, .codex]
                projects = Set(choices.prefix(2).map { .project(path: $0.path) })
            }
            if arguments.contains("-CorralInspectProjectPicker") { showProjects = true }
        }
        #endif
    }

    private var selectedOutside: [SessionProjectOption] {
        let visible = Set(choices.map(\.path))
        return projects.compactMap { project in
            guard case .project(let path) = project, !visible.contains(path) else { return nil }
            return SessionListFiltering.option(for: path, sessions: sessions)
        }.sorted { $0.path < $1.path }
    }
}

/// Match the iPhone's quiet native capsules. Text contrast also preserves
/// the selection distinction when macOS mutes an inactive window's tint.
private struct MacQuickFilterButton<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        button
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(selected ? Palette.accent : Color.secondary)
        .interfaceFrame(height: MacSidebarMetrics.rowHeight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) { content() }
                .interfaceFont(.callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Keep choices on one line and reveal overflow without a second picker step.
private struct MacFilterChoices<Content: View>: View {
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

/// Adapted from the iPhone's native searchable project picker, using Mac controls.
struct MacProjectFilterPopover: View {
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
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
            .searchable(text: $query, prompt: Text("sessions.filter.project.search"))
            .navigationTitle("sessions.filter.project.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
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
