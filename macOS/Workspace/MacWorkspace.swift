import AppKit
import Foundation
import Observation
import SwiftUI

/// The right side of the main window, modelled on the TUI's split area: up to
/// four panes, one focused pane, and the shared
/// group layout (`layout.*`). Two or more panes are a TUI session group, so the
/// same split shows up in every TUI window of the host and vice versa.
@MainActor
@Observable
final class MacWorkspace {
    /// Presentation only, used to size a new project terminal at its current font.
    var interfaceScale: CGFloat = 1
    enum PaneMode: String {
        case chat
        case terminal
    }

    static let maxPanes = 4

    private(set) var hostID: String?
    @ObservationIgnored private var layoutGeneration = UUID()

    private(set) var paneKeys: [String] = []
    var focusedKey: String?
    /// Panes the user added, which fade in. Panes opened by a sidebar click,
    /// restoration or a machine switch are absent.
    private(set) var pendingEntrances: Set<String> = []
    /// Split motion (design: Motion design, round 2): per pane, the horizontal
    /// offset back to where it was drawn before a pane was added or closed (a
    /// new last pane: beyond the trailing edge), animated to zero once the new
    /// layout is on screen. Widths change in one step; only offsets travel.
    private(set) var paneShifts: [String: CGFloat] = [:]
    /// Closed panes still drawn while they fade out, by key → slot.
    private(set) var leavingPanes: [String: Int] = [:]
    /// Width of the split area (set by it), for the slot positions.
    @ObservationIgnored var splitWidth: CGFloat = 0
    /// Height of the split area (set by it), for a new terminal's starting grid.
    @ObservationIgnored var splitHeight: CGFloat = 0
    @ObservationIgnored private var glideSerial = 0
    private(set) var layout: DesktopLayout = .empty
    /// A failed action's message for the window alert.
    var actionError: String?
    /// Assistants installed on the host (for "Add pane" and Continue with…).
    private(set) var runtimes: [RuntimeEntry] = []
    /// Selecting a pane is where the keys go: the pane whose composer should
    /// hold the caret, and a serial bumped on every request.
    private(set) var keyFocusTarget: String?
    private(set) var keyFocusSerial = 0
    /// A person's open/closed choice for a session's prompts card; without
    /// one the card is open only where it fits beside the conversation.
    var promptsOpen: [String: Bool] = [:]
    /// Prompts card → scroll that pane's conversation to a prompt.
    private(set) var scrollRequests: [String: ChatScrollRequest] = [:]
    /// Project shells of this machine (terminal panes look their titles up here).
    let shells = ProjectShellStore()
    let paneSurfaces = MacPaneSurfaceCache()
    /// A terminal pane whose shell runs a program, waiting for close confirmation.
    var pendingTerminalClose: ProjectShell?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var layoutClient: RemoteClient?
    @ObservationIgnored private var readyHandlerID: UUID?
    @ObservationIgnored weak var feed: HostSessionFeed?

    private static let modesKey = "corral.mac.paneModes"
    /// Settings: the view a session created by this client opens in.
    static let newSessionModeKey = "corral.mac.newSessionMode"
    private var modes: [String: String] = UserDefaults.standard.dictionary(forKey: MacWorkspace.modesKey) as? [String: String] ?? [:]

    func attach(appModel: AppModel) {
        self.appModel = appModel
    }

    /// Reset host-owned state before showing another machine's cached list.
    func selectHost(_ id: String?) {
        guard hostID != id else { return }
        stopLayoutWatch()
        paneSurfaces.reset()
        hostID = id
        layout = .empty
        paneKeys = []
        focusedKey = nil
        runtimes = []
        promptsOpen = [:]
        pendingEntrances = []
        cancelSplitMotion()
        keyFocusTarget = nil
        scrollRequests = [:]
        paneFrames = [:]
        actionError = nil
        feed = nil
        shells.reset()
        pendingTerminalClose = nil
    }

    // MARK: - Chat / terminal per session (chat by default, remembered)

    /// Keyed by the canonical session key, so a pane still holding the
    /// provisional key of a new session reads the same choice.
    private func modeKey(_ key: String) -> String {
        "\(hostID ?? ""):\(feed?.listStore.resolvedKey(key) ?? key)"
    }

