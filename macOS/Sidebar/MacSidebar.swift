import AppKit
import SwiftUI

/// Flat sessions with quick filters, independent pins and calendar sections.
/// Split membership is a row marker; the host still owns split restoration.
struct MacSidebar: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.sidebarRowSize) private var rowSize
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    let feed: HostSessionFeed
    var onNewSession: () -> Void
    var onPair: () -> Void

    @State private var filter = ""
    @State private var sectionExpansion: [String: Bool] = [:]
    @State private var filteredSectionExpansion: [String: Bool] = [:]
    @State private var activeOnly = false
    @State private var runtimeFilter: Set<SessionRuntimeFilter> = []
    @State private var projectFilter: Set<SessionProjectFilter> = []
    @State private var orderBox = OrderBox()
    @State private var selectedKeys: Set<String> = []
    @State private var pendingRevealSerial: Int?
    @State private var deleteTargets: [SessionSummary] = []
    @State private var batch = MacSessionBatch()
    @State private var batchError: String?
    #if DEBUG
    @State private var didInspectDeleteConfirmation = false
    @State private var inspectionTick = 0
    @FocusState private var inspectionFocused: Bool
    #endif

    /// Non-observed holder: first-seen order must update during rendering
    /// without triggering another render pass.
    final class OrderBox {
        var order = DesktopSidebarProjection.StableOrder()
    }

    private var sessions: [SessionSummary] { feed.listStore.windowSessions }
    private var filteredSessions: [SessionSummary] {
        SessionListFiltering.apply(sessions: sessions, runtimes: runtimeFilter, projects: projectFilter,
                                   activeOnly: activeOnly)
    }
    private var hasActiveScope: Bool {
        !filter.isEmpty || activeOnly || !runtimeFilter.isEmpty || !projectFilter.isEmpty
    }

    var body: some View {
        // One shared minute tick for every row's relative time (see
        // `sidebarNow`): a hundred rows must not run a hundred per-minute timers.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content
                .modifier(MacZoomContent())
                .environment(\.sidebarNow, context.date)
        }
            .task {
                  feed.listStore.refreshCalendar()
                #if DEBUG
                  if ProcessInfo.processInfo.arguments.contains("-CorralInspectSearchNavigation") {
                      filter = "__corral_navigation_conflicting_filter__"
                      activeOnly = true
                  }
                  if ProcessInfo.processInfo.arguments.contains("-CorralInspectPaneSelection") {
                      await inspectPaneSelection()
                      return
                  }
                await MacScrollbarInspection.runIfRequested()
                if ProcessInfo.processInfo.arguments.contains("-CorralInspectDateDisclosures") {
                    await inspectDateDisclosures()
                }
                  if ProcessInfo.processInfo.arguments.contains("-CorralInspectSessionMultiSelection") {
                      await inspectSessionMultiSelection()
                      return
                  }
                if ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebarGeometry") {
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        recordSidebarGeometry()
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("-CorralInspectCollapsedDates") {
                    try? await Task.sleep(for: .seconds(3))
                    let sections = DesktopSidebarProjection.sections(
                        sessions: filteredSessions, layout: sidebarLayout, filter: filter, order: &orderBox.order
                    )
                    for section in sections { expansion(for: section).wrappedValue = false }
                }
                if ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebarSelection") {
                    for tick in 0..<12 {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        inspectionFocused = tick.isMultiple(of: 2)
                        try? await Task.sleep(for: .milliseconds(300))
                        let window = NSApp.windows.first { $0.title == "Corral" }
                        let evidence: [String: Any] = [
                            "tick": tick,
                            "focusRequested": inspectionFocused,
                            "tableFirstResponder": window?.firstResponder is NSTableView,
                            "keyWindow": window?.isKeyWindow == true,
                            "selected": Array(selectedKeys).sorted(),
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: evidence) {
                            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-sidebar-selection.json"), options: .atomic)
                        }
                    }
                    return
                }
                guard ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebar") else { return }
                // Local projection only; host groups and user input stay intact.
                for tick in 1...24 {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    inspectionTick = tick
                }
                #endif
            }
            .searchable(text: $filter, placement: .sidebar, prompt: Text("mac.sidebar.filter"))
            .onChange(of: feed.host.id) { _, _ in
                filter = ""
                activeOnly = false
                runtimeFilter.removeAll()
                projectFilter.removeAll()
                sectionExpansion.removeAll()
                filteredSectionExpansion.removeAll()
                selectedKeys.removeAll()
                deleteTargets.removeAll()
            }
            .onChange(of: workspace.focusedKey, initial: true) { _, key in
                selectedKeys = key.map { visibleKeys.contains($0) ? [$0] : [] } ?? []
            }
            .onChange(of: workspace.paneFocusSerial) { _, _ in
                selectedKeys = workspace.focusedKey.map { visibleKeys.contains($0) ? [$0] : [] } ?? []
            }
            .onChange(of: visibleKeys) { previous, visible in
                selectedKeys.formIntersection(visible)
                if selectedKeys.isEmpty, let key = workspace.focusedKey,
                   !previous.contains(key), visible.contains(key) { selectedKeys = [key] }
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: Binding(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } }),
                titleVisibility: .visible,
                presenting: deleteTargets
            ) { targets in
                Button(role: .destructive) {
                    deleteTargets = []
                    perform(.delete, on: targets)
                } label: {
                    Label("sessions.action.delete", systemImage: "trash")
                }
                Button("action.cancel", role: .cancel) { deleteTargets = [] }
            } message: { targets in
                Text(verbatim: deleteMessage(targets))
            }
            .alert("mac.sessions.action_failed", isPresented: Binding(
                get: { batchError != nil }, set: { if !$0 { batchError = nil } }
            )) {
                Button("action.ok", role: .cancel) { batchError = nil }
            } message: {
                Text(verbatim: batchError ?? "")
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                MacSidebarFilters(
                    sessions: sessions,
                    activeCount: SessionListFiltering.activeCount(sessions: sessions),
                    activeOnly: $activeOnly, runtimes: $runtimeFilter, projects: $projectFilter
                )
                    .id(feed.host.id)
                    .modifier(MacZoomContent())
                    .interfacePadding(.horizontal, Space.md)
                    .interfacePadding(.vertical, 6)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: Space.sm * interfaceScale) {
                    if selectedKeys.count > 1 || batch.isRunning {
                        HStack(spacing: Space.sm * interfaceScale) {
                            if batch.isRunning {
                                ProgressView().controlSize(.small)
                                Text("mac.sessions.progress \(batch.completed) \(batch.total)")
                            } else {
                                Text("mac.sessions.selected \(selectedKeys.count)")
                            }
                            Spacer(minLength: 0)
                            Menu {
                                sessionMenu(selectedSessions)
                            } label: {
                                Label("mac.sessions.actions", systemImage: "ellipsis.circle")
                            }
                            .fixedSize()
                            .accessibilityIdentifier("corral.session.selection-actions")
                            .disabled(batch.isRunning)
                            Button { selectedKeys.removeAll() } label: {
                                Label("mac.sessions.clear_selection", systemImage: "xmark")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help(Text("mac.sessions.clear_selection"))
                        }
                        .interfaceFont(.system(size: 12))
                        Divider()
                    }
                    HStack(spacing: Space.sm * interfaceScale) {
                        MachineSwitcher(onPair: onPair)
                        Spacer(minLength: 0)
                    }
                }
                .modifier(MacZoomContent())
                .interfacePadding(.horizontal, Space.md)
                .interfacePadding(.vertical, 12)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onNewSession) {
                        Label("sessions.new", systemImage: "square.and.pencil")
                    }
                    .help(Text("sessions.new"))
                    .disabled(!canCreate)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if feed.isLoading && sessions.isEmpty {
            ProgressView().interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = feed.loadError, sessions.isEmpty {
            ContentUnavailableView {
                Label("sessions.load_failed.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("action.retry") { Task { await feed.reconnect() } }
            }
        } else {
            list
        }
    }

    private var sidebarLayout: DesktopLayout {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebar") {
            let keys = Array(sessions.prefix(4).map(\.key))
            guard keys.count == 4 else { return .empty }
            switch inspectionTick % 4 {
            case 1:
                return DesktopLayout(revision: 0, groups: [
                    DesktopGroup(id: "sidebar-inspection", name: "Sidebar inspection", members: Array(keys.prefix(2)))
                ], pinnedSessions: [:])
            case 2:
                return DesktopLayout(revision: 0, groups: [
                    DesktopGroup(id: "sidebar-inspection", name: "Sidebar inspection", members: Array(keys.suffix(3)))
                ], pinnedSessions: [:])
            case 3:
                return DesktopLayout(revision: 0, groups: [
                    DesktopGroup(id: "sidebar-inspection", name: "Sidebar inspection", members: keys, collapsed: true)
                ], pinnedSessions: [:])
            default: return .empty
            }
        }
        #endif
        return workspace.layout
    }

    private var list: some View {
        let sections = sidebarSections
        return ScrollViewReader { proxy in
        VStack(spacing: 0) {
        List(selection: selectionBinding(for: sections)) {
            ForEach(sections) { section in
                Section(isExpanded: expansion(for: section)) {
                    ForEach(section.items, id: \.session.key) { item in
                        itemView(item)
                    }
                } header: {
                    Button { toggleSection(section) } label: {
                        HStack(spacing: Space.sm * interfaceScale) {
                            Text(verbatim: title(for: section))
                                .interfaceFont(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .fixedSize()
                            VStack(spacing: 0) {
                                Divider()
                                    .overlay(Color(nsColor: .separatorColor).opacity(0.65))
                            }
                                .frame(maxWidth: .infinity)
                            Text(verbatim: section.items.count.formatted())
                                .interfaceFont(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .fixedSize()
                        }
                        .interfaceFrame(height: MacSidebarMetrics.sectionHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("corral.date-section.\(section.id)")
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { keys in
            sessionMenu(orderedSessions(for: keys))
        }
        .onDeleteCommand(perform: canCreate && !batch.isRunning && !selectedKeys.isEmpty ? {
            deleteTargets = selectedSessions
        } : nil)
        .environment(\.defaultMinListRowHeight, MacSidebarMetrics.compactRowHeight * interfaceScale)
        .environment(\.defaultMinListHeaderHeight, MacSidebarMetrics.sectionHeight * interfaceScale)
        // Keep scrolling rows legible beneath the native search and machine bars.
        .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
        #if DEBUG
        .focused($inspectionFocused)
        #endif
        .focusEffectDisabled()
        .task(id: pendingRevealSerial) {
            let serial = workspace.navigation.host.revealSerial
            guard pendingRevealSerial == serial,
                  let key = workspace.navigation.host.revealKey, visibleKeys.contains(key) else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            selectedKeys = [key]
            proxy.scrollTo(key, anchor: .center)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard pendingRevealSerial == serial,
                      workspace.navigation.host.revealSerial == serial else { return }
                // A destination that never mounts must not keep swallowing
                // native selection callbacks.
                pendingRevealSerial = nil
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectSearchNavigation") {
                Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard workspace.navigation.host.revealKey == key else { break }
                    recordNavigationReveal(key)
                }
                }
            }
            #endif
        }
        }
        .onChange(of: workspace.navigation.host.revealSerial, initial: true) { _, _ in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectSearchNavigation") {
                workspace.navigation.host.inspectionEvents.append("reveal observer: \(workspace.navigation.host.revealKey ?? "nil")")
            }
            #endif
            guard workspace.navigation.host.revealKey != nil else { return }
            pendingRevealSerial = workspace.navigation.host.revealSerial
            guard let key = revealNavigationTarget() else { pendingRevealSerial = nil; return }
            selectedKeys = [key]
        }
        }
    }

    private func revealNavigationTarget() -> String? {
        guard let key = workspace.navigation.host.revealKey,
              let session = feed.listStore.session(for: key) else { return nil }
        if !DesktopSidebarProjection.matches(session, filter: filter) { filter = "" }
        if SessionListFiltering.apply(sessions: [session], runtimes: runtimeFilter,
                                      projects: [], activeOnly: false).isEmpty { runtimeFilter = [] }
        if SessionListFiltering.apply(sessions: [session], runtimes: [],
                                      projects: projectFilter, activeOnly: false).isEmpty { projectFilter = [] }
        if SessionListFiltering.apply(sessions: [session], runtimes: [],
                                      projects: [], activeOnly: activeOnly).isEmpty { activeOnly = false }
        guard let section = sidebarSections.first(where: { $0.items.contains { $0.session.key == key } }) else { return nil }
        if hasActiveScope { filteredSectionExpansion[section.id] = true }
        else {
            sectionExpansion[section.id] = true
            filteredSectionExpansion[section.id] = nil
        }
        return key
    }

    #if DEBUG
    private func recordNavigationReveal(_ key: String) {
        func marker(_ view: NSView) -> NativeSidebarSelection.SelectionAppearanceView? {
            if let found = view as? NativeSidebarSelection.SelectionAppearanceView, found.debugKey == key {
                return found
            }
            return view.subviews.lazy.compactMap(marker).first
        }
        let root = NSApp.windows.first(where: { $0.title == "Corral" })?.contentView
        let state = root.flatMap(marker)?.debugRowState()
        workspace.navigation.host.inspectionSidebarKey = key
        workspace.navigation.host.inspectionSidebar = [
            "membership": sessions.contains { $0.key == key },
            "expanded": visibleKeys.contains(key),
            "selected": selectedKeys == [key],
            "nativeSelected": state?.selected == true,
            "rowVisible": state?.visible == true,
            "conflictingFiltersCleared": filter.isEmpty && !activeOnly,
        ]
    }
    #endif

    /// Titles, previews, timestamps and attention update in place. Selection
    /// and disclosure state are owned outside the native list lifetime.
    private enum StructureEntry: Hashable {
        case section(String)
        case session(String)
    }

    private func listStructure(_ sections: [DesktopSidebarProjection.Section]) -> [StructureEntry] {
        var entries: [StructureEntry] = []
        for section in sections {
            entries.append(.section(section.id))
            for item in section.items where expansion(for: section).wrappedValue {
                entries.append(.session(item.session.key))
            }
        }
        return entries
    }

    // MARK: - Rows

    private func itemView(_ item: DesktopSidebarProjection.Item) -> some View {
        sessionRow(item.session, split: item.split)
    }

    private func sessionRow(_ session: SessionSummary, split: DesktopGroup?) -> some View {
        MacSessionRow(session: session, splitHelp: split.map(splitHelp),
                      isSelected: selectedKeys.contains(session.key))
            .listRowInsets(.vertical, 0)
            .listRowSeparator(.visible, edges: .bottom)
            .listRowSeparatorTint(Color(nsColor: .separatorColor).opacity(0.5), edges: .bottom)
            .background(NativeSidebarSelection(
                revealSerial: workspace.navigation.host.revealKey == session.key ? pendingRevealSerial : nil,
                onReveal: {
                    guard workspace.navigation.host.revealKey == session.key else { return }
                    selectedKeys = [session.key]
                    pendingRevealSerial = nil
                },
                debugKey: ProcessInfo.processInfo.arguments.contains("-CorralInspectSearchNavigation")
                    ? session.key : nil))
            .tag(session.key)
            .onAppear { feed.listStore.rememberOpened(session) }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-CorralInspectDeleteConfirmation"),
                      ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == session.key,
                      !didInspectDeleteConfirmation else { return }
                didInspectDeleteConfirmation = true
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                deleteTargets = [session]
            }
            #endif
    }

    private func splitHelp(_ split: DesktopGroup) -> String {
        let members = sessions.filter { split.members.contains($0.key) }
        let path = split.project.isEmpty ? (members.first?.cwd ?? "") : split.project
        return ([String(localized: "mac.group.split"), path]
            + members.map { SessionPresentation.displayTitle(for: $0) })
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Menus

    @ViewBuilder
    private func sessionMenu(_ targets: [SessionSummary]) -> some View {
        if !targets.isEmpty {
            Group {
                if targets.count == 1, let session = targets.first {
                    Button {
                        workspace.addPane(session.key, project: session.cwd)
                    } label: {
                        Label("mac.session.open_in_split", systemImage: "rectangle.split.2x1")
                    }
                    .disabled(workspace.paneKeys.isEmpty || !workspace.canAddSessionToSplit(session))
                }
                Button {
                    var seen: Set<String> = []
                    let paths = targets.map(SessionPresentation.fullWorkspacePath)
                        .filter { !$0.isEmpty && seen.insert($0).inserted }
                    PlatformPasteboard.copy(paths.joined(separator: "\n"))
                } label: {
                    Label(targets.count == 1 ? "session.workspace.copy_path" : "mac.sessions.copy_paths",
                          systemImage: "doc.on.clipboard")
                }
                Divider()
                let pinned = targets.filter { workspace.layout.pinnedSessions[$0.key] != nil }
                let unpinned = targets.filter { workspace.layout.pinnedSessions[$0.key] == nil }
                if !unpinned.isEmpty {
                    Button { perform(.pin, on: unpinned) } label: {
                        if targets.count == 1 {
                            Label("mac.session.pin", systemImage: "pin")
                        } else {
                            Label("mac.sessions.pin \(unpinned.count)", systemImage: "pin")
                        }
                    }
                    .disabled(!canCreate || batch.isRunning)
                }
                if !pinned.isEmpty {
                    Button { perform(.unpin, on: pinned) } label: {
                        if targets.count == 1 {
                            Label("mac.session.unpin", systemImage: "pin.slash")
                        } else {
                            Label("mac.sessions.unpin \(pinned.count)", systemImage: "pin.slash")
                        }
                    }
                    .disabled(!canCreate || batch.isRunning)
                }
                if targets.count == 1, let session = targets.first,
                   let split = workspace.layout.group(containing: session.key) {
                    Button {
                        Task { await workspace.toggleGroupPin(split) }
                    } label: {
                        Label(split.pinned ? "mac.group.unpin" : "mac.group.pin",
                              systemImage: split.pinned ? "pin.slash" : "pin")
                    }
                    .disabled(!canCreate || batch.isRunning)
                }
                Divider()
                let live = targets.filter(\.live)
                if !live.isEmpty {
                    Button { perform(.stop, on: live) } label: {
                        if targets.count == 1 {
                            Label("sessions.action.stop", systemImage: "stop.fill")
                        } else {
                            Label("mac.sessions.stop \(live.count)", systemImage: "stop.fill")
                        }
                    }
                    .disabled(!canCreate || batch.isRunning)
                }
                Button(role: .destructive) { deleteTargets = targets } label: {
                    if targets.count == 1 {
                        Label("sessions.action.delete", systemImage: "trash")
                    } else {
                        Label("mac.sessions.delete \(targets.count)", systemImage: "trash")
                    }
                }
                .disabled(!canCreate || batch.isRunning)
            }
            .labelStyle(.titleAndIcon)
            // Template symbols that invert with the highlighted row's text.
            .tint(nil)
        }
    }

    private var deleteTitle: Text {
        if deleteTargets.count == 1 { Text("sessions.delete_confirm.title") }
        else { Text("mac.sessions.delete_confirm \(deleteTargets.count)") }
    }

    private func deleteMessage(_ targets: [SessionSummary]) -> String {
        let titles = targets.prefix(5).map { SessionPresentation.displayTitle(for: $0) }
        let extra = targets.count > 5 ? [String(localized: "mac.sessions.more \(targets.count - 5)")] : []
        return (titles + extra + [String(localized: "mac.sessions.delete_warning")]).joined(separator: "\n")
    }

    private func perform(_ action: MacSessionBatch.Action, on targets: [SessionSummary]) {
        guard canCreate, !batch.isRunning, !targets.isEmpty else { return }
        let hostID = workspace.hostID
        let client = appModel.client
        Task {
            let result = await batch.run(keys: targets.map(\.key), isCurrent: {
                workspace.hostID == hostID && appModel.client === client && canCreate
            }) { key in
                try await workspace.applySessionAction(action, key: key)
            }
            guard workspace.hostID == hostID else { return }
            if !result.failures.isEmpty {
                let names = Dictionary(targets.map { ($0.key, SessionPresentation.displayTitle(for: $0)) },
                                       uniquingKeysWith: { first, _ in first })
                batchError = String(localized: "mac.sessions.result \(result.succeeded.count) \(targets.count)")
                    + "\n\n" + result.failures.map { "\(names[$0.key] ?? $0.key): \($0.message)" }.joined(separator: "\n")
            }
        }
    }

    // MARK: - Selection and expansion

    private var sidebarSections: [DesktopSidebarProjection.Section] {
        DesktopSidebarProjection.sections(
            sessions: filteredSessions, layout: sidebarLayout, filter: filter, order: &orderBox.order,
            now: feed.listStore.presentationDate, calendar: feed.listStore.presentationCalendar
        )
    }

    private var visibleKeys: Set<String> {
        Set(sidebarSections.filter { expansion(for: $0).wrappedValue }.flatMap(\.items).map { $0.session.key })
    }

    private var selectedSessions: [SessionSummary] { orderedSessions(for: selectedKeys) }

    private func orderedSessions(for keys: Set<String>) -> [SessionSummary] {
        sidebarSections.flatMap(\.items).map(\.session).filter { keys.contains($0.key) }
    }

    private func selectionBinding(for sections: [DesktopSidebarProjection.Section]) -> Binding<Set<String>> {
        let structure = listStructure(sections)
        return Binding(
            get: { selectedKeys },
            set: { keys in
                #if DEBUG
                guard !ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebar") else { return }
                if ProcessInfo.processInfo.arguments.contains("-CorralInspectSearchNavigation") {
                    workspace.navigation.host.inspectionEvents.append("native selection: \(keys.sorted()) focus=\(workspace.focusedKey ?? "nil")")
                }
                #endif
                // A retired native outline can report its previous row index
                // after a structural update. That is reconciliation, not input.
                guard structure == listStructure(sidebarSections) else { return }
                if pendingRevealSerial != nil, keys != Set(workspace.navigation.host.revealKey.map { [$0] } ?? []) { return }
                selectedKeys = keys.intersection(visibleKeys)
                // Native selection owns Command/Shift/range gestures. Extending
                // or reducing a batch never navigates away from the open pane.
                guard selectedKeys.count == 1, let key = selectedKeys.first,
                      NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
                workspace.open(key, sessions: sessions)
            }
        )
    }

    private func toggleSection(_ section: DesktopSidebarProjection.Section) {
        expansion(for: section).wrappedValue.toggle()
    }

    private func expansion(for section: DesktopSidebarProjection.Section) -> Binding<Bool> {
        Binding(
            get: {
                if let filtered = filteredSectionExpansion[section.id] { return filtered }
                if let expanded = sectionExpansion[section.id] { return expanded }
                switch section.kind {
                case .pinned, .bucket(.today): return true
                case .bucket: return false
                }
            },
            set: { expanded in
                if hasActiveScope { filteredSectionExpansion[section.id] = expanded }
                else { sectionExpansion[section.id] = expanded }
            }
        )
    }

    private func title(for section: DesktopSidebarProjection.Section) -> String {
        switch section.kind {
        case .pinned: String(localized: "sessions.section.pinned")
        case .bucket(.today): String(localized: "sessions.section.today")
        case .bucket(.yesterday): String(localized: "sessions.section.yesterday")
        case .bucket(.weekday(let day)): Calendar.current.weekdaySymbols[(day - 1 + 7) % 7]
        case .bucket(.older): String(localized: "sessions.section.earlier")
        }
    }

    private var canCreate: Bool {
        appModel.isConnected(to: feed.host) && !SessionActionsMenu.isReadonly(access: appModel.connectedAccess)
    }

    #if DEBUG
    /// Exercise the mounted native List without posting pointer/key events.
    /// Reuses the restored pane and changes no session/group membership.
    private func inspectPaneSelection() async {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        func mountedOutline() -> NSOutlineView? {
            NSApp.windows.compactMap(\.contentView).flatMap(descendants)
                .compactMap { $0 as? NSOutlineView }.first { $0.window != nil }
        }
        var outline: NSOutlineView?
        for _ in 0..<100 {
            outline = mountedOutline()
            if outline != nil, visibleKeys.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let outline, let key = workspace.focusedKey.flatMap({ visibleKeys.contains($0) ? $0 : nil })
            ?? sessions.first(where: { $0.hosted && visibleKeys.contains($0.key) })?.key else { return }
        let original = selectedKeys
        let originalPanes = workspace.paneKeys, originalFocus = workspace.focusedKey
        // Local restoration avoids any layout write or new assistant launch.
        workspace.restorePanes([key])
        try? await Task.sleep(for: .milliseconds(350))
        func nativeKeys() -> Set<String> {
            var rows: [Int: String] = [:]
            var index = 0
            for section in sidebarSections {
                index += 1
                if expansion(for: section).wrappedValue {
                    for item in section.items { rows[index] = item.session.key; index += 1 }
                }
            }
            return Set((mountedOutline()?.selectedRowIndexes ?? []).compactMap { rows[$0] })
        }
        func settleSelection() async {
            for _ in 0..<50 {
                if selectedKeys == [key], nativeKeys() == [key] { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var availableRows: [(key: String, row: Int)] = []
        var rowIndex = 0
        for section in sidebarSections {
            rowIndex += 1
            if expansion(for: section).wrappedValue {
                for item in section.items { availableRows.append((item.session.key, rowIndex)); rowIndex += 1 }
            }
        }
        let pair = Set([key, availableRows.first(where: { $0.key != key })?.key].compactMap { $0 })
        let rowIndexes = IndexSet(availableRows.filter { pair.contains($0.key) }.map(\.row))
        mountedOutline()?.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        try? await Task.sleep(for: .milliseconds(350))
        var checks = ["nativeBatchPreservesPane": selectedKeys.count >= 2 && workspace.focusedKey == key]
        workspace.focus(key)
        await settleSelection()
        checks["reactivationClearsBatch"] = selectedKeys == [key] && nativeKeys() == [key]
        let batchResult: [String: Any] = ["selected": selectedKeys.sorted(), "native": nativeKeys().sorted(),
                                          "outlineReplaced": mountedOutline() !== outline,
                                          "focused": workspace.focusedKey ?? "", "serial": workspace.paneFocusSerial]
        mountedOutline()?.deselectAll(nil)
        try? await Task.sleep(for: .milliseconds(350))
        checks["nativeClear"] = selectedKeys.isEmpty
        workspace.focus(key)
        await settleSelection()
        checks["reactivationRestoresClearedRow"] = selectedKeys == [key] && nativeKeys() == [key]
        var selectAllAvailable = false
        if let table = mountedOutline() {
            table.window?.makeFirstResponder(table)
            let dispatched = NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: nil)
            try? await Task.sleep(for: .milliseconds(350))
            selectAllAvailable = dispatched && selectedKeys.count >= 2
            if selectAllAvailable {
                workspace.focus(key)
                await settleSelection()
                checks["reactivationAfterSelectAllAction"] = selectedKeys == [key] && nativeKeys() == [key]
            }
        }
        let output = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_PANE_SELECTION_OUTPUT"]
            ?? "/tmp/corral-pane-selection.json"
        let evidence: [String: Any] = ["checks": checks, "selected": selectedKeys.sorted(),
                                      "selectAllActionAvailable": selectAllAvailable,
                                      "batchResult": batchResult,
                                      "nativeSelected": nativeKeys().sorted(),
                                      "physicalInput": "not exercised; native List selection and production workspace focus"]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        selectedKeys = original.intersection(visibleKeys)
        if originalPanes.isEmpty { workspace.closePane(key) }
        else { workspace.restorePanes(originalPanes) }
        workspace.focusedKey = originalFocus
    }

    /// Public native selection, a non-posted context-menu query and native
    /// menu actions only. No input event is posted; host data is untouched.
    private func inspectSessionMultiSelection() async {
        for _ in 0..<80 where visibleKeys.count < 3 { try? await Task.sleep(for: .milliseconds(250)) }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        func hasOutline(_ window: NSWindow) -> Bool {
            window.contentView.map { descendants($0).contains { $0 is NSOutlineView } } == true
        }
        for _ in 0..<80 {
            if NSApp.windows.contains(where: hasOutline) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window = NSApp.windows.first(where: hasOutline), let root = window.contentView,
        let outline = descendants(root).compactMap({ $0 as? NSOutlineView }).first else { return }
        var rows: [(key: String, row: Int)] = []
        var index = 0
        for section in sidebarSections {
            index += 1
            if expansion(for: section).wrappedValue {
                for item in section.items { rows.append((item.session.key, index)); index += 1 }
            }
        }
        for _ in 0..<80 where outline.numberOfRows != index { try? await Task.sleep(for: .milliseconds(250)) }
        guard rows.count >= 3, outline.numberOfRows == index else {
            NSLog("Multi-selection inspection row mismatch: native=%d projected=%d", outline.numberOfRows, index)
            return
        }
        let original = selectedKeys
        let panes = workspace.paneKeys, focus = workspace.focusedKey
        var checks: [String: Bool] = [:]
        outline.selectRowIndexes(IndexSet(rows.prefix(2).map(\.row)), byExtendingSelection: false)
        try? await Task.sleep(for: .milliseconds(350))
        checks["nativeMultipleSelection"] = selectedKeys == Set(rows.prefix(2).map(\.key))
        outline.selectRowIndexes(IndexSet(integer: rows[2].row), byExtendingSelection: true)
        try? await Task.sleep(for: .milliseconds(350))
        checks["nativeAdditiveSelection"] = selectedKeys == Set(rows.prefix(3).map(\.key))
        outline.selectAll(nil)
        try? await Task.sleep(for: .milliseconds(350))
        checks["nativeSelectAllVisible"] = selectedKeys == visibleKeys
        checks["conversationAndPanesPreserved"] = workspace.paneKeys == panes && workspace.focusedKey == focus
        let oldFilter = filter
        filter = "corral-no-matching-session-multiselection-probe"
        for _ in 0..<40 {
            if sidebarSections.isEmpty && selectedKeys.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        checks["filterActuallyChanged"] = sidebarSections.isEmpty
        checks["filterPrunesHiddenTargets"] = selectedKeys.isEmpty
        filter = oldFilter
        try? await Task.sleep(for: .milliseconds(400))
        var menuRows = Array(rows.prefix(2))
        if let unpinned = rows.first(where: { workspace.layout.pinnedSessions[$0.key] == nil }) {
            menuRows.append(unpinned)
        } else {
            menuRows.append(rows[2])
        }
        selectedKeys = Set(menuRows.map(\.key))
        for _ in 0..<40 {
            let current = descendants(root).compactMap { $0 as? NSOutlineView }.first
            if current?.selectedRowIndexes.count == 3 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1))
        let currentOutline = descendants(root).compactMap { $0 as? NSOutlineView }.first ?? outline
        let output = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_MULTISELECT_OUTPUT"]
            ?? "/tmp/corral-multiselect.json"
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        let button = buttons.first { $0.accessibilityIdentifier() == "corral.session.selection-actions" }
            ?? buttons.first { $0.title == String(localized: "mac.sessions.actions") }
            ?? buttons.first { $0.accessibilityLabel() == String(localized: "mac.sessions.actions") }
            ?? buttons.first {
                $0 is NSPopUpButton && $0.convert($0.bounds, to: nil).maxY < 100
            }
        let point = currentOutline.convert(NSPoint(x: 80, y: currentOutline.rect(ofRow: menuRows[1].row).midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 0)
        let contextMenu = event.flatMap { currentOutline.menu(for: $0) }
        let evidence: [String: Any] = ["checks": checks, "selectedCount": selectedKeys.count,
                                      "nativeSelectedCount": currentOutline.selectedRowIndexes.count,
                                      "nativeTables": descendants(root).compactMap { $0 as? NSTableView }.map { $0.numberOfRows },
                                      "filter": filter, "visibleCount": visibleKeys.count,
                                      "menuButtonFound": button != nil,
                                      "contextMenuAvailable": contextMenu != nil,
                                      "buttons": buttons.map {
                                          ["title": $0.title, "id": $0.accessibilityIdentifier(),
                                           "label": $0.accessibilityLabel() ?? "",
                                           "class": String(describing: type(of: $0)),
                                           "frame": NSStringFromRect($0.convert($0.bounds, to: nil))]
                                      },
                                      "physicalInput": "not exercised; public selection APIs, non-posted menu query and native menu actions"]
        let recorder = MacSessionMenuInspection(output: URL(fileURLWithPath: output)) { evidence }
        defer { recorder.stop() }
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output + ".selection"), options: .atomic)
        }
        if let contextMenu {
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 120, y: currentOutline.rect(ofRow: menuRows[1].row).midY),
                              in: currentOutline)
        } else if let button, let action = button.action {
            NSApp.sendAction(action, to: button.target, from: button)
        } else if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        try? await Task.sleep(for: .seconds(15))
        selectedKeys = original.intersection(visibleKeys)
    }

    /// Exercise production header actions with a project scope; never drive input.
    private func inspectDateDisclosures() async {
        for _ in 0..<40 where sessions.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        let paths = Dictionary(grouping: sessions, by: SessionListFiltering.directoryIdentity)
        guard let path = paths.filter({ !$0.key.isEmpty }).max(by: { $0.value.count < $1.value.count })?.key else { return }
        let previous = projectFilter
        defer { projectFilter = previous }
        projectFilter = [.project(path: path)]
        try? await Task.sleep(for: .milliseconds(500))
        let sections = DesktopSidebarProjection.sections(
            sessions: filteredSessions, layout: sidebarLayout, filter: filter, order: &orderBox.order
        )
        func inventory() -> [NSObject] {
            guard let root = NSApp.windows.first(where: { $0.title == "Corral" })?.contentView else { return [] }
            var seen = Set<ObjectIdentifier>()
            func walk(_ object: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
                let children = ((object as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
                return [object] + children.flatMap(walk) + ((object as? NSView)?.subviews.flatMap(walk) ?? [])
            }
            return walk(root)
        }
        func rowCount() -> Int { inventory().compactMap { $0 as? NSOutlineView }.first?.numberOfRows ?? -1 }
        var outcomes: [[String: Any]] = []
        for section in sections {
            let before = expansion(for: section).wrappedValue
            let beforeRows = rowCount()
            toggleSection(section)
            try? await Task.sleep(for: .milliseconds(300))
            let collapsed = !expansion(for: section).wrappedValue
            let afterRows = rowCount()
            toggleSection(section)
            try? await Task.sleep(for: .milliseconds(300))
            outcomes.append(["section": section.id, "initialExpanded": before,
                             "collapsed": collapsed,
                             "expanded": expansion(for: section).wrappedValue,
                             "rowsBefore": beforeRows, "rowsCollapsed": afterRows, "rowsExpanded": rowCount()])
        }
        let evidence: [String: Any] = ["projectScoped": hasActiveScope, "matchedSessions": filteredSessions.count,
                                      "ordinaryOverridesUnchanged": sectionExpansion.isEmpty, "outcomes": outcomes,
                                      "actionRoute": "same production title-button callback; physical/AX click not exercised"]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-date-disclosures.json"), options: .atomic)
        }
    }

    /// Read mounted native row geometry; no pointer, key or host-data actions.
    private func recordSidebarGeometry() {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        guard let window = NSApp.windows.first(where: { $0.title == "Corral" }),
              let root = window.contentView,
              let outline = descendants(root).compactMap({ $0 as? NSOutlineView }).first else { return }
        if ProcessInfo.processInfo.arguments.contains("-CorralInspectAllSpaces") {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.orderBack(nil)
        }
        let rows: [[String: Any]] = (0..<min(outline.numberOfRows, 30)).map { row in
            ["row": row, "height": outline.rect(ofRow: row).height,
             "y": outline.rect(ofRow: row).minY,
             "level": outline.level(forRow: row)]
        }
        let projected = DesktopSidebarProjection.sections(
            sessions: filteredSessions, layout: sidebarLayout, filter: filter, order: &orderBox.order,
            now: feed.listStore.presentationDate, calendar: feed.listStore.presentationCalendar
        ).flatMap(\.items)
        let evidence: [String: Any] = ["rows": rows, "runtimeCount": runtimeFilter.count,
                                       "projectCount": projectFilter.count,
                                       "matchedSessions": filteredSessions.count,
                                       "projectedRows": projected.count,
                                       "splitMemberRows": projected.filter { $0.split != nil }.count,
                                       "uniqueSessionRows": Set(projected.map(\.id)).count,
                                       "layoutRevision": workspace.layout.revision]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-sidebar-geometry.json"), options: .atomic)
        }
        // Export the app's own content for spacing review when desktop capture
        // is unavailable. This does not include WindowServer compositing.
        if !sessions.isEmpty,
           let path = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SIDEBAR_OUTPUT"],
           !FileManager.default.fileExists(atPath: path),
           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.layoutSubtreeIfNeeded()
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                root.cacheDisplay(in: root.bounds, to: bitmap)
            }
            if let data = bitmap.representation(using: .png, properties: [:]) {
                do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
                catch { NSLog("Sidebar inspection export failed: %@", error.localizedDescription) }
            }
        }
    }
    #endif
}

/// Paired-machine switcher at the bottom of the sidebar: current machine over
/// its live connection route, every other paired machine and pairing.
struct MachineSwitcher: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(\.openSettings) private var openSettings
    var onPair: () -> Void

    var body: some View {
        Menu {
            ForEach(appModel.hosts) { host in
                Button {
                    Task { await appModel.connect(to: host) }
                } label: {
                    if host.hostID == appModel.selectedHost?.hostID {
                        Label(host.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: host.displayName)
                    }
                }
            }
            Divider()
            Button("mac.pair_machine", action: onPair)
            Button("mac.machine_settings") { openSettings() }
        } label: {
            HStack(spacing: Space.sm * interfaceScale) {
                MachineIconTile(size: 26)
                VStack(alignment: .leading, spacing: 1 * interfaceScale) {
                    Text(verbatim: appModel.selectedHost?.displayName ?? "")
                        .interfaceFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    ConnectionBanner(state: appModel.connectionState, transport: appModel.activeTransport)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(Text("mac.machine_switcher"))
        .accessibilityLabel(Text("mac.machine_switcher"))
    }
}
