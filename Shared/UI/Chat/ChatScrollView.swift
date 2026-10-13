import SwiftUI

/// Scoped to the rendered conversation so list/composer scrolling cannot read it.
private struct ConversationScrollReadActionKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var conversationScrollReadAction: @MainActor @Sendable () -> Void {
        get { self[ConversationScrollReadActionKey.self] }
        set { self[ConversationScrollReadActionKey.self] = newValue }
    }
}

/// Automatic latest scrolling, including item anchors, requires measured overflow.
/// Short transcripts belong to native top alignment; explicitly pinning their
/// last item during asynchronous layout can leave a blank band above the bubbles.
enum ChatLatestFollowPolicy {
    static func shouldScrollToEdge(contentHeight: CGFloat, containerHeight: CGFloat) -> Bool {
        guard containerHeight > 0,
              contentHeight > 0,
              contentHeight.isFinite, containerHeight.isFinite else { return false }
        return contentHeight - containerHeight > 1
    }
}

/// Reading toward the oldest loaded message fetches the next older page by itself
/// (owner requirement 2026-10-06), so nobody has to tap Load earlier.
enum ChatAutoLoadEarlierPolicy {
    static func shouldLoad(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        distanceFromTop: CGFloat,
        userHasScrolled: Bool
    ) -> Bool {
        guard containerHeight > 0, contentHeight > 0 else { return false }
        // A window shorter than the screen cannot be scrolled: fill it right away.
        guard ChatLatestFollowPolicy.shouldScrollToEdge(
            contentHeight: contentHeight,
            containerHeight: containerHeight
        ) else { return true }
        // The initial landing passes the top before the bottom anchor settles;
        // only the reader's own scroll counts.
        return userHasScrolled && distanceFromTop < containerHeight
    }

    /// Topmost timeline row among visible scroll targets ("message-<seq>",
    /// "tools-<seq>"); the anchor that keeps reading position across a prepend.
    static func topmostTimelineID(_ ids: [String]) -> String? {
        ids.compactMap { id -> (Int, String)? in
            guard let dash = id.lastIndex(of: "-"),
                  let seq = Int(id[id.index(after: dash)...]), seq > 0 else { return nil }
            return (seq, id)
        }
        .min { $0.0 < $1.0 }?.1
    }
}

/// Owns reading position only. Keyboard avoidance belongs to SwiftUI's safe area.
///
/// WeChat-style top alignment (user ruling 2026-09-14): short transcripts rest
/// at the top and the empty space stays below them. Entering a long transcript
/// still lands on the latest messages via the initial bottom offset; size
/// changes keep following the bottom only while the user reads the latest.
/// The header always leads the scroll content — no viewport overlay, since the
/// empty band is below the messages now, not above them.
struct ChatScrollView<Header: View, Content: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let scrollToLatestRequest: Int
    /// Bottom-most element id ("activity" cue, else "prompts" while a questionnaire is pinned,
    /// otherwise the last timeline item). Sends scroll to this instead of the
    /// raw bottom edge so a short transcript never overshoots into blank.
    let latestID: String?
    @Binding var scrollToMessageID: String?
    /// Whether a jump from `visible` (topmost visible row) to `target` is short
    /// enough to glide; a far jump fades instead.
    var jumpGlides: ((_ target: String, _ visible: String?) -> Bool)?
    /// Nil when no older pages exist. Returns whether older messages arrived.
    /// Pulled by gesture, and loaded automatically while reading near the top.
    var onPullToLoadEarlier: (() async -> Bool)?
    /// 下拉进度回传（0..1, nil = 未触碰）：header 进度环用，拥有方传入 Binding。
    var pullProgress: Binding<Double?> = .constant(nil)
    var header: Header
    var content: Content

    init(
        scrollToLatestRequest: Int,
        latestID: String? = nil,
        scrollToMessageID: Binding<String?>,
        jumpGlides: ((_ target: String, _ visible: String?) -> Bool)? = nil,
        onPullToLoadEarlier: (() async -> Bool)? = nil,
        pullProgress: Binding<Double?> = .constant(nil),
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollToLatestRequest = scrollToLatestRequest
        self.latestID = latestID
        self._scrollToMessageID = scrollToMessageID
        self.jumpGlides = jumpGlides
        self.header = header()
        self.content = content()
        self.onPullToLoadEarlier = onPullToLoadEarlier
        self.pullProgress = pullProgress
    }

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            NativeChatScrollView(
                scrollToLatestRequest: scrollToLatestRequest,
                latestID: latestID,
                scrollToMessageID: $scrollToMessageID,
                jumpGlides: jumpGlides,
                onPullToLoadEarlier: onPullToLoadEarlier,
                pullProgress: pullProgress,
                header: header,
                content: content
            )
        } else {
            CompatibleChatScrollView(
                scrollToLatestRequest: scrollToLatestRequest,
                latestID: latestID,
                scrollToMessageID: $scrollToMessageID,
                onPullToLoadEarlier: onPullToLoadEarlier,
                pullProgress: pullProgress,
                header: header,
                content: content
            )
        }
    }
}