    func mode(for key: String) -> PaneMode {
        if ProjectShell.isShellKey(key) { return .terminal }
        return modes[modeKey(key)].flatMap(PaneMode.init(rawValue:)) ?? .chat
    }

    func setMode(_ mode: PaneMode, for key: String) {
        modes[modeKey(key)] = mode.rawValue
        UserDefaults.standard.set(modes, forKey: Self.modesKey)
    }

    /// A new session's provisional key becomes canonical after its first
    /// prompt; its chosen view must survive the rename.
    func carryMode(from oldKey: String, to newKey: String) {
        let old = "\(hostID ?? ""):\(oldKey)"
        guard let stored = modes.removeValue(forKey: old) else { return }
        let new = modeKey(newKey)
        if modes[new] == nil { modes[new] = stored }
        UserDefaults.standard.set(modes, forKey: Self.modesKey)
    }

    /// Only sessions created here follow the setting; history keeps chat so
    /// browsing never resumes ended sessions through the terminal view.
    private func applyNewSessionMode(to key: String) {
        let preferred = UserDefaults.standard.string(forKey: Self.newSessionModeKey)
            .flatMap(PaneMode.init(rawValue:)) ?? .chat
        if preferred != .chat { setMode(preferred, for: key) }
    }

    func toggleModeOfFocusedPane() {
        guard let key = focusedKey, !ProjectShell.isShellKey(key) else { return }
        setMode(mode(for: key) == .chat ? .terminal : .chat, for: key)
        requestKeyFocus(key)
    }

    // MARK: - Opening and closing panes (TUI semantics)

    /// Sidebar click: a member of a shown group opens the whole group with that
    /// pane focused; any other session replaces the workspace with itself.
    /// `takeKeys` nil infers it: a mouse click on a sidebar row moves the caret
    /// into the opened pane, arrow-key browsing keeps focus in the sidebar.
    func open(_ key: String, sessions: [SessionSummary], takeKeys: Bool? = nil) {
        if !pendingEntrances.isEmpty { pendingEntrances = [] }
        defer { if takeKeys ?? Self.selectionCameFromPointer { requestKeyFocus(key) } }
        if paneKeys.contains(key) {
            focus(key)
            return
        }
        let visible = Set(sessions.map(\.key))
        if let group = layout.group(containing: key) {
            let members = group.members.filter { visible.contains($0) }
            if members.count >= 2 {
                cancelSplitMotion()
                paneKeys = Array(members.prefix(Self.maxPanes))
                focus(key)
                return
            }
        }
        cancelSplitMotion()
        paneKeys = [key]
        focusedKey = key
    }

