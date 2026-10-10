import SwiftUI

struct NewSessionSheet: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let host: HostInfo
    /// Project to preselect when the host lists it (Mac: the focused pane's).
    var preferredProject = ""
    var onCreated: (SessionSummary) -> Void

    @State private var options = NewSessionOptions()
    @State private var recentCombos: [RecentSessionCombo] = []
    @State private var isCreating = false
    @State private var creatingComboID: String?
    #if os(macOS)
    @State private var hoveredComboID: String?
    #endif
    @State private var unconfirmedCreation: PendingSessionCreation?
    @State private var errorMessage: String?
    @State private var hapticScope = HapticScope()
    @State private var projectQuery = ""
    @State private var navigationPath: [NewSessionRoute] = []

    var body: some View {
        Group {
            #if os(macOS)
            macContent
            #else
            mobileContent
            #endif
        }
        .hapticScope(hapticScope)
        .task { await loadOptions() }
        .onAppear { recentCombos = RecentSessionComboStore.load(hostID: host.hostID) }
    }

    #if os(iOS)
    private var mobileContent: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                if !recentCombos.isEmpty {
                    Section("session.new.recent") {
                        ForEach(recentCombos) { combo in
                            recentRow(combo)
                        }
                    }
                }
                choosers
                if options.isLoading {
                    Section { ProgressView("session.new.loading") }
                }
                if let errorMessage = errorMessage ?? options.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(Palette.danger)
                        creationRecovery
                        if options.errorMessage != nil {
                            Button("action.retry") { Task { await loadOptions() } }
                                .disabled(options.isLoading || isCreating)
                        }
                    }
                }
            }
            .navigationTitle("session.new.title")
            .navigationDestination(for: NewSessionRoute.self) { _ in
                NewSessionProjectList(projects: options.projects, selection: $options.selectedProject)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        Text("session.new.start")
                    }
                    .tint(Palette.accent)
                    .disabled(!canStart || isCreating)
                }
            }
        }
    }
    #endif

    private var usableRuntimes: [RuntimeEntry] { options.runtimes.filter(\.isUsable) }

    private var visibleProjects: [ProjectEntry] {
        ProjectEntry.matching(options.projects, query: projectQuery)
    }

    /// A project hidden by the search cannot be started by accident.
    private var canStart: Bool {
        options.canCreate && visibleProjects.contains { $0.path == options.selectedProject }
    }

    #if os(macOS)
    /// A desktop dialog: recents are a shortcut beside the main choices,
    /// leaving the entire project catalog and the action in one viewport.
    private var macContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("session.new.title")
                .interfaceFont(.title2.weight(.semibold))
                .interfacePadding(.horizontal, Space.xl)
                .interfacePadding(.top, Space.xl)
                .interfacePadding(.bottom, Space.lg)

            HStack(alignment: .top, spacing: 0) {
                if !recentCombos.isEmpty {
                    macRecents
                        .interfaceFrame(width: 224)
                    Divider()
                }
                macChoices
                    .interfacePadding(.horizontal, Space.xl)
            }
            .interfacePadding(.bottom, Space.lg)

            Divider()
            macFooter
        }
        .interfaceFrame(width: 820, height: 540)
    }

    private var macRecents: some View {
        VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
            Text("session.new.recent.compact")
                .interfaceFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .interfacePadding(.horizontal, Space.base)
            List {
                ForEach(recentCombos) { combo in
                    recentRow(combo)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .interfacePadding(.horizontal, Space.sm)
    }

    private var macChoices: some View {
        VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
            Text("session.new.runtime")
                .interfaceFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            RuntimeSegmentedControl(runtimes: usableRuntimes, selection: $options.selectedRuntime)
                .interfaceControlSize(.regular)
                .disabled(options.isLoading || isCreating)
                .interfacePadding(.bottom, Space.sm)
            Text("session.new.project")
                .interfaceFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ProjectSearchField(text: $projectQuery, onMove: moveProject) {
                Task { await create() }
            }
            .interfaceFrame(height: 28)
            .disabled(options.isLoading || isCreating)
            projectList
            creationRecovery
            if let message = errorMessage ?? options.errorMessage {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: message)
                        .interfaceFont(.callout)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    if options.errorMessage != nil {
                        Button("action.retry") { Task { await loadOptions() } }
                            .disabled(options.isLoading || isCreating)
                    }
                }
            }
        }
    }

    private var macFooter: some View {
        HStack(spacing: Space.md * interfaceScale) {
            if let project = options.projects.first(where: { $0.path == options.selectedProject }), canStart {
                RuntimeBadge(runtimeID: options.selectedRuntime, size: 28)
                VStack(alignment: .leading, spacing: 2 * interfaceScale) {
                    Text(verbatim: "\(options.runtimes.first { $0.id == options.selectedRuntime }?.name ?? options.selectedRuntime) · \(project.displayName)")
                        .interfaceFont(.callout.weight(.semibold))
                        .lineLimit(1)
                    if !project.path.isEmpty {
                        Text(verbatim: (project.path as NSString).abbreviatingWithTildeInPath)
                            .interfaceFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(project.path)
            }
            Spacer(minLength: Space.md * interfaceScale)
            if isCreating { ProgressView().interfaceControlSize(.small) }
            Button("action.cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("session.new.start") { Task { await create() } }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart || isCreating)
        }
        .interfaceControlSize(.large)
        .interfacePadding(.horizontal, Space.xl)
        .interfacePadding(.vertical, Space.base)
    }

    private var projectList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding<String?>(
                get: { options.selectedProject },
                set: { if let path = $0 { options.selectedProject = path } }
            )) {
                ForEach(visibleProjects) { project in
                    NewSessionProjectRow(project: project)
                        .nativeOverlayScrollers()
                        .tag(project.path)
                        .id(project.path)
                        // Rounded highlights alone separate the rows.
                        .listRowSeparator(.hidden)
                }
            }
            // The inset style draws the selection as a rounded, inset
            // highlight that matches the rounded group around it; the plain
            // style's square edge-to-edge bar did not.
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Double-click starts, like Return.
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { _ in
                Task { await create() }
            })
            .overlay {
                if options.isLoading {
                    ProgressView()
                } else if visibleProjects.isEmpty, options.isReady {
                    ContentUnavailableView.search(text: projectQuery)
                }
            }
            .interfaceFrame(maxHeight: .infinity)
            .disabled(options.isLoading || isCreating)
            .onChange(of: options.selectedProject) { _, path in
                proxy.scrollTo(path, anchor: .center)
            }
            .onChange(of: options.isReady) { _, ready in
                if ready { proxy.scrollTo(options.selectedProject, anchor: .center) }
            }
            .onChange(of: projectQuery) { _, _ in followSearch() }
            .task {
                await Task.yield()
                proxy.scrollTo(options.selectedProject, anchor: .center)
            }
        }
    }

    private func moveProject(by delta: Int) {
        let visible = visibleProjects
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.path == options.selectedProject } ?? -1
        let next = min(max(current + delta, 0), visible.count - 1)
        options.selectedProject = visible[next].path
    }
    #else
    /// Two rows in one group, so recents, both choices and Start all fit on
    /// one screen: the assistant opens a menu of logos and names, the project
    /// a searchable list instead of one long menu.
    @ViewBuilder
    private var choosers: some View {
        Section("session.new.choose") {
            Picker(selection: $options.selectedRuntime) {
                ForEach(usableRuntimes) { runtime in
                    Label {
                        Text(verbatim: runtime.name ?? runtime.id)
                    } icon: {
                        RuntimeMenuIcon(runtimeID: runtime.id)
                    }
                    .tag(runtime.id)
                }
            } label: {
                Text("session.new.runtime")
            }
            .pickerStyle(.menu)
            .disabled(options.isLoading || isCreating)
            NavigationLink(value: NewSessionRoute.projects) {
                LabeledContent {
                    Text(verbatim: options.projects.first { $0.path == options.selectedProject }?.displayName ?? "")
                        .lineLimit(1)
                } label: {
                    Text("session.new.project")
                }
            }
            .disabled(options.isLoading || isCreating || options.projects.isEmpty)
        }
    }
    #endif

    /// When the search hides the chosen project, the first match takes over,
    /// so Return always starts what the list highlights.
    private func followSearch() {
        let visible = visibleProjects
        guard !visible.isEmpty, !visible.contains(where: { $0.path == options.selectedProject }) else { return }
        options.selectedProject = visible[0].path
    }

    /// One-step start from a remembered combo. The trailing "Start" says the
    /// row acts immediately; a chevron would promise another page.
    private func recentRow(_ combo: RecentSessionCombo) -> some View {
        Button {
            Task { await createFromCombo(combo) }
        } label: {
            HStack(spacing: Space.sm * interfaceScale) {
                #if os(macOS)
                RuntimeBadge(runtimeID: combo.runtimeID, size: 24)
                VStack(alignment: .leading, spacing: 3 * interfaceScale) {
                    Text(verbatim: combo.projectName?.isEmpty == false
                         ? (combo.projectName ?? "")
                         : (combo.projectPath.isEmpty ? "—" : (combo.projectPath as NSString).lastPathComponent))
                        .interfaceFont(.callout.weight(.medium))
                        .foregroundStyle(hoveredComboID == combo.id ? Palette.accent : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: combo.runtimeName ?? combo.runtimeID)
                        .interfaceFont(.caption)
                        .foregroundStyle(.secondary)
                    if needsPath(combo) {
                        Text(verbatim: (combo.projectPath as NSString).abbreviatingWithTildeInPath)
                            .interfaceFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                #else
                RuntimeBadge(runtimeID: combo.runtimeID, size: 28)
                VStack(alignment: .leading, spacing: 2 * interfaceScale) {
                    Text(combo.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if needsPath(combo) {
                        Text(combo.projectPath)
                            .interfaceFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                #endif
                Spacer(minLength: Space.sm * interfaceScale)
                if creatingComboID == combo.id {
                    ProgressView()
                        .interfaceControlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
        .accessibilityLabel(Text(combo.title))
        .accessibilityHint(Text("session.new.recent.hint"))
        #if os(macOS)
        .onHover { hovering in hoveredComboID = hovering ? combo.id : nil }
        .help(Text("session.new.start_in \(combo.runtimeName ?? combo.runtimeID) \(combo.projectName ?? (combo.projectPath as NSString).lastPathComponent)"))
        #endif
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteCombo(combo)
            } label: {
                Label("action.delete", systemImage: "trash")
            }
        }
        #if os(macOS)
        // A mouse has no swipe; the row's context menu removes it.
        .contextMenu {
            Button(role: .destructive) {
                deleteCombo(combo)
            } label: {
                Label("action.delete", systemImage: "trash")
            }
        }
        #endif
    }

    /// The project name already says where; the path only tells apart two
    /// rows that would otherwise read the same.
    private func needsPath(_ combo: RecentSessionCombo) -> Bool {
        !combo.projectPath.isEmpty && recentCombos.contains { $0.id != combo.id && $0.title == combo.title }
    }

    private func loadOptions() async {
        recentCombos = RecentSessionComboStore.load(hostID: host.hostID)
        errorMessage = nil
        await options.load { method in
            guard let client = appModel.client, appModel.connectedHostID == host.hostID else {
                throw RemoteCallError(code: "not_connected", message: String(localized: "error.not_connected"), hint: "")
            }
            return try await client.call(method)
        }
        if !preferredProject.isEmpty, options.projects.contains(where: { $0.path == preferredProject }) {
            options.selectedProject = preferredProject
        }
        #if DEBUG
        if let preset = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PROJECT_QUERY"] {
            projectQuery = preset
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectNewSessionProjects") {
            navigationPath = [.projects]
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectCreateSession") {
            await create()
        }
        #if os(macOS)
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectCreateRecentSession"),
           let combo = recentCombos.first {
            await createFromCombo(combo)
        }
        #endif
        #endif
    }

    private func create() async {
        guard canStart else { return }
        await createSession(
            runtimeID: options.selectedRuntime,
            runtimeName: options.runtimes.first { $0.id == options.selectedRuntime }?.name,
            projectPath: options.selectedProject,
            projectName: options.projects.first { $0.path == options.selectedProject }?.name
        )
    }

    /// One-tap create from a remembered combo. A stale combo (assistant or
    /// project removed on the host) surfaces the host error in the sheet
    /// instead of silently creating something else.
    private func createFromCombo(_ combo: RecentSessionCombo) async {
        await createSession(
            runtimeID: combo.runtimeID,
            runtimeName: combo.runtimeName,
            projectPath: combo.projectPath,
            projectName: combo.projectName,
            comboID: combo.id
        )
    }

    @ViewBuilder
    private var creationRecovery: some View {
        if let record = unconfirmedCreation {
            Button("session.new.start_another") {
                Task {
                    guard !isCreating else { return }
                    do {
                        try PendingSessionCreationStore.remove(record)
                        unconfirmedCreation = nil
                        await createSession(
                            runtimeID: record.runtimeID, runtimeName: nil,
                            projectPath: record.cwd, projectName: nil
                        )
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            .disabled(isCreating)
        }
    }

    private func createSession(
        runtimeID: String,
        runtimeName: String?,
        projectPath: String,
        projectName: String?,
        comboID: String? = nil
    ) async {
        guard !isCreating else { return }
        let operationID = hapticScope.beginOperation()
        isCreating = true
        creatingComboID = comboID
        errorMessage = nil
        unconfirmedCreation = nil
        defer { isCreating = false; creatingComboID = nil }
        guard let client = appModel.client, appModel.connectedHostID == host.hostID else {
            errorMessage = String(localized: "error.not_connected")
            HapticFeedback.shared.emit(.error, operationID: operationID, scope: hapticScope)
            return
        }
        do {
            let session = try await SessionCreationCoordinator.create(
                hostID: host.hostID, runtimeID: runtimeID, cwd: projectPath,
                supportsReceipts: client.hostCapabilities.sessionCreateReceipts,
                call: { method, params in try await client.call(method, params: params) }
            )
            guard !Task.isCancelled, appModel.client === client,
                  appModel.connectedHostID == host.hostID else { return }
            unconfirmedCreation = nil
            RecentSessionComboStore.record(
                hostID: host.hostID,
                runtimeID: runtimeID,
                runtimeName: runtimeName,
                projectPath: projectPath,
                projectName: projectName
            )
            HapticFeedback.shared.emit(.success, operationID: operationID, scope: hapticScope)
            onCreated(session)
            dismiss()
        } catch let error as SessionCreationError {
            if case let .unconfirmed(record, _) = error { unconfirmedCreation = record }
            errorMessage = error.localizedDescription
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
        } catch let error as RemoteCallError {
            errorMessage = error.message
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
        } catch {
            errorMessage = error.localizedDescription
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
        }
    }

    /// Left-swipe delete on one recent row. State updates immediately so
    /// the row vanishes without reopening the sheet; store write follows.
    private func deleteCombo(_ combo: RecentSessionCombo) {
        recentCombos.removeAll { $0.id == combo.id }
        RecentSessionComboStore.remove(hostID: host.hostID, comboID: combo.id)
    }
}

/// Pages pushed inside the New Session sheet (iPhone).
enum NewSessionRoute: Hashable {
    case projects
}
