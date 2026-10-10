import AppKit
import SwiftUI

/// Session sidebar in the TUI's structure: Active sessions entry, pinned
/// block, local-calendar day buckets, split groups shared with the TUI, and
/// a local filter (title, project, user-given split name). Full-text body search is ⌘F.
struct MacSidebar: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    let feed: HostSessionFeed
    var onNewSession: () -> Void
    var onPair: () -> Void

    @State private var filter = ""
    @State private var olderExpanded = false
    @State private var orderBox = OrderBox()
    @State private var sessionToDelete: SessionSummary?
    @State private var groupToRename: DesktopGroup?
    @State private var renameText = ""
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

    var body: some View {
        content
            .modifier(MacZoomContent())
            .task {
                #if DEBUG
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
                if ProcessInfo.processInfo.arguments.contains("-CorralInspectSplitRename") {
                    // Presents the rename alert for the first split; nothing is
                    // sent unless Save is pressed.
                    for _ in 0..<20 where groupToRename == nil {
                        try? await Task.sleep(for: .seconds(1))
                        if let group = workspace.layout.groups.first {
                            renameText = group.named ? group.name : ""
                            groupToRename = group
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
                            try? await feed.delete(session)
                            workspace.closePane(session.key)
                        }
                    }
                    sessionToDelete = nil
                }
                Button("action.cancel", role: .cancel) { sessionToDelete = nil }
            }
            .alert(
                "mac.group.rename.title",
                isPresented: Binding(get: { groupToRename != nil }, set: { if !$0 { groupToRename = nil } }),
                presenting: groupToRename
            ) { group in
                TextField("mac.group.rename.title", text: $renameText)
                Button("mac.group.rename.save") {
                    let name = renameText
                    Task { await workspace.renameGroup(group, to: name) }
                    groupToRename = nil
                }
                .keyboardShortcut(.defaultAction)
                Button("action.cancel", role: .cancel) { groupToRename = nil }
            } message: { _ in
                Text("mac.group.rename.message")
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
            sessions: sessions, layout: sidebarLayout, filter: filter, order: &orderBox.order
        )
        let active = DesktopSidebarProjection.activeSessions(sessions)
        return List(selection: selectionBinding) {
            if filter.isEmpty {
                activeRow(active).tag(SidebarTag.board)
            }
            ForEach(sections) { section in
                Section(isExpanded: expansion(for: section)) {
                    ForEach(section.items) { item in
                        itemView(item)
                    }
                } header: {
                    Text(verbatim: title(for: section))
                }
            }
        }
        .listStyle(.sidebar)
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
        case board
        case section(String)
        case session(String)
        case group(String, members: [String], expanded: Bool)
    }

    private func listStructure(_ sections: [DesktopSidebarProjection.Section]) -> [StructureEntry] {
        var entries: [StructureEntry] = filter.isEmpty ? [.board] : []
        for section in sections {
            entries.append(.section(section.id))
            for item in section.items {
                switch item {
                case .session(let session): entries.append(.session(session.key))
                case .group(let group, let members):
                    entries.append(.group(group.id, members: members.map(\.key),
                                          expanded: !group.collapsed || !filter.isEmpty))
                }
            }
        }
        return entries
    }

    // MARK: - Rows

    private func activeRow(_ active: [SessionSummary]) -> some View {
        Label {
            HStack(spacing: Space.xs * interfaceScale) {
                Text("mac.board.show")
                    .interfaceFont(.body)
                Spacer(minLength: 0)
                if active.contains(where: { SessionPresentation.statusMarker(for: $0) == .waiting }) {
                    Circle()
                        .fill(Palette.attentionWaiting)
                        .interfaceFrame(width: 7, height: 7)
                        .accessibilityLabel(Text("sessions.attention.waiting"))
                }
            }
        } icon: {
            Image(systemName: "rectangle.split.2x2")
                .foregroundStyle(Palette.accent)
        }
        .badge(active.count)
        .background(NativeSidebarSelection())
    }

    @ViewBuilder
    private func itemView(_ item: DesktopSidebarProjection.Item) -> some View {
        switch item {
        case .session(let session):
            sessionRow(session)
        case .group(let group, let members):
            DisclosureGroup(isExpanded: groupExpansion(group)) {
                ForEach(members) { member in
                    sessionRow(member, groupProject: SessionPresentation.projectName(cwd: group.project))
                }
            } label: {
                groupLabel(group, members: members)
                    .background(NativeSidebarSelection())
                    .tag(SidebarTag.group(group.id))
                    .contextMenu { groupMenu(group) }
            }
        }
    }

    private func sessionRow(_ session: SessionSummary, groupProject: String? = nil) -> some View {
        MacSessionRow(session: session, groupProject: groupProject)
            .background(NativeSidebarSelection())
            // Reclaim part of the native outline's disclosure gutter on leaves.
            // Group headers keep their own disclosure space and hit target.
            .listRowInsets(.leading, -Space.sm)
            .tag(SidebarTag.session(session.key))
            .onAppear { feed.listStore.rememberOpened(session) }
            .contextMenu { sessionMenu(session) }
    }

    /// One line: pin, split symbol, display name, project; trailing member
    /// count, or the attention dots with counts while collapsed.
    private func groupLabel(_ group: DesktopGroup, members: [SessionSummary]) -> some View {
        HStack(spacing: Space.xs * interfaceScale) {
            if group.pinned {
                Image(systemName: "pin.fill")
                    .interfaceFont(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("sessions.section.pinned"))
            }
            Image(systemName: Self.splitSymbol(paneCount: members.count))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("mac.group.split"))
            Text(verbatim: DesktopSidebarProjection.displayName(group, members: members))
                .interfaceFont(.body)
                .truncationMode(.tail)
                .layoutPriority(1)
            // The joined name can be long: it truncates, project and count never do.
            Text(verbatim: SessionPresentation.projectName(cwd: group.project))
                .interfaceFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: Space.xs * interfaceScale)
            groupTrailing(group, members: members)
                .fixedSize()
        }
        .lineLimit(1)
        .interfacePadding(.vertical, MacSidebarMetrics.rowPadding)
        .help(Text(verbatim: group.project))
    }

    /// The system split symbol matching the pane count (4 uses the square
    /// grid so it never reads as the Active sessions entry).
    static func splitSymbol(paneCount: Int) -> String {
        switch paneCount {
        case ...2: return "rectangle.split.2x1"
        case 3: return "rectangle.split.3x1"
        default: return "square.split.2x2"
        }
    }

    @ViewBuilder
    private func groupTrailing(_ group: DesktopGroup, members: [SessionSummary]) -> some View {
        let summary = group.collapsed ? DesktopSidebarProjection.attentionSummary(members) : []
        if summary.isEmpty {
            Text(verbatim: members.count.formatted())
                .interfaceFont(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("mac.group.members \(members.count)"))
        } else {
            HStack(spacing: Space.sm * interfaceScale) {
                ForEach(summary, id: \.0) { marker, count in
                    HStack(spacing: 3 * interfaceScale) {
                        Circle()
                            .fill(MacSidebarMetrics.color(for: marker))
                            .interfaceFrame(width: 6, height: 6)
                        Text(verbatim: count.formatted())
                            .interfaceFont(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(MacSidebarMetrics.label(for: marker)))
                    .accessibilityValue(Text(verbatim: count.formatted()))
                }
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
        .disabled(workspace.paneKeys.isEmpty)
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
        Button {
            renameText = group.named ? group.name : ""
            groupToRename = group
        } label: {
            Label("mac.group.rename", systemImage: "pencil")
        }
    }

    // MARK: - Selection and expansion

    private enum SidebarTag {
        static let board = "board"
        static func session(_ key: String) -> String { "session:\(key)" }
        static func group(_ id: String) -> String { "group:\(id)" }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                if workspace.showingBoard { return SidebarTag.board }
                return workspace.focusedKey.map(SidebarTag.session)
            },
            set: { tag in
                #if DEBUG
                guard !ProcessInfo.processInfo.arguments.contains("-CorralInspectSidebar") else { return }
                #endif
                guard let tag else { return }
                if tag == SidebarTag.board {
                    workspace.showBoard()
                } else if tag.hasPrefix("session:") {
                    workspace.open(String(tag.dropFirst("session:".count)), sessions: sessions)
                } else if tag.hasPrefix("group:") {
                    let id = String(tag.dropFirst("group:".count))
                    if let group = workspace.layout.groups.first(where: { $0.id == id }) {
                        workspace.openGroup(group, sessions: sessions)
                    }
                }
            }
        )
    }

    private func expansion(for section: DesktopSidebarProjection.Section) -> Binding<Bool> {
        guard case .bucket(.older) = section.kind else { return .constant(true) }
        return Binding(get: { olderExpanded || !filter.isEmpty }, set: { olderExpanded = $0 })
    }

    private func groupExpansion(_ group: DesktopGroup) -> Binding<Bool> {
        Binding(
            get: { !group.collapsed || !filter.isEmpty },
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