    /// Search can find history outside the current list window. Resolve and
    /// retain its summary before the split area attempts to render the pane.
    func openSearchResult(_ key: String) async throws -> Bool {
        guard let feed, let client = appModel?.client else {
            throw NSError(domain: "Corral", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "error.not_connected")])
        }
        let host = hostID
        let session: SessionSummary
        if let cached = feed.listStore.session(for: key) {
            session = cached
        } else {
            session = try await client.call(WireProtocol.mSessionGet, params: ["key": key], as: SessionSummary.self)
        }
        guard !Task.isCancelled, hostID == host, self.feed === feed, appModel?.client === client else { return false }
        guard ActiveRuntimeVisibility.isListVisible(session) else {
            throw NSError(domain: "Corral", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "notification.unavailable")])
        }
        feed.listStore.rememberOpened(session)
        feed.listStore.applySessionEvent(session)
        open(session.key, sessions: feed.listStore.windowSessions, takeKeys: true)
        return true
    }

    func openGroup(_ group: DesktopGroup, sessions: [SessionSummary]) {
        let visible = Set(sessions.map(\.key))
        let members = group.members.filter { visible.contains($0) }
        guard let first = members.first else { return }
        pendingEntrances = []
        cancelSplitMotion()
        paneKeys = Array(members.prefix(Self.maxPanes))
        let target = group.members.contains(group.focus) && members.contains(group.focus) ? group.focus : first
        focus(target)
        if Self.selectionCameFromPointer { requestKeyFocus(target) }
    }

    /// Relaunch: show the panes from the last run without writing the layout.
    /// The host's groups may have changed in the TUI meanwhile; a restored
    /// split must not overwrite them. The next pane change syncs as usual.
    func restorePanes(_ keys: [String]) {
        guard let first = keys.first else { return }
        pendingEntrances = []
        cancelSplitMotion()
        var unique: [String] = []
        for key in keys where !unique.contains(key) { unique.append(key) }
        paneKeys = Array(unique.prefix(Self.maxPanes))
        focusedKey = first
    }

    #if DEBUG
    /// Restore local acceptance state, including an initially empty workspace,
    /// without changing the host's shared session groups.
    func inspectionRestoreWorkspace(keys: [String], focus: String?) {
        cancelSplitMotion()
        paneKeys = keys
        focusedKey = focus
    }
    #endif

    /// Split: add a session as another pane (replaces the focused pane when full).
    func addPane(_ key: String, project: String) {
        if paneKeys.contains(key) {
            focus(key)
            return
        }
        leavingPanes[key] = nil
        let before = drawnPaneKeys
        if paneKeys.count >= Self.maxPanes, let focusedKey, let index = paneKeys.firstIndex(of: focusedKey) {
            paneKeys[index] = key
        } else {
            paneKeys.append(key)
        }
        pendingEntrances.insert(key)
        glide(from: before, entering: key)
        focusedKey = key
        requestKeyFocus(key)
        syncGroup(project: project)
    }

    /// Pane ✕ / ⌘W: the hosted session keeps running; the pane leaves the split
    /// and its group (which dissolves below two members), focus stays on a
    /// remaining pane and never jumps to the closed session.
    func closePane(_ key: String) {
        guard let index = paneKeys.firstIndex(of: key) else { return }
        let wasGrouped = paneKeys.count >= 2 && layout.group(containing: key) != nil
        let slot = drawnPaneKeys.firstIndex(of: key) ?? index
        paneKeys.remove(at: index)
        beginLeaving(key, slot: slot)
        if focusedKey == key {
            focusedKey = paneKeys.isEmpty ? nil : paneKeys[min(index, paneKeys.count - 1)]
            requestKeyFocus(focusedKey)
        }
        guard wasGrouped else { return }
        scheduleLayout(WireProtocol.mLayoutRemoveSession, ["key": key])
    }

    func focus(_ key: String) {
        guard focusedKey != key else { return }
        focusedKey = key
        guard paneKeys.count >= 2, layout.group(containing: key) != nil else { return }
        let project = projectPath(of: key)
        scheduleLayout(WireProtocol.mLayoutSetFocus, ["key": key, "project": project])
    }

    func focusPane(at index: Int) {
        guard paneKeys.indices.contains(index) else { return }
        focus(paneKeys[index])
        requestKeyFocus(paneKeys[index])
    }

    // MARK: - Split motion

    /// Panes on screen in the split: the split's panes plus closed ones that
    /// are still fading out in their old slots.
    var drawnPaneKeys: [String] {
        guard !leavingPanes.isEmpty else { return paneKeys }
        var keys = paneKeys
        for (key, slot) in leavingPanes.sorted(by: { $0.value < $1.value }) where !keys.contains(key) {
            keys.insert(key, at: min(slot, keys.count))
        }
        return keys
    }

    /// Navigation replaces the split in one step: drop exits and glides.
    /// Assigning an equal value still notifies Observation and walks the whole
    /// retained hierarchy, so only touch state that actually changes.
    private func cancelSplitMotion() {
        glideSerial += 1
        if !paneShifts.isEmpty { paneShifts = [:] }
        if !leavingPanes.isEmpty { leavingPanes = [:] }
    }

    /// The closed pane stays in its slot while it fades out, then leaves the
    /// layout and the panes after it glide into the freed space.
    private func beginLeaving(_ key: String, slot: Int) {
        pendingEntrances.remove(key)
        leavingPanes[key] = slot
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(MacMotion.seconds(MacMotion.paneExitSeconds)))
            guard let self, self.leavingPanes[key] != nil, !self.paneKeys.contains(key) else { return }
            let before = self.drawnPaneKeys
            self.leavingPanes[key] = nil
            self.glide(from: before)
        }
    }

    /// Draw every pane whose slot moved at its previous position (and a new
    /// last pane just beyond the trailing edge) in the same update as the
    /// layout change, then animate the offsets home once that frame is on
    /// screen; building a pane can block long enough to swallow an animation
    /// started with the change.
    private func glide(from before: [String], entering: String? = nil) {
        glideSerial += 1
        let after = drawnPaneKeys
        var shifts: [String: CGFloat] = [:]
        if splitWidth > 0, !before.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (index, key) in after.enumerated() {
                if let old = before.firstIndex(of: key) {
                    let delta = slotX(old, of: before.count) - slotX(index, of: after.count)
                    if abs(delta) >= 1 { shifts[key] = delta }
                } else if key == entering, index == after.count - 1, after.count > before.count {
                    shifts[key] = splitWidth - slotX(index, of: after.count)
                }
            }
        }
        paneShifts = shifts
        guard !shifts.isEmpty else { return }
        let serial = glideSerial
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, self.glideSerial == serial else { return }
            withAnimation(MacMotion.paneGlide) { self.paneShifts = [:] }
        }
    }

    /// Leading edge of a slot: the split shares its width equally.
    private func slotX(_ index: Int, of count: Int) -> CGFloat {
        splitWidth * CGFloat(index) / CGFloat(max(count, 1))
    }

    // MARK: - Keyboard focus follows the selected pane

    func requestKeyFocus(_ key: String?) {
        guard let key else { return }
        keyFocusTarget = key
        keyFocusSerial += 1
    }

    /// The composer focus request a pane passes down (zero: leave focus alone).
    func composerFocusRequest(for key: String) -> Int {
        keyFocusTarget == key && mode(for: key) == .chat ? keyFocusSerial : 0
    }

    /// The caret entered a pane's composer by itself (Tab or a click on it):
    /// that pane becomes the selected one.
    func composerDidGainFocus(_ key: String) {
        keyFocusTarget = key
        focus(key)
    }

    /// After a click inside a chat pane: keep selectable text or the pane's
    /// own composer, otherwise move the caret into the pane's composer. Runs
    /// once the click finished, so the clicked view already took focus.
    func claimKeysAfterClick(in key: String, window: NSWindow?) {
        guard paneFrames[key] != nil, mode(for: key) == .chat else { return }
        if let textView = window?.firstResponder as? NSTextView,
           let frame = paneFrames[key], let content = window?.contentView {
            // A long message's document centre can lie outside its pane.
            // Use the clipped portion, and keep focus even before a drag has
            // produced its first selected character.
            let rect = textView.convert(textView.visibleRect, to: nil)
            let topLeft = CGPoint(x: rect.midX, y: content.bounds.height - rect.midY)
            if !rect.isEmpty, frame.contains(topLeft), textView.isEditable || textView.isSelectable {
                keyFocusTarget = key
                return
            }
        }
        requestKeyFocus(key)
    }

    /// A click or key in the last half second (a stale current event from
    /// earlier input does not count).
    private static var selectionCameFromPerson: Bool {
        guard let event = NSApp.currentEvent,
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5 else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown: return true
        default: return false
        }
    }

    private static var selectionCameFromPointer: Bool {
        selectionCameFromPerson && NSApp.currentEvent?.type != .keyDown
    }

    // MARK: - Prompts card jump

    /// Scroll a pane's chat to one prompt; a terminal pane switches to chat.
    func scrollToPrompt(_ messageID: String, in key: String) {
        if mode(for: key) == .terminal { setMode(.chat, for: key) }
        focus(key)
        scrollRequests[key] = ChatScrollRequest(messageID: messageID)
    }

    /// The sidebar reflects the focused pane.
    func replaceKey(_ old: String, with new: String) {
        if let index = paneKeys.firstIndex(of: old) { paneKeys[index] = new }
        if focusedKey == old { focusedKey = new }
    }

    /// Only sessions form a TUI group: terminal panes stay local to the Mac.
    private func syncGroup(project: String) {
        let sessionKeys = paneKeys.filter { !ProjectShell.isShellKey($0) }
        guard sessionKeys.count >= 2 else { return }
        let groupProject = project.isEmpty ? projectPath(of: sessionKeys[0]) : project
        var params: [String: Any] = ["project": groupProject, "keys": sessionKeys]
        if let focusedKey, sessionKeys.contains(focusedKey) { params["focus"] = focusedKey }
        scheduleLayout(WireProtocol.mLayoutSetGroup, params)
    }

    private func scheduleLayout(_ method: String, _ params: [String: Any]) {
        #if DEBUG
        // A tool activity inspection keeps its local conversation steady and
        // never changes the person's shared terminal/workspace layout.
        guard !ProcessInfo.processInfo.arguments.contains("-CorralInspectToolActivity") else { return }
        #endif
        guard let client = appModel?.client else { return }
        let host = hostID
        Task { [weak self] in
            guard let self, self.hostID == host, self.appModel?.client === client else { return }
            _ = await self.call(method, params, background: true)
        }
    }

    /// The pane finished (or skipped) its entrance.
    func clearEntrance(_ key: String) {
        pendingEntrances.remove(key)
    }

    // MARK: - Layout watch (shared with the TUI)

    func startLayoutWatch() {
        guard let client = appModel?.client else { return }
        guard client.hostCapabilities.desktopLayout else {
            stopLayoutWatch()
            layout = .empty
            Task { await loadRuntimes(client) }
            return
        }
        guard layoutClient !== client else { return }
        stopLayoutWatch()
        layoutClient = client
        let generation = layoutGeneration
        let events = client.subscribe(channel: WireProtocol.chLayout)
        layoutTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.layoutClient === client,
                      self.layoutGeneration == generation else { break }
                if let snapshot = try? RemoteJSONDecoder.decode(DesktopLayout.self, from: event.data) {
                    self.applyLayout(snapshot)
                }
            }
        }
        readyHandlerID = client.addReadyHandler { [weak self] in
            guard let self, self.layoutClient === client, self.layoutGeneration == generation else { return }
            Task { await self.pullLayout() }
        }
        Task {
            await pullLayout()
            await loadRuntimes(client)
        }
    }

    func stopLayoutWatch() {
        layoutGeneration = UUID()
        layoutTask?.cancel()
        layoutTask = nil
        if let readyHandlerID, let layoutClient {
            layoutClient.removeReadyHandler(readyHandlerID)
        }
        readyHandlerID = nil
        if let client = layoutClient {
            Task { _ = try? await client.call(WireProtocol.mLayoutUnwatch) }
        }
        layoutClient = nil
    }

    private func loadRuntimes(_ client: RemoteClient) async {
        let generation = layoutGeneration
        let host = hostID
        guard let data = try? await client.call(WireProtocol.mRuntimesList) as? [String: Any],
              let items = data["runtimes"] as? [[String: Any]] else { return }
        guard !Task.isCancelled, appModel?.client === client, hostID == host,
              layoutGeneration == generation else { return }
        runtimes = items.compactMap { try? RemoteJSONDecoder.decode(RuntimeEntry.self, from: $0) }.filter(\.isActive)
    }

    private func pullLayout() async {
        guard let client = layoutClient else { return }
        let generation = layoutGeneration
        if let snapshot = try? await client.call(WireProtocol.mLayoutWatch, as: DesktopLayout.self) {
            guard !Task.isCancelled, layoutClient === client, layoutGeneration == generation else { return }
            applyLayout(snapshot)
        }
    }

    private func applyLayout(_ snapshot: DesktopLayout) {
        #if DEBUG
        guard !ProcessInfo.processInfo.arguments.contains("-CorralInspectToolActivity") else { return }
        #endif
        guard snapshot.revision >= layout.revision || snapshot.revision == 0 else { return }
        layout = snapshot
    }

    // MARK: - Session actions (pane header, sidebar menu and menu bar share these)

    func togglePin(_ key: String) async {
        await call(WireProtocol.mLayoutPin, ["key": key])
    }

    func toggleGroupPin(_ group: DesktopGroup) async {
        await call(WireProtocol.mLayoutPinGroup, ["group_id": group.id])
    }

    func setCollapsed(_ group: DesktopGroup, collapsed: Bool) async {
        await call(WireProtocol.mLayoutCollapse, ["group_id": group.id, "collapsed": collapsed])
    }

    /// Fork / continue with another assistant: the new session opens in a pane
    /// beside its source, as the TUI's advanced actions do.
    func fork(_ source: SessionSummary) async {
        await createBeside(source, method: WireProtocol.mSessionCopy, params: ["key": source.key])
    }

    func handoff(_ source: SessionSummary, to runtimeID: String) async {
        await createBeside(source, method: WireProtocol.mSessionHandoff, params: ["key": source.key, "runtime": runtimeID])
    }

    func restart(_ key: String) async {
        await call(WireProtocol.mSessionRestart, ["key": key])
    }

    func stop(_ key: String) async {
        await call(WireProtocol.mSessionStop, ["key": key, "confirm": true])
    }

    func resume(_ key: String) async -> Bool {
        await call(WireProtocol.mSessionResume, ["key": key]) != nil
    }

    /// Terminal view starting an ended session: the failure belongs to the
    /// pane that asked, so it is returned instead of raised as a window alert.
    func resumeInPane(_ key: String) async -> String? {
        var failure: String?
        let result = await call(WireProtocol.mSessionResume, ["key": key]) { failure = $0 }
        return result == nil ? failure ?? String(localized: "error.unknown") : nil
    }

    /// TUI top bar: click an assistant to add a pane with a new session in the
    /// focused pane's project.
    func newSessionPane(runtimeID: String, project: String) async {
        guard let client = appModel?.client, let host = hostID else {
            actionError = String(localized: "error.not_connected")
            return
        }
        do {
            let created = try await SessionCreationCoordinator.create(
                hostID: host, runtimeID: runtimeID, cwd: project,
                supportsReceipts: client.hostCapabilities.sessionCreateReceipts,
                call: { method, params in try await client.call(method, params: params) }
            )
            guard !Task.isCancelled, appModel?.client === client, hostID == host else { return }
            openCreated(created, asPane: true)
        } catch {
            guard !Task.isCancelled, appModel?.client === client, hostID == host else { return }
            actionError = SessionActionsMenu.failureMessage(for: error)
        }
    }

    /// Pane frames in window coordinates (top-left origin), for click-to-focus.
    @ObservationIgnored var paneFrames: [String: CGRect] = [:]

    func paneKey(atWindowPoint point: CGPoint) -> String? {
        paneFrames.first { $0.value.contains(point) }?.key
    }

    func openCreated(_ session: SessionSummary, asPane: Bool) {
        feed?.listStore.patchSession(session)
        feed?.listStore.rememberOpened(session)
        applyNewSessionMode(to: session.key)
        if asPane, !paneKeys.isEmpty {
            addPane(session.key, project: session.cwd)
        } else {
            cancelSplitMotion()
            paneKeys = [session.key]
            focusedKey = session.key
            requestKeyFocus(session.key)
        }
    }

    private func createBeside(_ source: SessionSummary, method: String, params: [String: Any]) async {
        guard let payload = await call(method, params, refreshLayout: false),
              let created = try? SessionActionsMenu.decodeNewSession(from: payload) else { return }
        if !paneKeys.contains(source.key) {
            cancelSplitMotion()
            paneKeys = [source.key]
        }
        openCreated(created, asPane: true)
    }

    /// `background` marks syncs that follow pane changes (group, focus,
    /// removal): a failure there is retried by the next change, so it must not
    /// interrupt with an alert the way a failed user action does.
    @discardableResult
    private func call(
        _ method: String, _ params: [String: Any] = [:], refreshLayout: Bool = true, background: Bool = false,
        onFailure: ((String) -> Void)? = nil
    ) async -> Any? {
        let report: (String) -> Void = { message in
            if let onFailure { onFailure(message) } else if !background { self.actionError = message }
        }
        guard let client = appModel?.client else {
            report(String(localized: String.LocalizationValue("error.not_connected")))
            return nil
        }
        let host = hostID
        do {
            let result = try await client.call(method, params: params)
            guard !Task.isCancelled, appModel?.client === client, hostID == host else { return nil }
            if [WireProtocol.mSessionResume, WireProtocol.mSessionRestart].contains(method),
               let session = try? SessionActionsMenu.decodeNewSession(from: result) {
                feed?.listStore.patchSession(session)
            }
            if refreshLayout, method.hasPrefix("layout."),
               let snapshot = try? RemoteJSONDecoder.decode(DesktopLayout.self, from: result) {
                applyLayout(snapshot)
            }
            return result
        } catch {
            guard !Task.isCancelled, appModel?.client === client, hostID == host else { return nil }
            if !(error is CancellationError) {
                report(SessionActionsMenu.failureMessage(for: error))
            }
            return nil
        }
    }

    /// Folder of a pane: the session's project or the shell's start folder.
    func projectPath(of key: String) -> String {
        if ProjectShell.isShellKey(key) { return shells.shell(for: key)?.project ?? "" }
        return feed?.listStore.session(for: key)?.cwd ?? ""
    }

    // MARK: - Terminal panes (design: Project terminal)

    /// ⌥F12 / toolbar: focus the folder's terminal pane, bring back a shell of
    /// that folder still running on the host, or start a new one.
    func openTerminal(project: String) async {
        guard let client = appModel?.client else {
            actionError = String(localized: String.LocalizationValue("error.not_connected"))
            return
        }
        let host = hostID
        await shells.refresh(client: client)
        guard hostID == host else { return }
        let ofProject = shells.shells.filter { $0.project == project }
        if let shown = paneKeys.last(where: { key in ofProject.contains { $0.key == key } }) {
            focus(shown)
            requestKeyFocus(shown)
        } else if let running = ofProject.last {
            showTerminalPane(running.key)
        } else {
            await newTerminal(project: project)
        }
    }

    /// ⌥⌘T / Add Pane ▸ Terminal: a new shell in `project`, as a pane.
    func newTerminal(project: String) async {
        guard let client = appModel?.client else {
            actionError = String(localized: String.LocalizationValue("error.not_connected"))
            return
        }
        let host = hostID
        let shell = await shells.open(project: project, grid: newPaneTerminalGrid(), client: client)
        guard hostID == host else { return }
        guard let shell else {
            actionError = shells.failure
            shells.failure = nil
            return
        }
        showTerminalPane(shell.key)
    }

    /// The grid the new terminal pane's body will fit: its slot width once it
    /// joins the split (it replaces the focused pane when the split is full),
    /// the split height below the pane header.
    private func newPaneTerminalGrid() -> TerminalGrid? {
        guard splitWidth > 0, splitHeight > 0 else { return nil }
        let joining = paneKeys.isEmpty ? 1 : min(paneKeys.count + 1, Self.maxPanes)
        let width = (splitWidth - CGFloat(joining - 1)) / CGFloat(joining)
        return TerminalAppearance.fittingGrid(for: CGSize(width: width, height: splitHeight - Self.paneHeaderHeight * interfaceScale), interfaceScale: interfaceScale)
    }

    /// Pane header plus its divider (`MacPaneHeader`, `MacShellPane`).
    static let paneHeaderHeight: CGFloat = 31

    private func showTerminalPane(_ key: String) {
        if paneKeys.isEmpty {
            pendingEntrances = []
            cancelSplitMotion()
            paneKeys = [key]
            focusedKey = key
            requestKeyFocus(key)
        } else {
            addPane(key, project: "")
        }
    }

    /// Pane ✕ / ⌘W. A terminal pane ends its shell (asking first while a
    /// program runs in it); a session pane only leaves the split.
    func requestClose(_ key: String) {
        guard ProjectShell.isShellKey(key) else {
            closePane(key)
            return
        }
        guard let client = appModel?.client else {
            closePane(key)
            return
        }
        Task {
            if await shells.isBusy(key, client: client), let shell = shells.shell(for: key) {
                pendingTerminalClose = shell
            } else {
                endTerminal(key)
            }
        }
    }

    func endTerminal(_ key: String) {
        pendingTerminalClose = nil
        closePane(key)
        guard let client = appModel?.client else { return }
        Task { await shells.close(key, client: client) }
    }

    /// The shell exited (`exit`) or is gone from the host: drop its pane.
    func terminalEnded(_ key: String) {
        shells.removeEnded(key)
        closePane(key)
    }
}
