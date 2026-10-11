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
    @State private var showProjects = false
    #endif
    @State private var unconfirmedCreation: PendingSessionCreation?
    @State private var errorMessage: String?
    @State private var hapticScope = HapticScope()
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

    private var canStart: Bool { options.canCreate }

    #if os(macOS)
    /// A desktop dialog in the quick filters' form: one row of assistant
    /// capsules, one row of recent-project capsules with More for the whole
    /// catalog, then the action. Selections are single-choice.
    private var macContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("session.new.title")
                .interfaceFont(.title2.weight(.semibold))
                .interfacePadding(.horizontal, Space.xl)
                .interfacePadding(.top, Space.xl)
                .interfacePadding(.bottom, Space.lg)

            VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
                macFieldLabel("session.new.runtime")
                MacFilterChoices {
                    ForEach(usableRuntimes) { runtime in
                        MacQuickFilterButton(selected: runtime.id == options.selectedRuntime) {
                            if let logo = Palette.runtimeLogoName(runtime.id) {
                                Image(logo)
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .interfaceFrame(width: 16, height: 16)
                                    .accessibilityHidden(true)
                            }
                            Text(verbatim: runtime.name ?? runtime.id)
                        } action: {
                            options.selectedRuntime = runtime.id
                        }
                    }
                }
                .interfacePadding(.bottom, Space.md)
                macFieldLabel("session.new.project")
                HStack(spacing: Space.xs * interfaceScale) {
                    MacFilterChoices {
                        ForEach(quickProjects) { project in
                            MacQuickFilterButton(selected: project.path == options.selectedProject) {
                                Text(verbatim: project.displayName)
                            } action: {
                                options.selectedProject = project.path
                            }
                            .help(Text(verbatim: project.path))
                        }
                    }
                    Button {
                        showProjects = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .interfaceFont(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .interfaceFrame(width: 28, height: MacSidebarMetrics.filterHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("sessions.filter.more"))
                    .help(Text("sessions.filter.more"))
                    .popover(isPresented: $showProjects) {
                        MacNewSessionProjectPopover(projects: options.projects, selection: $options.selectedProject)
                    }
                }
                .overlay(alignment: .leading) {
                    if options.isLoading && options.projects.isEmpty { ProgressView().interfaceControlSize(.small) }
                }
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
            .disabled(options.isLoading || isCreating)
            .interfacePadding(.horizontal, Space.xl)
            .interfacePadding(.bottom, Space.xl)

            Divider()
            macFooter
        }
        .interfaceFrame(width: 560)
        .focusEffectDisabled()
    }

    private func macFieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .interfaceFont(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// The catalog arrives most recent first; its head is the quick set, and
    /// a selection made through More stays visible in front of it.
    private var quickProjects: [ProjectEntry] {
        let named = options.projects.filter { !$0.path.isEmpty }
        let recent = Array(named.prefix(SessionListFiltering.recentLimit))
        guard !recent.contains(where: { $0.path == options.selectedProject }),
              let selected = options.projects.first(where: { $0.path == options.selectedProject }) else { return recent }
        return recent + [selected]
    }

    private var macFooter: some View {
        HStack(spacing: Space.md * interfaceScale) {
            if let project = options.projects.first(where: { $0.path == options.selectedProject }), !project.path.isEmpty {
                Text(verbatim: (project.path as NSString).abbreviatingWithTildeInPath)
                    .interfaceFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

    #if os(iOS)
    /// One-step start from a remembered combo. The trailing "Start" says the
    /// row acts immediately; a chevron would promise another page.
    private func recentRow(_ combo: RecentSessionCombo) -> some View {
        Button {
            Task { await createFromCombo(combo) }
        } label: {
            HStack(spacing: Space.sm * interfaceScale) {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteCombo(combo)
            } label: {
                Label("action.delete", systemImage: "trash")
            }
        }
    }

    /// The project name already says where; the path only tells apart two
    /// rows that would otherwise read the same.
    private func needsPath(_ combo: RecentSessionCombo) -> Bool {
        !combo.projectPath.isEmpty && recentCombos.contains { $0.id != combo.id && $0.title == combo.title }
    }
    #endif

    private func loadOptions() async {
        recentCombos = RecentSessionComboStore.load(hostID: host.hostID)
        errorMessage = nil
        await options.load { method in
            guard let client = appModel.client, appModel.connectedHostID == host.hostID else {
                throw RemoteCallError(code: "not_connected", message: String(localized: "error.not_connected"), hint: "")
            }
            return try await client.call(method)
        }
        #if os(macOS)
        // The usual combination is preselected, so Return starts it at once.
        if let combo = recentCombos.first(where: { combo in
            options.runtimes.contains { $0.id == combo.runtimeID && $0.isUsable }
                && options.projects.contains { $0.path == combo.projectPath }
        }) {
            options.selectedRuntime = combo.runtimeID
            options.selectedProject = combo.projectPath
        }
        #endif
        if !preferredProject.isEmpty, options.projects.contains(where: { $0.path == preferredProject }) {
            options.selectedProject = preferredProject
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectNewSessionProjects") {
            #if os(macOS)
            showProjects = true
            #else
            navigationPath = [.projects]
            #endif
        }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectCreateSession") {
            await create()
        }
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

    #if os(iOS)
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
    #endif


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

    #if os(iOS)
    /// Left-swipe delete on one recent row. State updates immediately so
    /// the row vanishes without reopening the sheet; store write follows.
    private func deleteCombo(_ combo: RecentSessionCombo) {
        recentCombos.removeAll { $0.id == combo.id }
        RecentSessionComboStore.remove(hostID: host.hostID, comboID: combo.id)
    }
    #endif
}

/// Pages pushed inside the New Session sheet (iPhone).
enum NewSessionRoute: Hashable {
    case projects
}
