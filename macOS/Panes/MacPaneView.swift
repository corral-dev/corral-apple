import SwiftUI

/// One split pane: header and chat or terminal body. The pane owns the
/// session's conversation so switching between chat and terminal keeps it
/// live (and its prompts card current) in both views.
struct MacPaneView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macPaneLifetime) private var lifetime
    let session: SessionSummary
    let metadataStore: SessionListStore?
    var allowsClose = true
    var autoFocusComposer = false

    @State private var store: ConversationStore?
    @State private var bodySize: CGSize = .zero
    @State private var paneFrame: CGRect = .zero
    @State private var terminalVisited = false
    @State private var terminalPromptRequest: TerminalPromptRequest?
    @State private var promptStatus: TerminalPromptRowStatus?
    @State private var chatVisited = false
    /// Bumped on every (re)appearance; a disappear-triggered stop only runs
    /// when no reappearance has happened since, so a fast close→reopen can
    /// never stop the revived store from underneath its new start().
    @State private var visibilitySerial = 0

    init(session: SessionSummary, metadataStore: SessionListStore?, allowsClose: Bool = true,
         autoFocusComposer: Bool = false, retainedStore: ConversationStore? = nil,
         retainedBodySize: CGSize = .zero) {
        self.session = session
        self.metadataStore = metadataStore
        self.allowsClose = allowsClose
        self.autoFocusComposer = autoFocusComposer
        _store = State(initialValue: retainedStore)
        _bodySize = State(initialValue: retainedBodySize)
    }

    /// Read focus from the workspace directly. A cached copy on the pane's
    /// lifetime only refreshed when the surrounding split rebuilt, so a click
    /// or composer focus could leave the focused header in its inactive gray
    /// (owner report 2026-10-17).
    private var isFocused: Bool { workspace.focusedKey == session.key }
    private var mode: MacWorkspace.PaneMode { workspace.mode(for: session.key) }

    // MARK: - Focus guidance (design: Visual guidance pass)

    /// Another pane in the split holds the focus, so this composer steps back.
    private var composerRecedes: Bool {
        guard workspace.paneKeys.count > 1,
              let focused = workspace.focusedKey, focused != session.key else { return false }
        return workspace.paneKeys.contains(focused)
    }

    // MARK: - Prompts card (design: Prompts card)

    private var prompts: [RichMessage] {
        store?.userPrompts ?? []
    }

    /// Both presentations center in the same space beside an open prompts card.
    private var cardFitsBeside: Bool {
        bodySize.width - MacPromptsCard.reserve * interfaceScale >= MacPromptsCard.minimumReadingWidth * interfaceScale
    }

    private var cardOpen: Bool {
        workspace.promptsOpen[session.key] ?? (mode == .terminal || cardFitsBeside)
    }

    private var reservesCardMargin: Bool {
        cardFitsBeside && cardOpen && !prompts.isEmpty
    }

    @ViewBuilder
    private var promptsCard: some View {
        let prompts = prompts
        if !prompts.isEmpty, bodySize.width > 0 {
            MacPromptsCard(
                prompts: prompts,
                isOpen: promptsOpenBinding,
                width: promptsCardWidth,
                overContent: !cardFitsBeside,
                onTerminal: mode == .terminal,
                // Over content the whole card covers about a third of the pane.
                maxListHeight: max(120, bodySize.height * (cardFitsBeside ? 0.7 : MacPromptsCard.overContentHeightFraction) - 56),
                status: mode == .terminal ? promptStatus : nil,
                onSelect: selectPrompt,
                onJumpLatest: jumpToLatest
            )
            .interfacePadding(.top, Space.md)
            .interfacePadding(.trailing, Space.md)
        }
    }

    private func selectPrompt(_ prompt: RichMessage) {
        guard mode == .terminal else {
            workspace.scrollToPrompt(ConversationTimelineItem.message(prompt).id, in: session.key)
            return
        }
        // A second click on the row being located does not restart it.
        if promptStatus?.seq == prompt.seq, promptStatus?.kind == .locating { return }
        var generation = store?.promptHistoryGeneration ?? 0
        #if DEBUG
        // `CORRAL_INSPECTION_STALE_GENERATION=1`: model a host history rebuild.
        if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_STALE_GENERATION"] == "1" { generation -= 1 }
        #endif
        let request = TerminalPromptRequest(seq: prompt.seq, generation: generation, text: prompt.text)
        terminalPromptRequest = request
        promptStatus = TerminalPromptRowStatus(locating: request)
    }

    /// The card's last row: return this pane to its latest position without
    /// switching Chat/Terminal (owner requirement 2026-10-25).
    private func jumpToLatest() {
        workspace.scrollToLatest(in: session.key)
    }

    /// Beside the conversation the card has its full width; over content it
    /// leaves a strip of the narrow pane visible (design: Prompts card rule 3).
    private var promptsCardWidth: CGFloat {
        let full = MacPromptsCard.width * interfaceScale
        let fitting = bodySize.width - Space.md * 2 * interfaceScale
        guard !cardFitsBeside else { return min(full, fitting) }
        let partial = max(MacPromptsCard.overContentMinimumWidth * interfaceScale,
                          bodySize.width * MacPromptsCard.overContentWidthFraction)
        return min(full, partial, fitting)
    }

    /// Counted once the pane is measured, so the toggle never offers a card
    /// that cannot be placed yet.
    private var promptsCount: Int { bodySize.width > 0 ? prompts.count : 0 }

    private var promptsOpenBinding: Binding<Bool> {
        Binding(
            get: { cardOpen },
            set: { workspace.promptsOpen[session.key] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPaneHeader(
                session: session,
                isFocused: isFocused,
                allowsClose: allowsClose,
                promptsCount: promptsCount,
                promptsOpen: promptsOpenBinding
            )
            Divider()
            content
                // Beside the conversation the card takes the trailing margin and
                // either presentation shifts aside; elsewhere it floats over content.
                // Animated only when the person opens or closes the card (its
                // buttons use withAnimation). A split change that makes the card
                // stop fitting must not interpolate the reading width: that
                // reflowed every visible message on every frame of the change.
                .interfacePadding(.trailing, reservesCardMargin ? MacPromptsCard.reserve : 0)
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                // The strip behind the floating card is pane background too:
                // terminal keeps its emulator black, chat keeps grouped gray.
                .background(mode == .terminal ? Color(nsColor: TerminalAppearance.background) : Color(.systemGroupedBackground))
                .overlay(alignment: .topTrailing) { promptsCard }
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    bodySize = $0
                    workspace.paneSurfaces.existingEntry(for: session.key)?.bodySize = $0
                }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            paneFrame = frame
            // A retained hosting view has its own global coordinate space;
            // its native mount publishes the window-relative frame.
            if lifetime == nil { workspace.paneFrames[session.key] = frame }
        }
        .onAppear { prepareStore() }
        .expiringPromptStatus($promptStatus)
        .onChange(of: mode, initial: true) { _, current in
            if current == .terminal && !terminalVisited { terminalVisited = true }
            if current == .chat && !chatVisited { chatVisited = true }
        }
        #if DEBUG
        .onChange(of: prompts.count, initial: true) { _, _ in
            MacInteractionInspectionPrompts.shared[session.key] = prompts
        }
        .task { await MacPromptJumpInspection.run(key: session.key, workspace: workspace) { prompts } }
        .task { await MacCopyInspection.run(key: session.key, workspace: workspace) }
        .task(id: prompts.count) {
            MacPromptStatusInspection.start(key: session.key, mode: mode, prompts: { prompts },
                                            select: selectPrompt, status: { promptStatus })
        }
        .task { await MacTerminalReturnInspection.inspectColdChatIfRequested(appModel: appModel) }
        .task { await MacSelectionDragInspection.run(key: session.key, workspace: workspace) }
        .task(id: store.map(ObjectIdentifier.init)) {
            MacTerminalPromptInspection.start(session: session, store: store, workspace: workspace)
        }
        #endif
        .background {
            MacPaneConnection(sessionKey: session.key, lifetime: lifetime, store: store,
                              prepareStore: { prepareStore() }, resetStore: { store = nil }) {
                workspace.paneFrames[session.key] =
                    workspace.paneSurfaces.existingEntry(for: session.key)?.lastFrame ?? paneFrame
                metadataStore?.markReadLocally(key: session.key)
            }
        }
        .onAppear { metadataStore?.markReadLocally(key: session.key) }
        .onDisappear {
            guard lifetime == nil else { return }
            workspace.paneFrames[session.key] = nil
            let owned = store
            let ticket = visibilitySerial
            let key = session.key
            Task { @MainActor in
                // A reappearance bumps the serial in prepareStore(); skip the
                // stop so it cannot land after the new start(). The key check
                // covers a fresh view instance (new @State) reopening the same
                // retained store while this task was in flight.
                guard ticket == visibilitySerial,
                      !workspace.paneKeys.contains(key) else { return }
                await owned?.stop()
            }
        }
    }

    /// The terminal sits beneath the chat at a fixed position once visited, so
    /// its native emulator keeps its screen while chat is shown. It hides
    /// itself natively; SwiftUI visibility modifiers here would re-insert the
    /// AppKit view and force a synchronous window layout on every switch.
    @ViewBuilder
    private var content: some View {
        ZStack {
            if mode == .terminal || terminalVisited {
                MacTerminalPane(
                    session: session,
                    isFocused: isFocused && mode == .terminal,
                    isPresented: mode == .terminal && (lifetime?.isPresented ?? true),
                    promptRequest: terminalPromptRequest,
                    latestRequest: workspace.latestScrollRequests[session.key] ?? 0,
                    onPromptOutcome: { request, outcome in
                        promptStatus = promptStatus?.finishing(request, with: outcome)
                    }
                )
                .environment(\.conversationScrollReadAction, acknowledgeTerminalScrollRead)
                .id(session.key)
            }
            if mode == .chat || chatVisited {
                if let store {
                    MacChatSurface(isPresented: mode == .chat) {
                        SessionDetailView(
                            session: session,
                            autoFocusComposer: autoFocusComposer,
                            metadataStore: metadataStore,
                            injectedStore: store,
                            composerFocusRequest: workspace.composerFocusRequest(for: session.key),
                            onComposerFocusChange: { focused in
                                if focused { workspace.composerDidGainFocus(session.key) }
                            },
                            scrollRequest: workspace.scrollRequests[session.key],
                            externalScrollToLatestRequest: workspace.latestScrollRequests[session.key] ?? 0,
                            onDidCreateSession: { created in workspace.openCreated(created, asPane: true) }
                        )
                        .environment(\.macConversationTextDocument, workspace.paneSurfaces.entry(for: session.key).textDocument())
                        .id(ObjectIdentifier(store))
                        .environment(\.composerRecedes, composerRecedes)
                        .animation(MacMotion.state, value: composerRecedes)
                    }
                } else {
                    ProgressView().interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func acknowledgeTerminalScrollRead() {
        guard let store, metadataStore?.markReadLocally(key: session.key) == true else { return }
        Task { await store.markRead() }
    }

    @discardableResult
    private func prepareStore() -> ConversationStore? {
        visibilitySerial &+= 1
        if let store {
            lifetime?.bind(store)
            #if DEBUG
            if MacSessionSwitchInspection.enabled {
                MacSessionSwitchInspection.stores[session.key] = store
                if MacSessionSwitchInspection.preparationMs[session.key] == nil {
                    MacSessionSwitchInspection.preparationMs[session.key] = 0
                }
            }
            #endif
            return store
        }
        #if DEBUG
        let preparationStart = ContinuousClock.now
        #endif
        let entry = workspace.paneSurfaces.entry(for: session.key)
        let currentIdentity = appModel.client.map(ObjectIdentifier.init)
        // Rebuilds reuse the retained conversation when it still belongs to
        // the current connection; a replaced client gets a fresh store so the
        // pane resubscribes instead of idling on a dead connection.
        if let retained = entry.store,
           retained.clientIdentity == currentIdentity || appModel.client == nil {
            store = retained
            lifetime?.bind(retained)
            #if DEBUG
            if MacSessionSwitchInspection.enabled {
                MacSessionSwitchInspection.stores[session.key] = retained
                if MacSessionSwitchInspection.preparationMs[session.key] == nil {
                    MacSessionSwitchInspection.preparationMs[session.key] = 0
                }
            }
            #endif
            return retained
        }
        let hostID = appModel.selectedHost?.hostID ?? appModel.connectedHostID ?? ""
        let created = ConversationStore(
            sessionKey: session.key,
            client: appModel.client,
            live: session.live,
            attention: session.attention,
            hostID: hostID
        )
        if let metadataStore {
            created.onSessionMetadata = { summary, revision in
                metadataStore.applySessionEvent(summary, revision: revision)
            }
        }
        store = created
        entry.store = created
        lifetime?.bind(created)
        #if DEBUG
        if MacSessionSwitchInspection.enabled {
            MacSessionSwitchInspection.stores[session.key] = created
            MacSessionSwitchInspection.preparationMs[session.key] = MacSessionSwitchInspection.milliseconds(
                preparationStart.duration(to: .now)
            )
        }
        #endif
        return created
    }
}

/// Pane header, single pane or split: the title toggles the session's Your
/// prompts card, then its attention dots; the kebab (session menu) and Close
/// show while the pointer is over the header. Focus is the header's surface, never a ring or a tint
/// on the reading area (design: Window top bar, owner correction 2026-10-18).
struct MacPaneHeader: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let session: SessionSummary
    let isFocused: Bool
    var allowsClose = true
    var promptsCount = 0
    @Binding var promptsOpen: Bool

    @State private var runtimes: [RuntimeEntry] = []
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                // Keep the existing title reading edge; the grip shares the blank space.
                titleButton
                    .layoutPriority(1)
                projectLabel
                if let phase = appModel.restarts.phase(for: session.key) {
                    SessionRestartStatusLabel(phase: phase, font: .system(size: 12), compact: true)
                        .interfacePadding(.leading, 8)
                        .fixedSize()
                } else {
                    statusDotsView
                }
                Spacer(minLength: Space.sm)
                MacPaneDragGrip()
            }
            .modifier(MacPaneDragSource(key: session.key))
            // Hover-only (owner correction 2026-10-18); the slots keep their
            // width so the title never reflows when they appear.
            HStack(spacing: 0) {
                sessionMenu
                if allowsClose {
                    closeButton
                        .interfacePadding(.leading, Space.xs)
                }
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .interfacePadding(.horizontal, Space.md)
        .interfaceFrame(minHeight: 40)
        .modifier(MacPaneDropTarget(key: session.key))
        .background(headerSurface)
        .animation(MacMotion.state, value: isFocused)
        .animation(MacMotion.state, value: hovering)
        .animation(MacMotion.state, value: SessionPresentation.activityMarker(for: session))
        .animation(MacMotion.state, value: SessionPresentation.hasUnread(for: session))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { focusPane() }
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .task { await loadRuntimes() }
    }

    /// The title opens and closes Your prompts; the chevron shows the card's
    /// state and appears only when the session has prompts.
    private var titleButton: some View {
        Button {
            focusPane()
            if promptsCount > 0 { promptsBinding.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5 * interfaceScale) {
                Text(verbatim: SessionPresentation.displayTitle(for: session))
                    .interfaceFont(.system(size: 15, weight: isFocused ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if promptsCount > 0 {
                    Image(systemName: promptsOpen ? "chevron.up" : "chevron.down")
                        .interfaceFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isFocused ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: titleHelp))
        .accessibilityLabel(Text(verbatim: SessionPresentation.displayTitle(for: session)))
        .accessibilityValue(promptsCount > 0 ? Text("mac.prompts.title \(promptsCount)") : Text(verbatim: ""))
        .accessibilityAddTraits(promptsOpen && promptsCount > 0 ? .isSelected : [])
    }

    /// The project names the pane among splits; it shortens before the title
    /// (owner report 2026-10-20).
    @ViewBuilder
    private var projectLabel: some View {
        let project = SessionPresentation.projectName(from: session)
        if !project.isEmpty {
            Text(verbatim: project)
                .interfaceFont(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .interfacePadding(.leading, 8)
                .accessibilityLabel(Text(verbatim: project))
        }
    }

    /// Kebab: the system ellipsis turned upright (no vertical variant ships).
    private var sessionMenu: some View {
        Menu {
            MacSessionMenuItems(session: session, runtimes: runtimes, mode: modeBinding,
                                onClose: { workspace.requestClose(session.key) })
        } label: {
            Image(systemName: "ellipsis")
                .interfaceFont(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Color.secondary)
                .interfaceFrame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("session.actions.menu"))
        .accessibilityLabel(Text("session.actions.menu"))
        .accessibilityIdentifier("corral.session.actions")
    }

    private func focusPane() {
        workspace.focus(session.key)
        workspace.requestKeyFocus(session.key)
    }

    /// Attention dots follow the title text, so the title itself never moves.
    @ViewBuilder
    private var statusDotsView: some View {
        let dots = statusDots
        if !dots.isEmpty {
            HStack(spacing: 4 * interfaceScale) {
                ForEach(dots.indices, id: \.self) { index in
                    Circle()
                        .fill(dots[index])
                        .interfaceFrame(width: 7, height: 7)
                        .transition(.opacity)
                }
            }
            .interfacePadding(.leading, 6)
            .accessibilityHidden(true)
        }
    }

    /// Focus takes the brighter surface in both appearances: white over the
    /// grouped gray in light, the raised gray over the page in dark.
    private var headerSurface: Color {
        let page = Color(.systemGroupedBackground)
        let raised = Color(.secondarySystemGroupedBackground)
        if colorScheme == .dark {
            return isFocused ? raised : page
        }
        return isFocused ? page : raised
    }

    private var modeBinding: Binding<MacWorkspace.PaneMode> {
        Binding(
            get: { workspace.mode(for: session.key) },
            set: { mode in
                workspace.setMode(mode, for: session.key)
                workspace.focus(session.key)
                workspace.requestKeyFocus(session.key)
            }
        )
    }

    private var titleHelp: String {
        let title = SessionPresentation.displayTitle(for: session)
        let agent = Palette.runtimeDisplayName(session.runtime)
        let project = SessionPresentation.projectName(from: session)
        let path = SessionPresentation.fullWorkspacePath(from: session)
        var lines = [title]
        let identity = [agent, project].filter { !$0.isEmpty }.joined(separator: " · ")
        if !identity.isEmpty { lines.append(identity) }
        if !path.isEmpty { lines.append(path) }
        return lines.joined(separator: "\n")
    }

    private var closeButton: some View {
        Button {
            workspace.closePane(session.key)
        } label: {
            Image(systemName: "xmark")
                .interfaceFont(.system(size: 11, weight: .semibold))
                .interfaceFrame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.secondary)
        .help(Text("mac.pane.close"))
        .accessibilityLabel(Text("mac.pane.close"))
    }

    /// The prompt card's collapsed home is the session menu; opening or
    /// closing it keeps the card's disclosure animation.
    private var promptsBinding: Binding<Bool> {
        Binding(
            get: { promptsOpen },
            set: { open in
                withAnimation(MacMotion.disclosure(reduceMotion: reduceMotion)) { promptsOpen = open }
            }
        )
    }

    /// Activity dot first, then the independent red unread overlay.
    private var statusDots: [Color] {
        var dots: [Color] = []
        if let activity = SessionPresentation.activityMarker(for: session) {
            dots.append(markerColor(activity))
        }
        if SessionPresentation.hasUnread(for: session) {
            dots.append(markerColor(.unread))
        }
        return dots
    }

    private func markerColor(_ marker: SessionPresentation.StatusMarker) -> Color {
        switch marker {
        case .waiting: Palette.attentionWaiting
        case .working, .recent: Palette.attentionWorking
        case .unread: Palette.attentionUnread
        }
    }

    private func loadRuntimes() async {
        // The workspace already loads the runtime list once per connection;
        // per-pane fetch is only a fallback for headers mounted before it.
        if !workspace.runtimes.isEmpty {
            runtimes = workspace.runtimes
            return
        }
        guard runtimes.isEmpty, let client = appModel.client,
              let data = try? await client.call(WireProtocol.mRuntimesList) as? [String: Any],
              let items = data["runtimes"] as? [[String: Any]] else { return }
        runtimes = items.compactMap { try? RemoteJSONDecoder.decode(RuntimeEntry.self, from: $0) }.filter(\.isActive)
    }
}

extension EnvironmentValues {
    /// Session keys of the panes currently on screen (split or board page).
    @Entry var macVisiblePaneKeys: [String] = []
    /// Sidebar minute clock, ticked once per minute by the sidebar itself so
    /// a hundred rows do not run a hundred per-minute timers.
    @Entry var sidebarNow: Date = Date()
}

/// Identity of the connection a pane's subscriptions belong to.
struct PaneConnectionKey: Hashable {
    let sessionKey: String
    let client: ObjectIdentifier?
    let ready: Bool
}

extension ConversationStore {
    var clientIdentity: ObjectIdentifier? { boundClient.map(ObjectIdentifier.init) }
}

/// Keep subscription observation outside the expensive conversation layout.
private struct MacPaneConnection: View {
    @Environment(AppModel.self) private var appModel
    let sessionKey: String
    let lifetime: MacPaneLifetime?
    let store: ConversationStore?
    let prepareStore: () -> ConversationStore?
    let resetStore: () -> Void
    let onPresented: () -> Void

    private var isReady: Bool { appModel.connectionState == .connected && appModel.client != nil }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: PaneConnectionKey(sessionKey: sessionKey, client: appModel.clientIdentity,
                                        ready: isReady && (lifetime?.isPresented ?? true))) {
                guard isReady, lifetime?.isPresented ?? true else { return }
                await lifetime?.waitForSuspension()
                guard !Task.isCancelled, lifetime?.isPresented ?? true else { return }
                if let store, store.clientIdentity != appModel.clientIdentity {
                    await store.stop()
                    resetStore()
                }
                guard let owned = prepareStore() else { return }
                async let readMark: Void = owned.markRead()
                await owned.start()
                for attempt in 1...4 where owned.loadError != nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                    await owned.retry()
                }
                await readMark
            }
            .onChange(of: lifetime?.isPresented) { _, presented in
                if presented == true { onPresented() }
            }
    }
}


/// Retain the chat's native table, row hosts, selection and composer while the
/// terminal is presented. Reuses MacPaneSurface's native hiding/deferred-layout
/// boundary; SwiftUI visibility modifiers would remount its native children.
private struct MacChatSurface<Content: View>: NSViewRepresentable {
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.macPaneLifetime) private var lifetime
    var isPresented: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> MacPaneHostingView {
        let view = MacPaneHostingView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MacPaneHostingView, context: Context) {
        if !isPresented, let responder = view.window?.firstResponder as? NSView,
           responder.isDescendant(of: view) {
            view.window?.makeFirstResponder(nil)
        }
        view.isHidden = !isPresented
        guard isPresented else { return }
        let env = context.environment
        view.rootView = AnyView(content()
            .environment(appModel)
            .environment(workspace)
            .environment(\.macPaneLifetime, lifetime)
            .environment(\.interfaceScale, env.interfaceScale)
            .environment(\.colorScheme, env.colorScheme)
            .environment(\.locale, env.locale)
            .environment(\.calendar, env.calendar)
            .environment(\.timeZone, env.timeZone)
            .environment(\.layoutDirection, env.layoutDirection)
            .environment(\.font, env.font)
            .environment(\.controlSize, env.controlSize)
            .environment(\.dynamicTypeSize, env.dynamicTypeSize))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacPaneHostingView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}