/// Top overscroll loads earlier history on release: pulling past the
/// threshold arms one page load, releasing fires it (guarded by the store's
/// hasMore/isLoading flags). Pulling back above the threshold before release
/// cancels. One pull loads exactly one page.
///
/// Progress reporting: the modifier reports overscroll depth through
/// `progress` (0 = untouched, 1 = release-to-load) so the header button can
/// render a filling ring without owning scroll geometry itself.
private struct ChatPullToLoadEarlier: ViewModifier {
    @Environment(\.interfaceScale) private var interfaceScale
    var load: (() async -> Bool)?
    @Binding var progress: Double?
    @State private var requested = false
    @State private var pull = ChatHistoryPullState()
    @State private var didPulse = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
                } action: { _, distance in
                    guard load != nil, !requested else { return }
                    pull.update(distance: Double(distance))
                    // Fast scrolling reports geometry every frame: only touch the
                    // owner's state when the ring value actually changes, or the
                    // whole conversation rebuilds per frame.
                    let next = pull.progress
                    if progress != next { progress = next }
                    pulseIfArmed()
                }
                .onScrollPhaseChange { oldPhase, phase, context in
                    if phase == .interacting, oldPhase != .interacting {
                        pull.begin()
                        didPulse = false
                        let distance = max(0, -(context.geometry.contentOffset.y + context.geometry.contentInsets.top))
                        pull.update(distance: Double(distance))
                        pulseIfArmed()
                    }
                    // Release precedes deceleration. Waiting for idle loses the
                    // armed state as the rubber band returns to zero.
                    if oldPhase == .interacting,
                       phase == .decelerating || phase == .idle {
                        let shouldLoad = pull.release()
                        if shouldLoad, load != nil, !requested { requested = true }
                        if progress != nil { progress = nil }
                    }
                }
                .task(id: requested) {
                    guard requested, let load else { return }
                    _ = await load()
                    requested = false
                }
                .onDisappear {
                    pull.reset()
                    requested = false
                    if progress != nil { progress = nil }
                }
        } else {
            content
        }
    }

    private func pulseIfArmed() {
        guard pull.progress == 1, !didPulse else { return }
        didPulse = true
        HapticFeedback.shared.emit(.committed)
    }
}

