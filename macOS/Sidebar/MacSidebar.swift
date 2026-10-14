import AppKit
import SwiftUI

/// Session sidebar in the TUI's structure: quick filters (Active, runtime,
/// project), pinned block, local-calendar day buckets, split groups shared
/// with the TUI, and a local filter (title, project). Full-text body search is ⌘F.
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
    @State private var sessionToDelete: SessionSummary?
    #if DEBUG
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
        content
            .modifier(MacZoomContent())
            .task {
                #if DEBUG
                await MacScrollbarInspection.runIfRequested()
                if ProcessInfo.processInfo.arguments.contains("-CorralInspectDateDisclosures") {
                    await inspectDateDisclosures()
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
                            "selected": selectionBinding.wrappedValue ?? "none",
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
            .onChange(of: filter) { _, _ in filteredSectionExpansion.removeAll() }
            .onChange(of: activeOnly) { _, _ in filteredSectionExpansion.removeAll() }
            .onChange(of: runtimeFilter) { _, _ in filteredSectionExpansion.removeAll() }
            .onChange(of: projectFilter) { _, _ in filteredSectionExpansion.removeAll() }
            .onChange(of: feed.host.id) { _, _ in
                filter = ""
                activeOnly = false
                runtimeFilter.removeAll()
                projectFilter.removeAll()
                sectionExpansion.removeAll()
                filteredSectionExpansion.removeAll()
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
                    .interfacePadding(.vertical, Space.xs / 2)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                HStack(spacing: Space.sm * interfaceScale) {
                    MachineSwitcher(onPair: onPair)
                    Spacer(minLength: 0)
                }
                .modifier(MacZoomContent())
                .interfacePadding(.horizontal, Space.md)
                .interfacePadding(.vertical, Space.sm)
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
            .confirmationDialog(
                "sessions.delete_confirm.title",
                isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("sessions.action.delete", role: .destructive) {
                    if let session = sessionToDelete {
                        Task {
                            do {
                                try await feed.delete(session)
                                workspace.closePane(session.key)
                            } catch {
                                // The shared feed keeps the row and presents the host error.
                            }
                        }
                    }
                    sessionToDelete = nil
                }
                Button("action.cancel", role: .cancel) { sessionToDelete = nil }
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
        let sections = DesktopSidebarProjection.sections(
            sessions: filteredSessions, layout: sidebarLayout, filter: filter, order: &orderBox.order
        )
        return List(selection: selectionBinding) {
            ForEach(sections) { section in
                Section {
                    if expansion(for: section).wrappedValue {
                        ForEach(section.items) { item in
                            itemView(item)
                        }
                    }
                } header: {
                    DisclosureGroup(isExpanded: expansion(for: section)) {
                        EmptyView()
                    } label: {
                        Button {
                            toggleSection(section)
                        } label: {
                            Text(verbatim: title(for: section))
                                .interfaceFont(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .interfaceFrame(height: MacSidebarMetrics.sectionHeight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("corral.date-section.\(section.id)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, MacSidebarMetrics.compactRowHeight * interfaceScale)
        .environment(\.defaultMinListHeaderHeight, MacSidebarMetrics.sectionHeight * interfaceScale)
        // Keep scrolling rows legible beneath the native search and machine bars.
        .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
        #if DEBUG
        .focused($inspectionFocused)
        #endif
        // Retire old native cell hosts when rows move across the outline.
        // Streaming metadata must keep the existing list lifetime.
        .id(listStructure(sections))
        .focusEffectDisabled()
    }

    /// Titles, previews, timestamps and attention update in place. Selection
    /// and disclosure state are owned outside the native list lifetime.
    private enum StructureEntry: Hashable {
        case section(String)
        case session(String)
        case group(String, members: [String], expanded: Bool)
    }

    private func listStructure(_ sections: [DesktopSidebarProjection.Section]) -> [StructureEntry] {
        var entries: [StructureEntry] = []
        for section in sections {
            entries.append(.section(section.id))
            for item in section.items {
                switch item {
                case .session(let session): entries.append(.session(session.key))
                case .group(let group, let members):
                    entries.append(.group(group.id, members: members.map(\.key),
                                          expanded: !group.collapsed))
                }
            }
        }
        return entries
    }

    // MARK: - Rows

    @ViewBuilder
    private func itemView(_ item: DesktopSidebarProjection.Item) -> some View {
        switch item {
        case .session(let session):
            sessionRow(session)
        case .group(let group, let members):
            DisclosureGroup(isExpanded: groupExpansion(group)) {
                // The rail joins the members; only the last one closes the split.
                ForEach(members) { member in
                    sessionRow(
                        member,
                        groupProject: SessionPresentation.projectName(cwd: Self.splitProject(group, members: members)),
                        closesSplit: member.id == members.last?.id
                    )
                }
            } label: {
                Button {
                    groupExpansion(group).wrappedValue.toggle()
                } label: {
                    groupLabel(group, members: members)
                        .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .background(NativeSidebarSelection())
                    .contextMenu { groupMenu(group) }
            }
            // An expanded header attaches to its members; collapsed, it closes itself.
            .listRowSeparator(group.collapsed ? .visible : .hidden, edges: .bottom)
            .listRowSeparatorTint(Color(nsColor: .separatorColor).opacity(0.5), edges: .bottom)
            .listRowInsets(.vertical, 0)
        }
    }

    /// `groupProject` marks a split member; inside a split only the last
    /// member (`closesSplit`) draws the separator.
    private func sessionRow(
        _ session: SessionSummary, groupProject: String? = nil, closesSplit: Bool = true
    ) -> some View {
        MacSessionRow(session: session, groupProject: groupProject)
            .listRowInsets(.vertical, 0)
            .listRowSeparator(closesSplit ? .visible : .hidden, edges: .bottom)
            .listRowSeparatorTint(Color(nsColor: .separatorColor).opacity(0.5), edges: .bottom)
            .background(NativeSidebarSelection())
            // Reclaim part of the native outline's disclosure gutter on leaves.
            // Group headers keep their own disclosure space and hit target.
            .listRowInsets(.leading, -Space.sm)
            .tag(SidebarTag.session(session.key))
            .onAppear { feed.listStore.rememberOpened(session) }
            .contextMenu { sessionMenu(session) }
    }

    /// The project names the split (design: Collapsed split and project
    /// prominence, owner request 2026-10-11). Collapsed, the split stands in
    /// for its members at the equal two-line session height: project title,
    /// combined status and newest time, then member glyphs and "Split view ·
    /// N sessions". Expanded, one compact line heads the members. Splits are
    /// never named and never repeat member titles.
    @ViewBuilder
    private func groupLabel(_ group: DesktopGroup, members: [SessionSummary]) -> some View {
        let path = Self.splitProject(group, members: members)
        let project = SessionPresentation.projectName(cwd: path)
        Group {
            if group.collapsed {
                collapsedGroupLabel(group, members: members, project: project)
            } else {
                expandedGroupLabel(group, members: members, project: project)
            }
        }
        .lineLimit(1)
        .help(Text(verbatim: ([path] + members.map { SessionPresentation.displayTitle(for: $0) })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")))
    }

    private func collapsedGroupLabel(
        _ group: DesktopGroup, members: [SessionSummary], project: String
    ) -> some View {
        HStack(alignment: .top, spacing: Space.xs * interfaceScale) {
            splitSymbol(paneCount: members.count)
                .interfaceFrame(height: MacSidebarMetrics.titleLineHeight, alignment: .center)
            VStack(alignment: .leading, spacing: MacSidebarMetrics.lineSpacing * interfaceScale) {
                HStack(spacing: Space.xs * interfaceScale) {
                    groupTitle(group, project: project)
                    Spacer(minLength: Space.xs * interfaceScale)
                    attentionSummary(DesktopSidebarProjection.attentionSummary(members))
                        .fixedSize()
                    if let newest = members.max(by: { $0.mtime < $1.mtime }) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(verbatim: MacSidebarMetrics.compactTime(for: newest, now: context.date))
                                .interfaceFont(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
                .interfaceFrame(height: MacSidebarMetrics.titleLineHeight)
                HStack(spacing: Space.xs * interfaceScale) {
                    HStack(spacing: 2 * interfaceScale) {
                        ForEach(members) { member in
                            RuntimeGlyph(runtimeID: member.runtime, size: MacSidebarMetrics.glyph(.small))
                        }
                    }
                    .accessibilityHidden(true)
                    Text(project.isEmpty ? "mac.group.members \(members.count)"
                         : "mac.group.split_members \(members.count)")
                        .interfaceFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                }
            }
        }
        .interfacePadding(.vertical, MacSidebarMetrics.rowPadding)
        .interfaceFrame(height: MacSidebarMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }

    private func expandedGroupLabel(
        _ group: DesktopGroup, members: [SessionSummary], project: String
    ) -> some View {
        HStack(spacing: Space.xs * interfaceScale) {
            splitSymbol(paneCount: members.count)
            groupTitle(group, project: project)
            if !project.isEmpty {
                Text("mac.group.split")
                    .interfaceFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: Space.xs * interfaceScale)
            Text(verbatim: members.count.formatted())
                .interfaceFont(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("mac.group.members \(members.count)"))
                .fixedSize()
        }
        .interfacePadding(.vertical, MacSidebarMetrics.rowPadding)
        .interfaceFrame(height: MacSidebarMetrics.compactRowHeight)
    }

    /// Pin mark and the project as the split's title; "Split view" without one.
    private func groupTitle(_ group: DesktopGroup, project: String) -> some View {
        HStack(spacing: Space.xs * interfaceScale) {
            if group.pinned {
                Image(systemName: "pin.fill")
                    .interfaceFont(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("sessions.section.pinned"))
            }
            Group {
                if project.isEmpty {
                    Text("mac.group.split")
                } else {
                    Text(verbatim: project)
                }
            }
            .interfaceFont(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .truncationMode(.tail)
        }
    }

    private func splitSymbol(paneCount: Int) -> some View {
        Image(systemName: Self.splitSymbol(paneCount: paneCount))
            .resizable()
            .scaledToFit()
            .foregroundStyle(Palette.accent)
            .interfaceFrame(width: MacSidebarMetrics.glyph(rowSize), height: MacSidebarMetrics.glyph(rowSize))
            .accessibilityHidden(true)
    }

    /// The split's project; older layouts without one use the first member's.
    static func splitProject(_ group: DesktopGroup, members: [SessionSummary]) -> String {
        group.project.isEmpty ? (members.first?.cwd ?? "") : group.project
    }

    /// The system split symbol matching the pane count (4 uses the square grid).
    static func splitSymbol(paneCount: Int) -> String {
        switch paneCount {
        case ...2: return "rectangle.split.2x1"
        case 3: return "rectangle.split.3x1"
        default: return "square.split.2x2"
        }
    }

    private func attentionSummary(_ summary: [(SessionPresentation.StatusMarker, Int)]) -> some View {
        HStack(spacing: Space.sm * interfaceScale) {
            ForEach(summary, id: \.0) { marker, count in
                HStack(spacing: 3 * interfaceScale) {
                    Circle()
                        .fill(MacSidebarMetrics.color(for: marker))
                        .interfaceFrame(width: 7, height: 7)
                    Text(verbatim: count.formatted())
                        .interfaceFont(.subheadline.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(MacSidebarMetrics.label(for: marker)))
                .accessibilityValue(Text(verbatim: count.formatted()))
            }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func sessionMenu(_ session: SessionSummary) -> some View {
        Button {
            workspace.addPane(session.key, project: session.cwd)
        } label: {
            Label("mac.session.open_in_split", systemImage: "rectangle.split.2x1")
        }
        .disabled(workspace.paneKeys.isEmpty || !workspace.canAddSessionToSplit(session))
        Button {
            Task { await workspace.togglePin(session.key) }
        } label: {
            Label("mac.session.pin_toggle", systemImage: "pin")
        }
        Button {
            PlatformPasteboard.copy(SessionPresentation.fullWorkspacePath(from: session))
        } label: {
            Label("session.workspace.copy_path", systemImage: "doc.on.doc")
        }
        Divider()
        if session.live {
            Button {
                Task { await workspace.stop(session.key) }
            } label: {
                Label("sessions.action.stop", systemImage: "stop.fill")
            }
        }
        Button(role: .destructive) {
            sessionToDelete = session
        } label: {
            Label("sessions.action.delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: DesktopGroup) -> some View {
        Button {
            workspace.openGroup(group, sessions: sessions)
        } label: {
            Label("mac.group.open", systemImage: "rectangle.split.3x1")
        }
        Button {
            Task { await workspace.toggleGroupPin(group) }
        } label: {
            Label(group.pinned ? "sessions.action.unpin" : "sessions.action.pin", systemImage: group.pinned ? "pin.slash" : "pin")
        }
    }

    // MARK: - Selection and expansion

    private enum SidebarTag {
        static func session(_ key: String) -> String { "session:\(key)" }
        static func group(_ id: String) -> String { "group:\(id)" }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { workspace.focusedKey.map(SidebarTag.session) },
            set: { tag in
                #if DEBUG
                guard !ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebar") else { return }
                #endif
                guard let tag else { return }
                if tag.hasPrefix("session:") {
                    workspace.open(String(tag.dropFirst("session:".count)), sessions: sessions)
                } else if tag.hasPrefix("group:") {
                    let id = String(tag.dropFirst("group:".count))
                    if let group = workspace.layout.groups.first(where: { $0.id == id }) {
                        groupExpansion(group).wrappedValue.toggle()
                    }
                }
            }
        )
    }

    private func toggleSection(_ section: DesktopSidebarProjection.Section) {
        expansion(for: section).wrappedValue.toggle()
    }

    private func expansion(for section: DesktopSidebarProjection.Section) -> Binding<Bool> {
        Binding(
            get: {
                if hasActiveScope { return filteredSectionExpansion[section.id] ?? true }
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

    private func groupExpansion(_ group: DesktopGroup) -> Binding<Bool> {
        Binding(
            get: { !group.collapsed },
            set: { expanded in Task { await workspace.setCollapsed(group, collapsed: !expanded) } }
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
        let evidence: [String: Any] = ["rows": rows, "runtimeCount": runtimeFilter.count,
                                       "projectCount": projectFilter.count,
                                       "matchedSessions": filteredSessions.count]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-sidebar-geometry.json"), options: .atomic)
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
                        .interfaceFont(.callout.weight(.semibold))
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
