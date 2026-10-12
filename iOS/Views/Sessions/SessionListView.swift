#if os(iOS)
import SwiftUI

/// 会话路由：列表详情跳转与详情页内复制/接力成功后的新会话跳转共用。
/// 从 SessionListView 私有提升到共享，保证详情页 push 新会话时与现有
/// value/item/inspected 三条 navigationDestination 行为一致。
struct SessionRoute: Hashable, Identifiable {
    let key: String
    var id: String { key }
}

struct SessionListView: View {
    static let listRecheckInterval = HostSessionFeed.listRecheckInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var appModel

    let host: HostInfo
    /// Shared live list plumbing (also drives the Mac sidebar).
    @State private var feed: HostSessionFeed
    private var listStore: SessionListStore { feed.listStore }
    private var isLoading: Bool { feed.isLoading }
    private var loadError: String? { feed.loadError }

    init(host: HostInfo) {
        self.host = host
        _feed = State(initialValue: HostSessionFeed(host: host))
    }
    @State private var showNewSession = false
    @State private var pendingCreatedSessionKey: String?
    @State private var openedSessionRoute: SessionRoute?
    /// Notification-tap session leg, pushed once this host's snapshot holds the key.
    @State private var notificationSessionRoute: SessionRoute?
    @State private var sessionToDelete: SessionSummary?
    @State private var hapticScope = HapticScope()
    /// True while this list is the visible navigation content. Pending taps are
    /// consumed only here, never by an offscreen or stale same-host instance.
    @State private var isActiveList = false
    /// Notification tap still waiting for its session to appear in this host's
    /// snapshot. The ticket stays unconsumed while set; every new snapshot retries.
    @State private var pendingWaitKey: String?
    /// In-flight direct `session.get` ticket. Guards one lookup per ticket; a newer
    /// tap supersedes it and its late result is dropped, never consumed or pushed.
    @State private var lookupTicket: UInt64?
    /// Last direct-lookup transient failure for the pending tap. Rendered with a
    /// Retry action over empty and non-empty lists; cleared on push, on lookup
    /// start, or when the pending tap goes away. The ticket is never consumed.
    @State private var pendingLookupError: String?
    /// Direct lookup answered explicit `not_found` for the tapped session. Visible
    /// recovery, dismissible; never a silent empty screen. List windows can never
    /// set this — only the `session.get` lookup may.
    @State private var missingNotificationKey: String?
    @State private var inspectedSessionRoute: SessionRoute?
    /// Date disclosures survive navigation and updates for this host page.
    @State private var sectionExpansion: [String: Bool] = [:]
    /// Quick-filter selections. They live in this view (one instance per host
    /// in the navigation stack, so state is host-scoped) and survive pushing
    /// a conversation and returning. Live updates, refreshes, and reconnects
    /// never reset them; only leaving this host's page discards them.
    @State private var activeOnly = false
    @State private var runtimeFilter: Set<SessionRuntimeFilter> = []
    @State private var projectFilter: Set<SessionProjectFilter> = []
    @State private var showProjectPicker = false
    /// Stable per-host quick-choice snapshot. Reconciled (never re-sorted)
    /// from the unfiltered host window, so live updates keep positions.
    @State private var projectChoices: [SessionProjectOption] = []
    @State private var isSearchPresented = false