@available(iOS 18.0, *)
private struct NativeChatScrollView<Header: View, Content: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let scrollToLatestRequest: Int
    let latestID: String?
    @Binding var scrollToMessageID: String?
    var jumpGlides: ((_ target: String, _ visible: String?) -> Bool)?
    var onPullToLoadEarlier: (() async -> Bool)?
    var pullProgress: Binding<Double?> = .constant(nil)
    let header: Header
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationScrollReadAction) private var acknowledgeRead
    #if os(macOS)
    @Environment(\.macConversationTextDocument) private var selectionDocument
    #endif
    @State private var position = ScrollPosition(idType: String.self)
    @State private var followsLatest = true
    @State private var isUserScrolling = false
    @State private var isReadingScroll = false
    @State private var containerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var distanceFromTop: CGFloat = 0
    @State private var userHasScrolled = false
    @State private var topVisibleID: String?
    @State private var isAutoLoading = false
    /// A fetch that brought nothing waits for the next scroll gesture, never per frame.
    @State private var autoLoadHeld = false
    /// A message jump is gliding; automatic earlier loading would cut it short.
    @State private var isJumping = false
    @State private var jumpGeneration = 0
    /// The conversation is faded out while a far jump moves under it.
    @State private var isJumpFaded = false
    /// Geometry fires every frame while scrolling: read acknowledgements are
    /// throttled here (the phase change already acks the gesture start).
    /// Without this each frame sent its own mark-read RPC.
    @State private var lastReadAck = Date.distantPast

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                header
                content
            }
            .scrollTargetLayout()
            .chatReadableColumn()
            .nativeOverlayScrollers()
            .opacity(isJumpFaded ? 0 : 1)
        }
        #if os(macOS)
        // Messages pass under the window toolbar; a hard edge keeps the title legible.
        .scrollEdgeEffectStyle(.hard, for: .top)
        #endif
        .modifier(ChatPullToLoadEarlier(load: onPullToLoadEarlier, progress: pullProgress))
        .contentMargins(Space.base, for: .scrollContent)
        #if os(macOS)
        .scrollIndicators(.automatic)
        #else
        .scrollIndicators(.hidden)
        #endif
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard let view = notification.object as? NSTextView,
                  let document = selectionDocument,
                  view.layoutManager === document.layout,
                  document.layout.textContainers.compactMap(\.textView).contains(where: {
                      $0.window?.firstResponder === $0
                  }),
                  followsLatest, view.selectedRange().length > 0 else { return }
            followsLatest = false
            // Selecting is a reading interaction: release the previous explicit
            // latest-message anchor before font metrics reflow the conversation.
            position.isPositionedByUser = true
        }
        #endif
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
            let next = ChatAutoLoadEarlierPolicy.topmostTimelineID(ids)
            if topVisibleID != next { topVisibleID = next }
        }
        .onScrollPhaseChange { _, phase, context in
            let wasUserScrolling = isUserScrolling
            let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if wasUserScrolling != scrolling { isUserScrolling = scrolling }
            // Tracking is only a touch, and animating can be an automatic jump.
            let reading = phase == .interacting || phase == .decelerating
            if isReadingScroll != reading { isReadingScroll = reading }
            if phase == .interacting {
                acknowledgeRead()
                lastReadAck = Date.now
            }
            if scrolling, !wasUserScrolling {
                if !userHasScrolled { userHasScrolled = true }
                if autoLoadHeld { autoLoadHeld = false }
            }
            // Idle alone must not clear the initial follow: at open the viewport
            // briefly reports top before the bottom anchor settles, and clearing
            // here would strand a long transcript at the oldest messages.
            // User-driven phases already cover drag + momentum end state.
            if scrolling {
                let nearBottom = isNearBottom(context.geometry)
                if followsLatest != nearBottom { followsLatest = nearBottom }
            }
        }
        .onScrollGeometryChange(for: ChatScrollState.self) { geometry in
            ChatScrollState(
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height,
                nearBottom: isNearBottom(geometry),
                distanceFromTop: max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            )
        } action: { _, state in
            // Geometry fires every display frame during a fling: only promote
            // values that actually moved, or every frame rebuilds this view and
            // re-drives the pull-progress owner above it.
            if abs(containerHeight - state.containerHeight) > 0.5 { containerHeight = state.containerHeight }
            if abs(contentHeight - state.contentHeight) > 0.5 { contentHeight = state.contentHeight }
            if abs(distanceFromTop - state.distanceFromTop) > 0.5 { distanceFromTop = state.distanceFromTop }
            // A result arriving during this drag/momentum is read on its next move,
            // throttled: the gesture start already acked above.
            // The metadata store gates duplicates before any write or RPC.
            if isReadingScroll, Date.now.timeIntervalSince(lastReadAck) > 1.5 {
                lastReadAck = Date.now
                acknowledgeRead()
            }
            // Resizing for the keyboard is not a request to stop following.
            if isUserScrolling, followsLatest != state.nearBottom { followsLatest = state.nearBottom }
            loadEarlierIfReading()
        }
        .onChange(of: onPullToLoadEarlier == nil) { _, _ in
            loadEarlierIfReading()
        }
        .onChange(of: scrollToLatestRequest) { _, _ in
            showLatest()
        }
        .onAppear {
            // Explicit landing is needed for overflowing async transcripts only.
            if followsLatest {
                showLatest()
            }
        }
        .onChange(of: latestID) { _, _ in
            // Later arrivals while still following stay pinned; history reading
            // (followsLatest == false) never steals position here. Load-earlier
            // prepends keep the same latestID so they never trigger this.
            if followsLatest {
                showLatest()
            }
        }
        #if os(macOS)
        .onChange(of: contentHeight) { _, newHeight in
            // Replacing the loaded window (cached tail, then the host's newer
            // window) leaves the lazy stack at an offset computed from
            // estimated rows, with none realized there: the pane stays blank
            // until the reader scrolls. Re-anchor once the real height lands.
            guard followsLatest, !isUserScrolling, latestID != nil, newHeight > 0 else { return }
            showLatest()
        }
        #endif
        #if os(iOS)
        .onChange(of: contentHeight) { oldHeight, newHeight in
            // First layout after async mount: onAppear can run before the lazy
            // stack realizes, so re-pin once content measures. Also re-pin when a
            // top-aligned short transcript grows past the viewport (a question
            // card opening, a streaming reply): the size-change anchor keeps the
            // top offset then, leaving the newest content under the composer.
            // Only while following and not dragging, so history reading never moves.
            guard followsLatest, !isUserScrolling, latestID != nil, newHeight > 0 else { return }
            let grewPastViewport = newHeight > oldHeight
                && ChatLatestFollowPolicy.shouldScrollToEdge(
                    contentHeight: newHeight,
                    containerHeight: containerHeight
                )
            guard oldHeight == 0 || grewPastViewport else { return }
            showLatest()
        }
        .onChange(of: containerHeight) { oldHeight, newHeight in
            // A keyboard/composer resize follows latest only when content overflows.
            guard followsLatest, latestID != nil, newHeight > 0, oldHeight != newHeight else { return }
            showLatest()
        }
        #endif
        .onChange(of: scrollToMessageID) { _, messageID in
            guard let messageID else { return }
            scrollToMessageID = nil
            jump(to: messageID)
        }
        .overlay(alignment: .bottomTrailing) {
            if !followsLatest { ChatJumpToLatestButton(action: showLatest) }
        }
    }

    /// Moves to a message (Your prompts) with visible motion. A nearby target
    /// glides. A far one fades out, moves and fades back in: lazy rows far from
    /// the viewport only have estimated heights, and gliding through them
    /// flickers on the Mac (measured 2026-10-07). Reduce Motion always fades.
    private func jump(to messageID: String) {
        followsLatest = false
        // A jump to a message is reading history, like the reader's own scroll.
        userHasScrolled = true
        isJumping = true
        jumpGeneration += 1
        let generation = jumpGeneration
        let glides = !reduceMotion && (jumpGlides?(messageID, topVisibleID) ?? true)
        Task { @MainActor in
            if glides {
                withAnimation(ChatJumpMotion.glide) { position.scrollTo(id: messageID, anchor: .center) }
                // Scroll animations report completion at once, so wait out the glide.
                try? await Task.sleep(for: ChatJumpMotion.glideDuration)
            } else {
                withAnimation(ChatJumpMotion.fadeOut) { isJumpFaded = true }
                try? await Task.sleep(for: ChatJumpMotion.fadeOutDuration)
                withoutAnimation { position.scrollTo(id: messageID, anchor: .center) }
                // Let the rows around the target realize and measure.
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard generation == jumpGeneration else { return }
            // Rows measured on the way can shift the target; settle on it without motion.
            withoutAnimation { position.scrollTo(id: messageID, anchor: .center) }
            if isJumpFaded { withAnimation(ChatJumpMotion.fadeIn) { isJumpFaded = false } }
            isJumping = false
            loadEarlierIfReading()
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private func loadEarlierIfReading() {
        guard let load = onPullToLoadEarlier, !isAutoLoading, !autoLoadHeld, !isJumping,
              ChatAutoLoadEarlierPolicy.shouldLoad(
                  contentHeight: contentHeight,
                  containerHeight: containerHeight,
                  distanceFromTop: distanceFromTop,
                  userHasScrolled: userHasScrolled
              ) else { return }
        isAutoLoading = true
        // Keep the row the reader is looking at in place once older rows land above it.
        let anchor = followsLatest ? nil : topVisibleID
        Task { @MainActor in
            let loaded = await load()
            if loaded, let anchor {
                withoutAnimation { position.scrollTo(id: anchor, anchor: .top) }
            }
            if !loaded { autoLoadHeld = true }
            isAutoLoading = false
        }
    }

    private func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY <= 44
    }

    private var sizeChangeAnchor: UnitPoint? {
        guard followsLatest else { return nil }
        #if os(macOS)
        // Native anchoring owns reflow; .alignment keeps short conversations at
        // the top. Explicit scroll requests during lazy size estimation can
        // overshoot when a zoom or window resize changes the same geometry.
        return .bottom
        #else
        return ChatLatestFollowPolicy.shouldScrollToEdge(
            contentHeight: contentHeight,
            containerHeight: containerHeight
        ) ? .bottom : .top
        #endif
    }

    private func showLatest() {
        followsLatest = true
        guard ChatLatestFollowPolicy.shouldScrollToEdge(
            contentHeight: contentHeight,
            containerHeight: containerHeight
        ) else { return }
        // Once overflow is established, prefer the layout-anchored item.
        if let latestID {
            position.scrollTo(id: latestID, anchor: .bottom)
            return
        }
        position.scrollTo(edge: .bottom)
    }
}

/// iOS 17 keeps the same native safe-area ownership with its ID-based scroll API.
private struct CompatibleChatScrollView<Header: View, Content: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    private static var bottomID: String { "chat-bottom-anchor" }
    let scrollToLatestRequest: Int
    let latestID: String?
    @Binding var scrollToMessageID: String?
    var onPullToLoadEarlier: (() async -> Bool)?
    var pullProgress: Binding<Double?> = .constant(nil)
    let header: Header
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationScrollReadAction) private var acknowledgeRead
    @State private var positionID: String?
    @State private var containerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                header
                content
                Color.clear.interfaceFrame(height: 1).id(Self.bottomID)
            }
            .scrollTargetLayout()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                contentHeight = $0
                if positionID == nil { showLatest() }
            }
        }
        .modifier(ChatPullToLoadEarlier(load: onPullToLoadEarlier, progress: pullProgress))
        .contentMargins(Space.base, for: .scrollContent)
        .scrollIndicators(.hidden)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        // iOS 17 has no scroll-phase callback. Observe the vertical drag alongside
        // native scrolling, without replacing its gesture or scroll-position owner.
        .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
            guard abs(value.translation.height) > abs(value.translation.width) else { return }
            acknowledgeRead()
        })
        .defaultScrollAnchor(.top)
        .scrollPosition(id: $positionID, anchor: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            containerHeight = $0
            if positionID == nil { showLatest() }
        }
        .onChange(of: scrollToLatestRequest) { _, _ in
            showLatest()
        }
        .onChange(of: scrollToMessageID) { _, messageID in
            guard let messageID else { return }
            withAnimation(reduceMotion ? nil : ChatJumpMotion.glide) { positionID = messageID }
            scrollToMessageID = nil
        }
        .overlay(alignment: .bottomTrailing) {
            if positionID != nil, positionID != Self.bottomID {
                ChatJumpToLatestButton(action: showLatest)
            }
        }
    }

    private func showLatest() {
        guard ChatLatestFollowPolicy.shouldScrollToEdge(
            contentHeight: contentHeight,
            containerHeight: containerHeight
        ) else { return }
        positionID = latestID ?? Self.bottomID
    }
}

