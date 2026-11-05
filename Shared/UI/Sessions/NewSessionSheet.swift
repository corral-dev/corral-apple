import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    @State private var customProject: ProjectEntry?
    @State private var localCorral: URL?
    @State private var isChoosingFolder = false
    #endif
    @State private var unconfirmedCreation: PendingSessionCreation?
    @State private var errorMessage: String?
    @State private var hapticScope = HapticScope()
    @State private var navigationPath: [NewSessionRoute] = []
    #if DEBUG
    private static var inspectedCreation = false
    #endif

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
        .onAppear { loadRecentCombos() }
    }

    #if os(iOS)
    private var mobileContent: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    mobileChoosers
                    if options.isLoading {
                        ProgressView("session.new.loading")
                    }
                    if let errorMessage = errorMessage ?? options.errorMessage {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(errorMessage).foregroundStyle(Palette.danger)
                            creationRecovery
                            if options.errorMessage != nil {
                                Button("action.retry") { Task { await loadOptions() } }
                                    .disabled(options.isLoading || isCreating)
                            }
                        }
                    }
                    if !recentCombos.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: Space.sm) {
                            mobileFieldLabel("session.new.quick")
                            NewSessionChoiceFlow {
                                ForEach(recentCombos) { mobileQuickStart($0) }
                            }
                        }
                    }
                }
                .padding(Space.base)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("session.new.title")
            .navigationBarTitleDisplayMode(.inline)
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
                        if isCreating { ProgressView() }
                        else { Text("session.new.start") }
                    }
                    .accessibilityLabel(Text("session.new.start"))
                    .tint(Palette.accent)
                    .disabled(!canStart || isCreating)
                }
            }
        }
    }
    #endif

    private var usableRuntimes: [RuntimeEntry] { options.runtimes.filter(\.isUsable) }

    private var canStart: Bool {
        #if os(macOS)
        if isChoosingFolder { return false }
        if let customProject, options.selectedProject == customProject.path {
            return options.isReady && !options.isLoading
                && usableRuntimes.contains { $0.id == options.selectedRuntime }
        }
        #endif
        return options.canCreate
    }

    #if os(macOS)
    /// A desktop dialog in the quick filters' form: a Quick Start row of
    /// one-click combinations, one row of assistant capsules, one row of
    /// recent-project capsules with More for the whole catalog, then the
    /// action. Assistant and project selections are single-choice.
    private var macContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("session.new.title")
                .interfaceFont(.title2.weight(.semibold))
                .interfacePadding(.horizontal, Space.xl)
                .interfacePadding(.top, Space.xl)
                .interfacePadding(.bottom, Space.lg)

            if !recentCombos.isEmpty {
                // Starts need no catalog, so this row does not wait for it.
                VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
                    macFieldLabel("session.new.quick")
                    MacFilterChoices {
                        ForEach(recentCombos) { quickStartButton($0) }
                    }
                }
                .interfacePadding(.horizontal, Space.xl)
                .interfacePadding(.bottom, Space.lg)
                // Starting now and choosing-then-Start read as two zones; the
                // rule is inset to the content edges, unlike the footer's.
                Divider()
                    .interfacePadding(.horizontal, Space.xl)
            }

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
                projectChoices
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
            .disabled(options.isLoading || isCreating || isChoosingFolder)
            .interfacePadding(.horizontal, Space.xl)
            .interfacePadding(.top, recentCombos.isEmpty ? 0 : Space.lg)
            .interfacePadding(.bottom, Space.xl)

            Divider()
            macFooter
        }
        .interfaceFrame(width: 560)
        .focusEffectDisabled()
        .task {
            guard !MacHostCommand.isSandboxed,
                  let corral = await MacHostCommand.locateCorral(),
                  await MacHostCommand.localHostID(corral: corral) == host.hostID,
                  !Task.isCancelled else { return }
            localCorral = corral
        }
    }

    /// Kept separate from the rest of the dialog: one long modifier chain in
    /// this position made the accessibility overloads ambiguous (Xcode 27.2).
    private var projectChoices: some View {
        HStack(spacing: 6 * interfaceScale) {
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
            // Keep the current project visible outside the scrolling quick
            // set, just like the sidebar's pinned picker entry.
            MacQuickFilterButton(selected: selectedProject != nil) {
                projectSummaryLabel
            } action: {
                showProjects = true
            }
            .layoutPriority(1)
            .accessibilityLabel(Text("session.new.project"))
            .accessibilityValue(projectSummaryLabel.title)
            .accessibilityIdentifier("corral.newSession.project")
            .help(selectedProject.map { Text(verbatim: $0.path) } ?? projectSummaryLabel.title)
            .popover(isPresented: $showProjects) {
                MacNewSessionProjectPopover(
                    onOpenFolder: popoverOpenFolder,
                    projects: macProjects, selection: $options.selectedProject
                )
            }
        }
    }

    private var popoverOpenFolder: (() -> Void)? {
        guard localCorral != nil else { return nil }
        return openFolder
    }

    private var macProjects: [ProjectEntry] {
        ProjectEntry.catalog(options.projects, including: customProject)
    }

    private func openFolder() {
        guard let corral = localCorral, !isChoosingFolder, !isCreating else { return }
        showProjects = false
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "session.new.project.open_folder")
        if !options.selectedProject.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: options.selectedProject, isDirectory: true)
        }
        isChoosingFolder = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else {
                isChoosingFolder = false
                return
            }
            Task { @MainActor in
                defer { isChoosingFolder = false }
                do {
                    let path = try await MacHostCommand.allowProject(folder, hostID: host.hostID, corral: corral)
                    guard !Task.isCancelled, appModel.connectedHostID == host.hostID else { return }
                    customProject = ProjectEntry(path: path, name: nil)
                    options.selectedProject = path
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// An action, not a choice: it never shows a selected state, and a click
    /// creates the remembered combination at once.
    private func quickStartButton(_ combo: RecentSessionCombo) -> some View {
        let runtime = combo.runtimeName ?? options.runtimes.first { $0.id == combo.runtimeID }?.name ?? combo.runtimeID
        return MacQuickFilterButton(selected: false) {
            if creatingComboID == combo.id {
                ProgressView()
                    .controlSize(.mini)
                    .interfaceFrame(width: 16, height: 16)
            } else if let logo = Palette.runtimeLogoName(combo.runtimeID) {
                Image(logo)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .interfaceFrame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text(verbatim: combo.projectLabel)
        } action: {
            Task { await createFromCombo(combo) }
        }
        .disabled(isCreating)
        .help(String(localized: "session.new.start_in \(runtime) \(combo.projectLabel)")
            + (combo.projectPath.isEmpty ? "" : "\n" + (combo.projectPath as NSString).abbreviatingWithTildeInPath))
        .accessibilityLabel(Text(combo.title))
        .accessibilityHint(Text("session.new.recent.hint"))
        .contextMenu {
            Button("session.new.quick.remove", role: .destructive) { deleteCombo(combo) }
        }
    }

    private func macFieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .interfaceFont(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Selection never reorders or expands the recent quick set; the pinned
    /// summary exposes every selection, including choices from More.
    private var quickProjects: [ProjectEntry] {
        Array(options.projects.filter { !$0.path.isEmpty }.prefix(SessionListFiltering.recentLimit))
    }

    private var selectedProject: ProjectEntry? {
        macProjects.first { $0.path == options.selectedProject }
    }

    private var projectSummaryLabel: ProjectFilterSummaryLabel {
        let project = selectedProject
        return ProjectFilterSummaryLabel(
            selected: project.map { [$0.path.isEmpty ? .noProject : .project(path: $0.path)] } ?? [],
            options: project.map { [SessionProjectOption(path: $0.path, label: $0.displayName)] } ?? [],
            maximumNameWidth: 108 * interfaceScale
        )
    }

    private var macFooter: some View {
        HStack(spacing: Space.md * interfaceScale) {
            if let project = selectedProject, !project.path.isEmpty {
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
    /// The Mac's visible choices, wrapped and sized for touch. Quick Start is
    /// a separate action group below, so history never displaces the choices.
    private var mobileChoosers: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                mobileFieldLabel("session.new.runtime")
                NewSessionChoiceFlow {
                    ForEach(usableRuntimes) { runtime in
                        NewSessionChoiceButton(selected: runtime.id == options.selectedRuntime) {
                            mobileRuntimeLogo(runtime.id)
                            Text(verbatim: runtime.name ?? runtime.id)
                        } action: {
                            options.selectedRuntime = runtime.id
                            HapticFeedback.shared.emit(.selection)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                mobileFieldLabel("session.new.project")
                NewSessionChoiceFlow {
                    ForEach(mobileQuickProjects) { project in
                        NewSessionChoiceButton(selected: project.path == options.selectedProject) {
                            Text(verbatim: project.displayName)
                        } action: {
                            options.selectedProject = project.path
                            HapticFeedback.shared.emit(.selection)
                        }
                    }
                    NewSessionChoiceButton {
                        Text("sessions.filter.more")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    } action: {
                        navigationPath.append(.projects)
                    }
                    .disabled(options.projects.isEmpty)
                }
                if !options.selectedProject.isEmpty {
                    Text(verbatim: (options.selectedProject as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .disabled(options.isLoading || isCreating)
    }

    private var mobileQuickProjects: [ProjectEntry] {
        var projects = Array(options.projects.filter { !$0.path.isEmpty }.prefix(3))
        if !projects.contains(where: { $0.path == options.selectedProject }),
           let selected = options.projects.first(where: { $0.path == options.selectedProject }) {
            if projects.count == 3 { projects.removeLast() }
            projects.append(selected)
        }
        return projects
    }

    private func mobileFieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func mobileRuntimeLogo(_ runtimeID: String) -> some View {
        if let logo = Palette.runtimeLogoName(runtimeID) {
            Image(logo)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
    #endif

    #if os(iOS)
    /// Same immediate action as the Mac's Quick Start, with no selected state.
    private func mobileQuickStart(_ combo: RecentSessionCombo) -> some View {
        NewSessionChoiceButton {
            if creatingComboID == combo.id {
                ProgressView().controlSize(.small)
                    .frame(width: 20, height: 20)
            } else {
                mobileRuntimeLogo(combo.runtimeID)
            }
            VStack(alignment: .leading, spacing: 2 * interfaceScale) {
                Text(verbatim: combo.projectLabel)
                if needsPath(combo) {
                    Text(verbatim: (combo.projectPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
        } action: {
            Task { await createFromCombo(combo) }
        }
        .disabled(isCreating)
        .accessibilityLabel(Text(combo.title))
        .accessibilityHint(Text("session.new.recent.hint"))
        .contextMenu {
            Button("session.new.quick.remove", role: .destructive) { deleteCombo(combo) }
        }
    }

    /// The project name already says where; the path only tells apart two
    /// rows that would otherwise read the same.
    private func needsPath(_ combo: RecentSessionCombo) -> Bool {
        !combo.projectPath.isEmpty && recentCombos.contains { $0.id != combo.id && $0.title == combo.title }
    }
    #endif

    private func loadOptions() async {
        loadRecentCombos()
        errorMessage = nil
        await options.load { method in
            guard let client = appModel.client, appModel.connectedHostID == host.hostID else {
                throw RemoteCallError(code: "not_connected", message: String(localized: "error.not_connected"), hint: "")
            }
            return try await client.call(method)
        }
        // Both clients start from the most recent still-usable combination.
        if let combo = recentCombos.first(where: { combo in
            options.runtimes.contains { $0.id == combo.runtimeID && $0.isUsable }
                && options.projects.contains { $0.path == combo.projectPath }
        }) {
            options.selectedRuntime = combo.runtimeID
            options.selectedProject = combo.projectPath
        }
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
        // Creation inspection fires once per process: a rebuilt window
        // reopening the sheet must not create the session again.
        let arguments = ProcessInfo.processInfo.arguments
        if !Self.inspectedCreation, arguments.contains("-CorralInspectCreateSession") {
            Self.inspectedCreation = true
            await create()
        }
        if !Self.inspectedCreation, arguments.contains("-CorralInspectCreateRecentSession"), let combo = recentCombos.first {
            Self.inspectedCreation = true
            await createFromCombo(combo)
        }
        #endif
    }

    private func create() async {
        guard canStart else { return }
        #if os(macOS)
        let projectName = selectedProject?.name
        #else
        let projectName = options.projects.first { $0.path == options.selectedProject }?.name
        #endif
        await createSession(
            runtimeID: options.selectedRuntime,
            runtimeName: options.runtimes.first { $0.id == options.selectedRuntime }?.name,
            projectPath: options.selectedProject,
            projectName: projectName
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

    /// Removes one remembered combo through its native context menu.
    /// State updates immediately so it vanishes without reopening the sheet;
    /// the store write follows.
    private func deleteCombo(_ combo: RecentSessionCombo) {
        recentCombos.removeAll { $0.id == combo.id }
        RecentSessionComboStore.remove(hostID: host.hostID, comboID: combo.id)
    }

    /// Combos remembered before a runtime went dormant stay on disk but never
    /// surface as a start (active allowlist, as in the catalog).
    private func loadRecentCombos() {
        recentCombos = RecentSessionComboStore.load(hostID: host.hostID)
            .filter { RuntimeEntry.activeIDs.contains($0.runtimeID.lowercased()) }
    }
}

/// Pages pushed inside the New Session sheet (iPhone).
enum NewSessionRoute: Hashable {
    case projects
}
