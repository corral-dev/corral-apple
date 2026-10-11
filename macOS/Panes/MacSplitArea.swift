import SwiftUI

/// Right side of the window: the split panes (a TUI session group when two or
/// more), or the Active sessions board. Panes share the width equally, as in
/// the TUI's split (no draggable dividers).
struct MacSplitArea: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(MacWorkspace.self) private var workspace
    let feed: HostSessionFeed
    var autoFocusKey: String?

    /// Width of the floating sidebar the first pane extends under (macOS 26).
    @State private var sidebarInset: CGFloat = 0

    var body: some View {
        // Closed panes stay drawn in their slots while they fade out. Terminal
        // panes (`shell:` keys) sit in the split like session panes.
        let keys = workspace.drawnPaneKeys.filter {
            ProjectShell.isShellKey($0) || feed.listStore.session(for: $0) != nil
        }
        MacRetainedPanes(keys: keys, feed: feed, autoFocusKey: autoFocusKey)
            .id(workspace.hostID)
        .environment(\.macVisiblePaneKeys, keys.filter { workspace.leavingPanes[$0] == nil })
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { sidebarInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { workspace.splitWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { workspace.splitHeight = $0 }
        .preference(key: WindowMinimumWidthKey.self, value: Self.requiredWidth(panes: keys.count, sidebar: sidebarInset))
    }

    nonisolated static let paneMinimum: CGFloat = 220

    /// The window must hold the sidebar plus every pane at its minimum; a
    /// narrower window would push the split out of both window edges.
    static func requiredWidth(panes: Int, sidebar: CGFloat) -> CGFloat {
        guard panes > 0 else { return 0 }
        return sidebar + CGFloat(panes) * paneMinimum + CGFloat(panes - 1)
    }
}

/// Keep at most four dormant native hosts at their last measured geometry.
/// Hidden hosts keep reading/composer state, suspend watches and never own
/// focus or hit targets. Eviction releases their data and hosting roots.
private struct MacRetainedPanes: View {
    @Environment(MacWorkspace.self) private var workspace
    let keys: [String]
    let feed: HostSessionFeed
    var allowsClose = true
    var autoFocusKey: String?
    @State private var recent: [String] = []

    var body: some View {
        let roster = workspace.paneSurfaces.retainedKeys(visible: keys, previous: recent) {
            !ProjectShell.isShellKey($0) && feed.listStore.session(for: $0) != nil
                && workspace.mode(for: $0) == .chat
        }
        MacRetainedPaneLayout(visibleKeys: keys) {
            ForEach(roster, id: \.self) { key in
                let visible = keys.contains(key)
                HStack(spacing: 0) {
                    Divider().frame(width: (keys.firstIndex(of: key) ?? 0) > 0 ? 1 : 0)
                    Group {
                        if ProjectShell.isShellKey(key) {
                            MacShellPane(shellKey: key)
                        } else if let session = feed.listStore.session(for: key) {
                            MacPaneSurface(session: session, metadataStore: feed.listStore,
                                           allowsClose: allowsClose, autoFocusComposer: autoFocusKey == key,
                                           isPresented: visible)
                        }
                    }
                    .modifier(PaneEntrance(key: key, direction: workspace.pendingEntrances[key]))
                }
                .modifier(PaneSlot(shift: workspace.paneShifts[key] ?? 0,
                                   leaving: workspace.leavingPanes[key] != nil))
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
                .layoutValue(key: MacRetainedPaneKey.self, value: key)
            }
        }
        .onChange(of: keys, initial: true) { _, _ in
            let retained = workspace.paneSurfaces.retainedKeys(visible: keys, previous: recent) {
                !ProjectShell.isShellKey($0) && feed.listStore.session(for: $0) != nil
                    && workspace.mode(for: $0) == .chat
            }
            for key in recent where !retained.contains(key) {
                workspace.paneSurfaces.evict(key)
            }
            recent = retained
        }
    }
}

nonisolated private struct MacRetainedPaneKey: LayoutValueKey {
    static let defaultValue = ""
}

/// Delegate visible placement to the existing equal-slot layout. Hidden
/// children remain at their last proposal without contributing to its width.
private struct MacRetainedPaneLayout: Layout {
    let visibleKeys: [String]
    struct Cache { var sizes: [String: CGSize] = [:] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let keys = Set(subviews.map { $0[MacRetainedPaneKey.self] })
        cache.sizes = cache.sizes.filter { keys.contains($0.key) }
    }
    private var equal: EqualPaneLayout { EqualPaneLayout(minimumWidth: MacSplitArea.paneMinimum) }

    private func visibleIndices(_ subviews: Subviews) -> [Int] {
        visibleKeys.compactMap { key in subviews.indices.first { subviews[$0][MacRetainedPaneKey.self] == key } }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        var empty: Void = ()
        return equal.sizeThatFits(proposal: proposal, subviews: subviews[visibleIndices(subviews)], cache: &empty)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let indices = visibleIndices(subviews)
        var empty: Void = ()
        equal.placeSubviews(in: bounds, proposal: proposal, subviews: subviews[indices], cache: &empty)
        let count = indices.count
        if count > 0 {
            let paneWidth = max(0, (bounds.width - CGFloat(count - 1)) / CGFloat(count))
            for (slot, index) in indices.enumerated() {
                cache.sizes[subviews[index][MacRetainedPaneKey.self]] = CGSize(
                    width: paneWidth + (slot > 0 ? 1 : 0), height: bounds.height)
            }
        }
        let liveKeys = Set(subviews.map { $0[MacRetainedPaneKey.self] })
        cache.sizes = cache.sizes.filter { liveKeys.contains($0.key) }
        for index in subviews.indices where !indices.contains(index) {
            let key = subviews[index][MacRetainedPaneKey.self]
            let size = cache.sizes[key] ?? bounds.size
            subviews[index].place(at: bounds.origin, anchor: .topLeading,
                                 proposal: ProposedViewSize(size))
        }
    }
}

/// Minimum window width requested by the split (largest wins); the window
/// grows to it when a pane is added and cannot be dragged narrower.
struct WindowMinimumWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The TUI's Active sessions board: hosted sessions that wait, work, are
/// unread or were active just now, four at a time with cyclic paging. Panes
/// here are live and accept input but cannot be closed (board semantics).
struct MacActiveBoard: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(MacWorkspace.self) private var workspace
    let feed: HostSessionFeed
    @State private var sidebarInset: CGFloat = 0

    var body: some View {
        let active = DesktopSidebarProjection.activeSessions(feed.listStore.windowSessions)
        let pages = workspace.boardPages(active: active)
        let page = min(workspace.boardPage, pages - 1)
        let shown = Array(active.dropFirst(page * MacWorkspace.boardPageSize).prefix(MacWorkspace.boardPageSize))
        VStack(spacing: 0) {
            HStack(spacing: Space.md * interfaceScale) {
                Label("mac.board.title \(active.count)", systemImage: "rectangle.split.2x2")
                    .interfaceFont(.body.weight(.semibold))
                Spacer()
                if pages > 1 {
                    Button {
                        workspace.turnBoardPage(by: -1, active: active)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .help(Text("mac.board.previous"))
                    Text(verbatim: "\(page + 1)/\(pages)")
                        .interfaceFont(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        workspace.turnBoardPage(by: 1, active: active)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .keyboardShortcut("]", modifiers: .command)
                    .help(Text("mac.board.next"))
                }
            }
            .buttonStyle(.borderless)
            .interfacePadding(.horizontal, Space.md)
            .interfacePadding(.vertical, Space.sm)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView("mac.board.empty", systemImage: "rectangle.split.2x2")
                    .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacRetainedPanes(keys: shown.map(\.key), feed: feed, allowsClose: false)
                    .id(workspace.hostID)
                .environment(\.macVisiblePaneKeys, shown.map(\.key))
                .clipped()
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { sidebarInset = $0 }
                .preference(
                    key: WindowMinimumWidthKey.self,
                    value: MacSplitArea.requiredWidth(panes: shown.count, sidebar: sidebarInset)
                )
            }
        }
    }
}

/// A pane's entrance (design: Motion design). The layout has already changed
/// in one step; the pane starts hidden and fades in (sliding from `direction`
/// on a board page turn) only after its first frame is committed, because
/// building a pane can block the main thread long enough to swallow an
/// animation that started with the change. Panes without a pending entrance
/// render as they are.
private struct PaneEntrance: ViewModifier {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let key: String
    let direction: Int?
    @State private var entered: Bool

    init(key: String, direction: Int?) {
        self.key = key
        self.direction = direction
        // Decided once, when the pane is created.
        _entered = State(initialValue: direction == nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(entered ? 1 : 0)
            .visualEffect { [entered, reduceMotion, direction, pageOffset = MacMotion.pageOffset] effect, _ in
                effect.offset(x: entered || reduceMotion ? 0 : CGFloat(direction ?? 0) * pageOffset)
            }
            .task {
                guard !entered else { return }
                // Let the first frame (and any build stall) pass before moving.
                try? await Task.sleep(for: .milliseconds(16))
                withAnimation(MacMotion.paneEntrance(sliding: (direction ?? 0) != 0, reduceMotion: reduceMotion)) {
                    entered = true
                }
                workspace.clearEntrance(key)
            }
    }
}

extension ContainerValues {
    /// Session key of a split pane, so the split can move and fade it.
    @Entry var macPaneKey: String?
}

/// Equal-width panes separated by hairlines. Plain layout instead of an
/// AppKit split view: under the floating sidebar a split view kept stale pane
/// widths and pushed the whole window content past both edges. Each pane
/// carries the hairline before it, so the line travels and fades with it.
struct EqualPanes<Content: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(MacWorkspace.self) private var workspace
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { panes in
            EqualPaneLayout(minimumWidth: MacSplitArea.paneMinimum) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    let key = pane.containerValues.macPaneKey
                    HStack(spacing: 0) {
                        if index > 0 {
                            Divider()
                        }
                        pane.frame(minWidth: MacSplitArea.paneMinimum, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .modifier(PaneSlot(
                        shift: key.flatMap { workspace.paneShifts[$0] } ?? 0,
                        leaving: key.map { workspace.leavingPanes[$0] != nil } ?? false
                    ))
                }
            }
        }
    }
}

/// Split motion of one pane (design: Motion design, round 2): drawn offset
/// from its slot while it glides home (the workspace animates the offset; the
/// frame never interpolates), and faded out, inert, while it is closing.
private struct PaneSlot: ViewModifier {
    @Environment(\.interfaceScale) private var interfaceScale
    let shift: CGFloat
    let leaving: Bool

    func body(content: Content) -> some View {
        content
            // A visual effect, not `.offset`: the pane's geometry stays in its
            // slot while it travels, so a conversation's lazy stack does not
            // re-place its rows on every frame of the glide (measured
            // 2026-10-07: that was most of the stall when adding or closing a
            // pane beside a long conversation).
            .visualEffect { effect, _ in effect.offset(x: shift) }
            .opacity(leaving ? 0 : 1)
            .animation(MacMotion.paneExit, value: leaving)
            .allowsHitTesting(!leaving)
            .accessibilityHidden(leaving)
    }
}