/// Motion of a message jump (Your prompts). Debug window captures may slow it
/// with `CORRAL_INSPECTION_MOTION_SLOWDOWN` (e.g. 10); Release never does.
private enum ChatJumpMotion {
    static let glide = Animation.smooth(duration: seconds(0.45))
    static let glideDuration = Duration.seconds(seconds(0.5))
    static let fadeOut = Animation.easeIn(duration: seconds(0.12))
    static let fadeOutDuration = Duration.seconds(seconds(0.12))
    static let fadeIn = Animation.easeOut(duration: seconds(0.22))

    private static func seconds(_ value: Double) -> Double {
        #if DEBUG
        let slowdown = Double(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_MOTION_SLOWDOWN"] ?? "") ?? 1
        return value * max(slowdown, 1)
        #else
        return value
        #endif
    }
}

/// One geometry observer feeds container/content size plus the follow flag, so the
/// ScrollView doesn't fan out into separate LazyPreference combiners per metric
/// (2026-10-01真机 AttributeGraph realloc crash during DisplayList commit).
private struct ChatScrollState: Equatable {
    var containerHeight: CGFloat
    var contentHeight: CGFloat
    var nearBottom: Bool
    var distanceFromTop: CGFloat
}

private struct ChatJumpToLatestButton: View {
    @Environment(\.interfaceScale) private var interfaceScale
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .interfaceFont(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .interfaceFrame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                .contentShape(Circle())
                .background(.bar, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text("chat.jump_to_latest"))
        .interfacePadding(.trailing, Space.base)
        .interfacePadding(.bottom, Space.sm)
    }
}