    var body: some View {
        VStack(spacing: 0) {
            SessionRuntimeFilterRow(
                activeOnly: $activeOnly,
                activeCount: SessionListFiltering.activeCount(sessions: windowSessions),
                selected: $runtimeFilter
            )
                .padding(.top, Space.xs)
            SessionProjectFilterRow(
                selected: $projectFilter,
                choices: projectChoices,
                selectedOutside: selectedOutsideRecents,
                onMore: { showProjectPicker = true }
            )
            .padding(.bottom, Space.xs)
            Divider()
            Group {
                switch SessionListPlaceholderPolicy.resolve(
                sectionsEmpty: visibleSections.isEmpty,
                isLoading: isLoading,
                connected: appModel.isConnected(to: host),
                pendingTapWaiting: pendingWaitKey != nil,
                tapMissing: missingNotificationKey != nil,
                tapError: pendingLookupError != nil,
                loadFailed: loadError != nil
            ) {
            case .content:
                List {
                    if let loadError, shouldShowLoadErrorBanner(loadError) {
                        Section {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                    if missingNotificationKey != nil {
                        Section {
                            HStack {
                                Label("sessions.notification_missing.title", systemImage: "bell.slash")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                                Spacer()
                                Button("action.dismiss") { missingNotificationKey = nil }
                                    .font(.footnote)
                            }
                        }
                    }
                    if pendingLookupError != nil, pendingWaitKey != nil {
                        Section {
                            HStack {
                                Label(pendingTapErrorText, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                                Spacer()
                                Button("action.retry") {
                                    Task { await retryPendingConnection() }
                                }
                                .font(.footnote)
                            }
                        }
                    }
                    ForEach(visibleSections) { section in
                        let expanded = isSectionExpanded(section)
                        Section {
                            if expanded {
                                ForEach(section.sessions) { session in
                                    NavigationLink(value: SessionRoute(key: session.key)) {
                                        SessionRowView(session: session)
                                    }
                                    .listRowSeparator(.visible, edges: .bottom)
                                    .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                        dimensions[.leading] + SessionListLayout.separatorLeading
                                    }
                                    .listRowInsets(SessionListLayout.rowInsets)
                                    .onAppear { listStore.rememberOpened(session) }
                                    .swipeActions(edge: .leading) {
                                        let isPinned = session.pinned == true
                                            || session.group?.pinned == true
                                        Button {
                                            Task { await togglePin(session) }
                                        } label: {
                                            Label(
                                                isPinned ? "sessions.action.unpin" : "sessions.action.pin",
                                                systemImage: isPinned ? "pin.slash" : "pin"
                                            )
                                        }
                                        .tint(Palette.accent)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            sessionToDelete = session
                                        } label: {
                                            Label("sessions.action.delete", systemImage: "trash")
                                        }
                                        Button {
                                            Task { await stopSession(session) }
                                        } label: {
                                            Label("sessions.action.stop", systemImage: "stop.fill")
                                        }
                                        .tint(.gray)
                                    }
                                }
                            }
                        } header: {
                            sectionHeader(section)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .contentMargins(.top, Space.sm, for: .scrollContent)
                .contentMargins(.bottom, Self.searchBarClearance, for: .scrollContent)
                .listSectionSpacing(.compact)
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await refreshSessions(showLoading: false)
                }
            case .loading:
                ProgressView()
            case .loadFailed:
                ContentUnavailableView {
                    Label("sessions.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError ?? "")
                } actions: {
                    Button("action.retry") {
                        Task { await refreshSessions(showLoading: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }
            case .tapError:
                ContentUnavailableView {
                    Label(pendingTapErrorText, systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("action.retry") {
                        Task { await retryPendingConnection() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }
            case .tapMissing:
                ContentUnavailableView {
                    Label("sessions.notification_missing.title", systemImage: "bell.slash")
                } actions: {
                    Button("action.dismiss") { missingNotificationKey = nil }
                }
            case .empty:
                if hasActiveScope {
                    ContentUnavailableView {
                        Label("sessions.filter.empty.title", systemImage: "magnifyingglass")
                    } description: {
                        Text(filterScopeDescription)
                    } actions: {
                        Button("sessions.filter.clear") {
                            clearFilters()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                    }
                } else {
                    ContentUnavailableView(
                        "sessions.empty.title",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: SessionRoute.self) { route in
            sessionDetail(for: route, autoFocusComposer: false)
        }
        .navigationDestination(item: $openedSessionRoute) { route in
            sessionDetail(for: route, autoFocusComposer: true)
        }
        .navigationDestination(item: $notificationSessionRoute) { route in
            sessionDetail(for: route, autoFocusComposer: false)
        }
        .navigationDestination(item: $inspectedSessionRoute) { route in
            sessionDetail(
                for: route,
                autoFocusComposer: ProcessInfo.processInfo.arguments.contains("-CorralInspectKeyboard")
            )
        }
        .searchable(
            text: Bindable(listStore).searchQuery,
            isPresented: $isSearchPresented,
            prompt: Text("sessions.search")
        )
        .modifier(SessionListSystemSearchPlacement())
        .onChange(of: listStore.searchQuery) { _, query in
            scheduleRemoteSearch(query)
        }
        .onChange(of: listStore.windowSessions, initial: true) { _, window in
            // Reconcile, never re-sort: existing choices keep their positions
            // while labels refresh and genuinely new identities append.
            projectChoices = SessionListFiltering.reconcileChoices(
                current: projectChoices,
                sessions: window
            )
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                SessionPrincipalHeader(
                    deviceName: host.displayName,
                    state: appModel.connectionState,
                    transport: appModel.activeTransport
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    HostSettingsView(host: host)
                } label: {
                    Label("nav.settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewSession = true
                } label: {
                    Label("sessions.new", systemImage: "plus")
                }
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
        }
        .sheet(isPresented: $showProjectPicker) {
            SessionProjectPickerSheet(
                options: SessionListFiltering.allOptions(sessions: windowSessions),
                hasNoProject: SessionListFiltering.hasNoProject(sessions: windowSessions),
                selected: $projectFilter
            )
        }
        .sheet(isPresented: $showNewSession, onDismiss: {
            openPendingCreatedSessionIfNeeded()
        }) {
            NewSessionSheet(host: host) { session in
                listStore.patchSession(session)
                listStore.rememberOpened(session)
                pendingCreatedSessionKey = session.key
            }
        }
        .confirmationDialog(
            "sessions.delete_confirm.title",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("sessions.action.delete", role: .destructive) {
                if let session = sessionToDelete {
                    Task { await deleteSession(session) }
                }
                sessionToDelete = nil
            }
            Button("action.cancel", role: .cancel) { sessionToDelete = nil }
        }
        .task(id: isActiveList) {
            guard isActiveList else { return }
            await bootstrap()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectBottomBarSearch") {
                isSearchPresented = true
            }
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectNewSession") {
                showNewSession = true
            }
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectProjectPicker") {
                showProjectPicker = true
            }
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectConversation") {
                let requestedKey = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"]
                let sessions = listStore.sections.flatMap(\.sessions)
                if let session = sessions.first(where: { requestedKey == nil || $0.key == requestedKey }) {
                    inspectedSessionRoute = SessionRoute(key: session.key)
                }
            }
            #endif
            // Reconcile missed events while this page remains visible.
            await feed.runRecheckLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .corralPendingNotificationOpen)) { _ in
            Task { await openPendingNotificationSession() }
        }
        .hapticScope(hapticScope)
        .onAppear {
            isActiveList = true
            Task { await openPendingNotificationSession() }
        }
        .onDisappear {
            isActiveList = false
            teardownWatch()
        }
    }

    @ViewBuilder
    private func sessionDetail(for route: SessionRoute, autoFocusComposer: Bool) -> some View {
        if let session = listStore.session(for: route.key) {
            SessionDetailView(
                session: session,
                autoFocusComposer: autoFocusComposer,
                metadataStore: listStore,
                onDidCreateSession: { created in
                    listStore.patchSession(created)
                    listStore.rememberOpened(created)
                    openedSessionRoute = SessionRoute(key: created.key)
                }
            )
                .id(route.key)
                .onAppear { listStore.rememberOpened(session) }
        } else {
            ContentUnavailableView(
                "sessions.empty.title",
                systemImage: "bubble.left.and.bubble.right"
            )
        }
    }

    private func openPendingCreatedSessionIfNeeded() {
        guard let key = pendingCreatedSessionKey else { return }
        pendingCreatedSessionKey = nil
        // Sheet dismiss animation first, then push chat so focus sticks.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            openedSessionRoute = SessionRoute(key: key)
        }
    }

    /// The floating bottom search field must never rest on top of the last row.
    private static var searchBarClearance: CGFloat {
        if #available(iOS 26.0, *) { Space.xl } else { 0 }
    }

    /// Store sections intersected with the runtime/project quick filters.
    /// Search is already applied inside the store; counts and headers below
    /// always describe exactly these rows.
    private var visibleSections: [SessionListStore.Section] {
        SessionListFiltering.apply(
            to: listStore.sections,
            runtimes: runtimeFilter,
            projects: projectFilter,
            activeOnly: activeOnly
        )
    }

    /// Unfiltered host window backing the project choices, so text search
    /// narrows only the displayed rows while choices stay available.
    private var windowSessions: [SessionSummary] {
        listStore.windowSessions
    }

    /// Every selected project outside the quick set remains directly reachable.
    private var selectedOutsideRecents: [SessionProjectOption] {
        projectFilter.compactMap { selection -> String? in
            guard case .project(let path) = selection,
                  !projectChoices.contains(where: { $0.path == path }) else { return nil }
            return path
        }.sorted().map {
            SessionListFiltering.option(for: $0, sessions: windowSessions)
        }
    }

    /// Any narrowing: a filter dimension or text search.
    private var hasActiveScope: Bool {
        activeOnly || !runtimeFilter.isEmpty || !projectFilter.isEmpty || isSearching
    }

    /// Human-readable filtered scope for the empty-results description:
    /// runtime and project names plus the quoted search text when searching.
    /// Brand and project names need no localization; All/home do.
    private var filterScopeDescription: String {
        let all = String(localized: String.LocalizationValue("sessions.filter.all"))
        let runtimeNames = SessionRuntimeFilter.ordered.filter {
            runtimeFilter.contains($0)
        }.map { Palette.runtimeDisplayName($0.rawValue) }
        let runtimeName = runtimeNames.isEmpty ? all : runtimeNames.joined(separator: ", ")
        let projectNames = projectFilter.map { selection -> String in
            switch selection {
            case .all: all
            case .noProject: String(
                    localized: String.LocalizationValue("sessions.filter.project.none")
                )
            case .project(let path):
                path == "~"
                    ? String(localized: String.LocalizationValue("sessions.project.home"))
                    : SessionListFiltering.option(for: path, sessions: windowSessions).label
            }
        }.sorted()
        let projectName = projectNames.isEmpty ? all : projectNames.joined(separator: ", ")
        var scope = "\(runtimeName) · \(projectName)"
        if activeOnly {
            scope = String(localized: String.LocalizationValue("sessions.filter.active")) + " · " + scope
        }
        let query = listStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            scope += " · “\(query)”"
        }
        return scope
    }

    private func clearFilters() {
        activeOnly = false
        runtimeFilter.removeAll()
        projectFilter.removeAll()
        listStore.searchQuery = ""
    }

    private func sectionTitle(_ section: SessionListStore.Section) -> String {
        // 移动端没有分组概念：置顶区标题就是纯标题，不再按桌面分屏组拼 emoji。
        switch section {
        case .waiting: String(localized: "sessions.section.waiting")
        case .pinned: String(localized: "sessions.section.pinned")
        case .today: String(localized: "sessions.section.today")
        case .yesterday: String(localized: "sessions.section.yesterday")
        case .earlier: String(localized: "sessions.section.earlier")
        }
    }

    private var isSearching: Bool {
        !listStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSectionExpanded(_ section: SessionListStore.Section) -> Bool {
        if hasActiveScope { return true }
        if let expanded = sectionExpansion[section.id] { return expanded }
        switch section {
        case .waiting, .pinned, .today: return true
        case .yesterday, .earlier: return false
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: SessionListStore.Section) -> some View {
        let title = sectionTitle(section)
        let count = section.sessions.count.formatted()
        let label = HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(title)
                .font(Typography.sectionHeader)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            Text(count)
                .font(Typography.sessionMeta)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .monospacedDigit()
        }
        if !hasActiveScope && section.id != "waiting" {
            DisclosureGroup(isExpanded: Binding(
                get: { isSectionExpanded(section) },
                set: { sectionExpansion[section.id] = $0 }
            )) {
                EmptyView()
            } label: {
                label
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(count))
        } else {
            label
        }
    }

    private func bootstrap() async {
        feed.onListChanged = { await openPendingNotificationSession() }
        // Cached session leg first: open from the persisted snapshot before any
        // connection completes, so offline body taps still land in the session.
        await feed.activate(appModel: appModel) {
            await openPendingNotificationSession()
        }
    }

    /// Notification-tap session leg, consumed only while this list is visible.
    /// Known keys push immediately from cache or snapshot. Unknown keys never push
    /// the empty fallback and no list window may declare them gone (`has_more`
    /// windows are not an authoritative catalog): the ticket stays pending and a
    /// direct `session.get` lookup resolves it once this host is connected.
    /// Only the server's explicit `not_found` consumes with a visible recovery;
    /// transient failures keep the ticket retryable. Never synthesizes messages.
    /// A new route resets the old one first so repeats are not blocked by a stale value.
    private func openPendingNotificationSession() async {
        guard isActiveList else { return }
        let registrar = PushRegistrar.shared
        guard let key = registrar.pendingSessionKey(for: host.hostID) else {
            pendingWaitKey = nil
            pendingLookupError = nil
            return
        }
        if missingNotificationKey != nil, missingNotificationKey != key {
            missingNotificationKey = nil
        }
        switch NotificationReply.resolveTap(found: listStore.session(for: key) != nil) {
        case .push:
            pendingWaitKey = nil
            lookupTicket = nil
            pendingLookupError = nil
            missingNotificationKey = nil
            if registrar.consumePendingOpen(hostID: host.hostID, sessionKey: key) {
                pushNotificationSession(key: key)
            }
        case .wait:
            pendingWaitKey = key
            await lookupNotificationSessionIfNeeded(key: key)
        case .unavailable:
            // Unreachable from resolveTap: absence is only declared by the direct
            // lookup below, never by a snapshot. Kept for exhaustiveness.
            break
        }
    }

    /// Direct `session.get` lookup for a tap whose key is outside the current
    /// window. One lookup per ticket; every await rechecks the captured client,
    /// host, and ticket, so a superseded or wrong-host result is dropped without
    /// consuming the ticket or opening a stale target. No history fetch, no list
    /// expansion: exactly one summary merge.
    private func lookupNotificationSessionIfNeeded(key: String) async {
        let registrar = PushRegistrar.shared
        let ticket = registrar.pendingOpen.ticket
        guard NotificationReply.shouldStartLookup(ticket: ticket, inflightTicket: lookupTicket) else { return }
        guard appModel.connectedHostID == host.hostID, let client = appModel.client else { return }
        lookupTicket = ticket
        pendingLookupError = nil
        do {
            let summary = try await client.call(
                WireProtocol.mSessionGet,
                params: ["key": key],
                as: SessionSummary.self
            )
            guard !Task.isCancelled, isActiveList,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID,
                  registrar.pendingSessionKey(for: host.hostID) == key,
                  registrar.pendingOpen.ticket == ticket else {
                if lookupTicket == ticket { lookupTicket = nil }
                return
            }
            // Identity check first: a dormant summary must not mutate aliases or
            // merge anything, even when the key is otherwise unknown.
            guard ActiveRuntimeVisibility.isListVisible(summary) else {
                // Dormant history stays on the host; the phone holds no entrypoint
                // for it. Consume the tap into the existing dismissible recovery
                // instead of pushing a detail or leaving the ticket retryable.
                if registrar.consumePendingOpen(hostID: host.hostID, sessionKey: key) {
                    lookupTicket = nil
                    pendingWaitKey = nil
                    pendingLookupError = nil
                    missingNotificationKey = key
                } else if lookupTicket == ticket {
                    lookupTicket = nil
                }
                return
            }
            if summary.key != key {
                // Server resolved a provisional key to its canonical identity:
                // keep the tapped key usable as an alias.
                listStore.migrateSession(from: key, to: summary.key)
            }
            listStore.patchSession(summary)
            listStore.rememberOpened(summary)
            lookupTicket = nil
            pendingWaitKey = nil
            pendingLookupError = nil
            missingNotificationKey = nil
            if registrar.consumePendingOpen(hostID: host.hostID, sessionKey: key) {
                pushNotificationSession(key: summary.key)
            }
        } catch {
            if lookupTicket == ticket { lookupTicket = nil }
            guard !Task.isCancelled, isActiveList,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID,
                  registrar.pendingSessionKey(for: host.hostID) == key,
                  registrar.pendingOpen.ticket == ticket else { return }
            switch NotificationReply.classifyLookupError(error) {
            case .unavailable:
                if registrar.consumePendingOpen(hostID: host.hostID, sessionKey: key) {
                    pendingWaitKey = nil
                    missingNotificationKey = key
                }
            case .wait:
                // Retryable: keep the ticket and surface the error with retry.
                pendingWaitKey = key
                pendingLookupError = remoteErrorMessage(error)
            case .push:
                break
            }
        }
    }

    /// Error text for the pending-tap recovery: the lookup failure when present,
    /// otherwise the offline message. Both keys already exist; no new copy.
    private var pendingTapErrorText: String {
        pendingLookupError ?? String(localized: String.LocalizationValue("error.not_connected"))
    }

    /// Retry recovery for a pending tap. Preserves the exact pending host/session/
    /// ticket (the registrar is never touched here) and re-establishes this host's
    /// connection before refreshing; every downstream step rechecks current client
    /// ownership, revision, host, and ticket before consuming or pushing.
    private func retryPendingConnection() async {
        guard isActiveList else { return }
        pendingLookupError = nil
        await feed.reconnect()
        guard !Task.isCancelled, isActiveList else { return }
        await openPendingNotificationSession()
    }

    private func pushNotificationSession(key: String) {        guard notificationSessionRoute?.key == key else {
            notificationSessionRoute = SessionRoute(key: key)
            return
        }
        // Same value would block repeat navigation: reset, then set on the next
        // main-actor turn so the destination observes a change.
        notificationSessionRoute = nil
        Task { @MainActor in
            notificationSessionRoute = SessionRoute(key: key)
        }
    }

    private func refreshSessions(showLoading: Bool) async {
        await feed.refresh(showLoading: showLoading)
    }

    private func teardownWatch() {
        feed.deactivate()
    }

    private func scheduleRemoteSearch(_ query: String) {
        feed.scheduleRemoteSearch(query)
    }

    private func togglePin(_ session: SessionSummary) async {
        let operationID = hapticScope.beginOperation()
        do {
            if try await feed.togglePin(session) {
                HapticFeedback.shared.emit(.selection, operationID: operationID, scope: hapticScope)
            }
        } catch {
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
        }
    }

    private func stopSession(_ session: SessionSummary) async {
        let operationID = hapticScope.beginOperation()
        do {
            if try await feed.stop(session) {
                HapticFeedback.shared.emit(.committed, operationID: operationID, scope: hapticScope)
            }
        } catch {
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
        }
    }

    private func deleteSession(_ session: SessionSummary) async {
        let operationID = hapticScope.beginOperation()
        do {
            try await feed.delete(session)
            HapticFeedback.shared.emit(.committed, operationID: operationID, scope: hapticScope)
        } catch {
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
        }
    }

    private func remoteErrorMessage(_ error: Error) -> String {
        HostSessionFeed.remoteErrorMessage(error)
    }

    /// Hide the duplicate "not connected" card when the connection row already says the same thing.
    private func shouldShowLoadErrorBanner(_ message: String) -> Bool {
        let notConnected = String(localized: String.LocalizationValue("error.not_connected"))
        guard message == notConnected else { return true }
        switch appModel.connectionState {
        case .failed, .disconnected, .connecting, .reconnecting:
            return false
        case .connected:
            return true
        }
    }
}

/// 列表页边距：行文字左缘=分组标题左缘=分隔线左端；图标不吃这层边距。
/// nonisolated：纯布局常量，被 Sendable 的 alignmentGuide 闭包引用。
nonisolated enum SessionListLayout {
    /// 行左右边距：与对话页 Space.base 对齐。
    static let rowHorizontal: CGFloat = 16
    /// 分隔线左端与标题左缘对齐，跳过助手图标列。
    /// 44 = 图标 32 + 图文间距 12；与 SessionRowLayout.badgeSize + Space.md 同值，
    /// 这里用字面量避免从 nonisolated 上下文引用 MainActor 隔离的 token。
    static let separatorLeading: CGFloat = 44
    /// Vertical padding belongs to SessionRowView; this layer adds only side margins.
    static var rowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: rowHorizontal, bottom: 0, trailing: rowHorizontal)
    }
}

#endif
