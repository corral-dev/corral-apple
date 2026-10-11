#if os(macOS)
import SwiftUI
import AppKit

/// One row in the pooled conversation table: a timeline item or one of the
/// pinned trailing cards. Ids match ChatView's scroll targets exactly, so
/// jumps, follow-latest and reading position keep their semantics.
enum MacPooledRow: Equatable, Identifiable {
    case timeline(ConversationTimelineItem)
    case prompts
    case activity

    var id: String {
        switch self {
        case .timeline(let item): item.id
        case .prompts: "prompts"
        case .activity: "activity"
        }
    }
}

/// Pooled AppKit table for one Mac conversation.
///
/// SwiftUI models exactly one view (this representable) instead of one node
/// per message, so switching cost no longer scales with history length.
/// `NSTableView` reuses a bounded pool of cells for the visible rows; each
/// cell hosts the same SwiftUI row UI (`MessageBubbleView`, `ToolActivityView`
/// and friends) with the shared `MacConversationTextDocument` network, so
/// selection, links, copy, zoom and reflow behave like the lazy-stack path.
/// Off-screen rows have no views at all.
///
/// Heights: rows never seen at the current geometry use a text-measured
/// estimate; every displayed row is measured from its own hosted content and
/// corrected after the delegate returns, keeping the reader's position (the
/// latest edge while following, otherwise the first visible row).
///
/// iOS keeps the `ChatScrollView` path; this component is Mac-only.
struct MacPooledConversationList: NSViewRepresentable {
    var rows: [MacPooledRow]
    var separators: [String: Date]
    var gaps: [String: CGFloat]
    var prompts: [SessionPrompt]
    var activity: ChatActivityState?
    var runtimeID: String? = nil
    var isConnected = true
    var isSending = false
    var questionSubmissionState: NativeQuestionSubmissionState? = nil
    var onQuestionSubmit: ((String, [NativeQuestionAnswer]) -> Void)? = nil
    var onRetryMessage: ((RichMessage) -> Void)? = nil
    var onNeedDetails: (([Int]) async -> [ToolCall]?)? = nil
    var detailSourceID: ObjectIdentifier? = nil
    var interfaceScale: CGFloat = 1
    var sessionTextScale: CGFloat = SessionTextSize.default.scale
    var colorScheme: ColorScheme = .light
    var document: MacConversationTextDocument? = nil
    /// History paging: called when the reader reaches the top.
    var onNeedEarlier: (() async -> Bool)? = nil
    /// Programmatic jumps (Your prompts): consumed (set to nil) on delivery.
    var scrollToMessageID: Binding<String?> = .constant(nil)
    /// External latest requests (sends, question submits): bump to re-pin.
    var scrollToLatestRequest = 0
    /// Reading-follow reports for the caller's jump-to-latest button.
    var onFollowChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.configure(self)
        let scroll = PooledScrollView()
        scroll.onUserScroll = { [weak coordinator] in coordinator?.noteUserScroll() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let table = PooledConversationTable()
        table.coordinator = coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.selectionHighlightStyle = .none
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.refusesFirstResponder = true
        table.focusRingType = .none
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        // The default (inset) style pads every cell by 16 points on each side;
        // the readable column owns the margins, so cells span the full width.
        table.style = .fullWidth
        // Automatic heights measure cells without a settled width and stick;
        // the coordinator measures displayed rows explicitly instead.
        table.usesAutomaticRowHeights = false
        table.rowHeight = 44
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        scroll.documentView = table
        coordinator.observeScroll(of: scroll)
        coordinator.mount()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? PooledConversationTable,
              table.coordinator != nil else { return }
        context.coordinator.configure(self)
        context.coordinator.syncRows()
        context.coordinator.consumeScrollIntents(
            scrollToMessageID: scrollToMessageID,
            scrollToLatestRequest: scrollToLatestRequest
        )
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown(scroll: scroll)
    }

    /// Bounded reusable cell shell. Content is a hosted SwiftUI row rebuilt
    /// from the current item on every display; the native text views inside
    /// stay owned by the shared conversation document.
    final class PooledRowCell: NSView {
        static let identifier = NSUserInterfaceItemIdentifier("MacPooledRowCell")
        private var hosting: NSHostingController<AnyView>?

        func setRoot(_ root: AnyView) {
            if let hosting {
                hosting.rootView = root
            } else {
                let created = NSHostingController(rootView: root)
                // The table owns the row height; the hosted view only fills it.
                created.sizingOptions = []
                created.view.frame = bounds
                created.view.autoresizingMask = [.width, .height]
                addSubview(created.view)
                hosting = created
            }
        }

        /// Height the hosted row needs at `width`, from SwiftUI layout itself
        /// (the text representables answer through their measurement path).
        func fittingHeight(width: CGFloat) -> CGFloat? {
            guard let hosting else { return nil }
            let size = hosting.sizeThatFits(in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            guard size.height.isFinite, size.height > 0, size.height < 1_000_000 else { return nil }
            return ceil(size.height)
        }

        override func layout() {
            super.layout()
            hosting?.view.frame = bounds
        }
    }

    /// Plain single-column table; all behavior lives in the coordinator so
    /// the view stays free of product logic.
    final class PooledConversationTable: NSTableView {
        weak var coordinator: Coordinator?

        /// Rows measured while this pass realized them get their corrected
        /// heights before the pass ends, so a clipped frame is never drawn.
        /// This runs after the delegate callbacks, so it is not reentrant.
        override func layout() {
            super.layout()
            if coordinator?.applyPendingHeights() == true {
                super.layout()
            }
        }
    }

    /// Reports reader-initiated scrolling (wheel, trackpad, scroller drag) so
    /// programmatic pins and layout clamps never count as reading history.
    final class PooledScrollView: NSScrollView {
        var onUserScroll: (() -> Void)?

        override func scrollWheel(with event: NSEvent) {
            onUserScroll?()
            super.scrollWheel(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// Everything a row renders besides its own item. A change re-renders
        /// the visible rows; geometry inputs also invalidate measured heights.
        private struct RenderContext: Equatable {
            var runtimeID: String?
            var interfaceScale: CGFloat
            var sessionTextScale: CGFloat
            var colorScheme: ColorScheme
            var document: ObjectIdentifier?
        }

        /// Inputs of the trailing cards, whose row ids never change.
        private struct TrailingContext: Equatable {
            var prompts: [SessionPrompt]
            var activity: ChatActivityState?
            var isConnected: Bool
            var isSending: Bool
            var questionSubmissionState: NativeQuestionSubmissionState?
        }

        /// Geometry a height was resolved for.
        private struct Geometry: Equatable {
            var width: CGFloat
            var interfaceScale: CGFloat
            var sessionTextScale: CGFloat
            var document: ObjectIdentifier?
        }

        private struct HeightEntry {
            var geometry: Geometry
            var height: CGFloat
            var measured: Bool
        }

        /// A reading position: a row and its top edge relative to the viewport.
        private struct Anchor {
            var id: String
            var offset: CGFloat
        }

        weak var table: PooledConversationTable?
        private var rows: [MacPooledRow] = []
        private var lastRows: [MacPooledRow] = []
        private var lastSeparators: [String: Date] = [:]
        private var lastGaps: [String: CGFloat] = [:]
        private var lastDetailSourceID: ObjectIdentifier?
        private var lastRender: RenderContext?
        private var lastTrailing: TrailingContext?
        private var separators: [String: Date] = [:]
        private var gaps: [String: CGFloat] = [:]
        private var prompts: [SessionPrompt] = []
        private var activity: ChatActivityState?
        private var runtimeID: String?
        private var isConnected = true
        private var isSending = false
        private var questionSubmissionState: NativeQuestionSubmissionState?
        private var onQuestionSubmit: ((String, [NativeQuestionAnswer]) -> Void)?
        private var onRetryMessage: ((RichMessage) -> Void)?
        private var onNeedDetails: (([Int]) async -> [ToolCall]?)?
        private var detailSourceID: ObjectIdentifier?
        private var interfaceScale: CGFloat = 1
        private var sessionTextScale: CGFloat = 1
        private var colorScheme: ColorScheme = .light
        private var document: MacConversationTextDocument?
        private var onNeedEarlier: (() async -> Bool)?
        private var onFollowChange: ((Bool) -> Void)?
        private var lastScrollRequest = 0
        private var followsLatest = true
        private var userHasScrolled = false
        private var isAutoLoading = false
        private var autoLoadHeld = false
        private var lastTableWidth: CGFloat = 0
        private var scrollObservers: [NSObjectProtocol] = []
        private var jumpSerial = 0
        private var didInitialScroll = false
        private var pinScheduled = false
        private var pendingHeightIDs: Set<String> = []
        private var heightFlushScheduled = false
        private var isApplyingHeights = false
        private var heightEntries: [String: HeightEntry] = [:]

        private var renderContext: RenderContext {
            RenderContext(runtimeID: runtimeID, interfaceScale: interfaceScale,
                          sessionTextScale: sessionTextScale, colorScheme: colorScheme,
                          document: document.map(ObjectIdentifier.init))
        }

        private var trailingContext: TrailingContext {
            TrailingContext(prompts: prompts, activity: activity, isConnected: isConnected,
                            isSending: isSending, questionSubmissionState: questionSubmissionState)
        }

        /// Before the first layout the table has no width; estimate at the
        /// last real width (or a typical pane) rather than collapsing every
        /// estimate to a 40-point column.
        private var layoutWidth: CGFloat {
            let width = table?.bounds.width ?? 0
            if width > 80 { return width }
            return lastTableWidth > 80 ? lastTableWidth : 640
        }

        private var geometry: Geometry {
            Geometry(width: layoutWidth, interfaceScale: interfaceScale,
                     sessionTextScale: sessionTextScale,
                     document: document.map(ObjectIdentifier.init))
        }

        func configure(_ view: MacPooledConversationList) {
            rows = view.rows
            separators = view.separators
            gaps = view.gaps
            prompts = view.prompts
            activity = view.activity
            runtimeID = view.runtimeID
            isConnected = view.isConnected
            isSending = view.isSending
            questionSubmissionState = view.questionSubmissionState
            onQuestionSubmit = view.onQuestionSubmit
            onRetryMessage = view.onRetryMessage
            onNeedDetails = view.onNeedDetails
            detailSourceID = view.detailSourceID
            interfaceScale = view.interfaceScale
            sessionTextScale = view.sessionTextScale
            colorScheme = view.colorScheme
            document = view.document
            onNeedEarlier = view.onNeedEarlier
            onFollowChange = view.onFollowChange
        }

        // MARK: - Data

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 44 }
            let id = rows[row].id
            // A stale entry (other width or zoom) still beats a fresh estimate:
            // display re-measures it at the current geometry.
            if let entry = heightEntries[id] { return entry.height }
            let height = estimateHeight(for: rows[row], tableWidth: layoutWidth)
            heightEntries[id] = HeightEntry(geometry: geometry, height: height, measured: false)
            return height
        }

        /// Detached text measurement (shared cache) plus stable chrome, used
        /// only until the row is displayed and measured.
        private func estimateHeight(for row: MacPooledRow, tableWidth: CGFloat) -> CGFloat {
            let font = Typography.sessionUIFont(.bubbleBody, scale: sessionTextScale * interfaceScale)
            switch row {
            case .timeline(let item):
                let gap = (gaps[item.id] ?? 0) * interfaceScale
                var chrome = gap
                if separators[item.id] != nil { chrome += 24 * interfaceScale }
                switch item {
                case .message(let message):
                    let isUser = message.role.lowercased() == "user"
                    let column = min(tableWidth - 2 * Space.base, ChatLayout.readableWidth ?? tableWidth)
                    let textWidth = max(column - (isUser ? 2 * Space.base : 0), 120)
                    var textHeight = font.pointSize + 10
                    if let document, let text = document.text(for: message.seq),
                       let measurement = document.measurement(for: message.seq) {
                        let measured = measurement.size(for: text, font: font, width: textWidth)
                        textHeight = ceil(max(measured.height, font.pointSize + 4))
                    }
                    chrome += isUser ? 2 * Space.md : Space.xs
                    return ceil(textHeight + chrome)
                case .toolGroup:
                    return ceil(chrome + 44 * interfaceScale)
                }
            case .prompts:
                return 200
            case .activity:
                return 36
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: PooledRowCell.identifier, owner: nil) as? PooledRowCell) ?? PooledRowCell()
            cell.identifier = PooledRowCell.identifier
            cell.setRoot(AnyView(rowContent(for: rows[row])))
            recordMeasuredHeight(of: cell, id: rows[row].id,
                                 cellWidth: tableView.frameOfCell(atColumn: 0, row: row).width)
            return cell
        }

        /// Measure the displayed row; corrections apply after the delegate
        /// returns (changing heights inside it is a reentrant table operation).
        private func recordMeasuredHeight(of cell: PooledRowCell, id: String, cellWidth: CGFloat) {
            let current = geometry
            if let entry = heightEntries[id], entry.measured, entry.geometry == current { return }
            // Measure at the width the cell will actually get, not the table's.
            let width = cellWidth > 80 ? cellWidth : current.width
            guard let height = cell.fittingHeight(width: width) else { return }
            let previous = heightEntries[id]?.height
            heightEntries[id] = HeightEntry(geometry: current, height: height, measured: true)
            if previous.map({ abs($0 - height) > 0.5 }) ?? true {
                pendingHeightIDs.insert(id)
                scheduleHeightFlush()
            }
        }

        private func scheduleHeightFlush() {
            guard !heightFlushScheduled else { return }
            heightFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightFlushScheduled = false
                self.flushHeights()
            }
        }

        /// Applies measured corrections inside the table's layout pass.
        /// Returns whether heights changed (the caller lays out again).
        func applyPendingHeights() -> Bool {
            guard !pendingHeightIDs.isEmpty, !isApplyingHeights else { return false }
            isApplyingHeights = true
            defer { isApplyingHeights = false }
            flushHeights()
            return true
        }

        private func flushHeights() {
            guard let table, !pendingHeightIDs.isEmpty else { return }
            var indexes = IndexSet()
            for (index, row) in rows.enumerated() where pendingHeightIDs.contains(row.id) {
                indexes.insert(index)
            }
            pendingHeightIDs.removeAll()
            guard !indexes.isEmpty else { return }
            preservingPosition {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: indexes)
                }
            }
        }

        private func rowContent(for row: MacPooledRow) -> some View {
            Group {
                switch row {
                case .timeline(let item):
                    VStack(alignment: .leading, spacing: 0) {
                        if let date = separators[item.id] {
                            ChatTimeSeparator(date: date)
                        }
                        switch item {
                        case .message(let message):
                            MessageBubbleView(
                                message: message,
                                runtimeID: runtimeID,
                                onRetry: { [onRetryMessage] in onRetryMessage?(message) },
                                interfaceScale: interfaceScale,
                                sessionTextScale: sessionTextScale,
                                colorScheme: colorScheme,
                                bubbleTextCap: MessageBubbleLayout.defaultBubbleCap,
                                selectionDocumentID: document.map(ObjectIdentifier.init)
                            )
                            .environment(\.macMessageSelectionID, message.seq)
                        case .toolGroup(_, let sourceSeqs, let tools):
                            ToolActivityView(
                                tools: tools,
                                sourceSeqs: sourceSeqs,
                                runtimeID: runtimeID,
                                onNeedDetails: onNeedDetails,
                                detailSourceID: detailSourceID,
                                interfaceScale: interfaceScale,
                                sessionTextScale: sessionTextScale,
                                colorScheme: colorScheme
                            )
                        }
                    }
                    .interfacePadding(.top, gaps[item.id] ?? 0)
                case .prompts:
                    AnswerOptionsView(
                        prompts: prompts,
                        isConnected: isConnected,
                        isBusy: isSending,
                        submissionState: questionSubmissionState,
                        onSubmit: { [onQuestionSubmit] requestID, answers in
                            onQuestionSubmit?(requestID, answers)
                        }
                    )
                    .id("prompts")
                case .activity:
                    if let activity {
                        ChatActivityFooter(state: activity)
                            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                            .interfacePadding(.top, Space.xs)
                            .id("activity")
                    }
                }
            }
            .environment(\.interfaceScale, interfaceScale)
            .environment(\.sessionTextScale, sessionTextScale)
            .environment(\.colorScheme, colorScheme)
            .environment(\.macConversationTextDocument, document)
            .chatReadableColumn()
            // A reused cell must not carry the previous row's representables:
            // native text views belong to one message in the shared document,
            // so a new row identity realizes (or reattaches) its own view.
            .id(row.id)
        }

        // MARK: - Updates

        func mount() {
            lastRows = rows
            lastSeparators = separators
            lastGaps = gaps
            lastDetailSourceID = detailSourceID
            lastRender = renderContext
            lastTrailing = trailingContext
            table?.reloadData()
            scrollToBottom(animated: false)
            // The caller's jump button state may belong to a previous list.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onFollowChange?(self.followsLatest)
            }
        }

        /// Diff by stable id, then by rendered value: streaming edits reload
        /// one row, structural changes rebuild and keep the reading position.
        /// Changed rows drop their heights so they re-measure.
        func syncRows() {
            guard let table else { return }
            if detailSourceID != lastDetailSourceID {
                resetForNewConversation()
                return
            }
            let render = renderContext
            let trailing = trailingContext
            defer {
                lastRows = rows
                lastSeparators = separators
                lastGaps = gaps
                lastRender = render
                lastTrailing = trailing
            }
            let newIDs = rows.map(\.id)
            if newIDs != lastRows.map(\.id) {
                let oldByID = Dictionary(lastRows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for row in rows where row != oldByID[row.id] || rowDecorationChanged(row.id) {
                    heightEntries[row.id] = nil
                }
                if trailing != lastTrailing {
                    heightEntries["prompts"] = nil
                    heightEntries["activity"] = nil
                }
                preservingPosition { table.reloadData() }
                return
            }
            var changed = IndexSet()
            for (index, row) in rows.enumerated() {
                let trailingChanged = (row == .prompts || row == .activity) && trailing != lastTrailing
                if row != lastRows[index] || rowDecorationChanged(row.id) || trailingChanged {
                    changed.insert(index)
                    heightEntries[row.id] = nil
                }
            }
            if render != lastRender {
                // Zoom, theme or document swaps re-render what is on screen;
                // the remaining rows re-measure when they are displayed.
                changed.formUnion(visibleRowIndexes())
            }
            if !changed.isEmpty {
                preservingPosition {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                    table.noteHeightOfRows(withIndexesChanged: changed)
                }
            }
        }

        private func rowDecorationChanged(_ id: String) -> Bool {
            separators[id] != lastSeparators[id] || gaps[id] != lastGaps[id]
        }

        /// The same table can be handed another conversation: start it like a
        /// fresh mount (latest edge, no inherited heights or paging holds).
        private func resetForNewConversation() {
            heightEntries.removeAll()
            pendingHeightIDs.removeAll()
            userHasScrolled = false
            autoLoadHeld = false
            isAutoLoading = false
            jumpSerial &+= 1
            setFollowsLatest(true)
            mount()
        }

        func consumeScrollIntents(scrollToMessageID: Binding<String?>, scrollToLatestRequest: Int) {
            guard let table else { return }
            if let target = scrollToMessageID.wrappedValue {
                if let index = rows.firstIndex(where: { $0.id == target }) {
                    setFollowsLatest(false)
                    reveal(index: index, in: table)
                    // Display measures the landing zone; land again once its
                    // corrected heights have been applied.
                    jumpSerial &+= 1
                    let serial = jumpSerial
                    DispatchQueue.main.async { [weak self] in
                        guard let self, serial == self.jumpSerial, let table = self.table,
                              let settled = self.rows.firstIndex(where: { $0.id == target }) else { return }
                        self.flushHeights()
                        self.reveal(index: settled, in: table)
                    }
                }
                DispatchQueue.main.async { scrollToMessageID.wrappedValue = nil }
            }
            if scrollToLatestRequest != lastScrollRequest {
                lastScrollRequest = scrollToLatestRequest
                showLatest()
            }
        }

        /// Top-aligns a row with a small margin so a jump reads from its start.
        private func reveal(index: Int, in table: NSTableView) {
            guard let clip = table.enclosingScrollView?.contentView else { return }
            let rect = table.rect(ofRow: index)
            setClipOrigin(rect.minY - Space.sm * interfaceScale, clip: clip)
        }

        // MARK: - Scrolling

        func observeScroll(of scroll: NSScrollView) {
            let center = NotificationCenter.default
            scrollObservers = [
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scroll.contentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollGeometryChanged(scroll: scroll) }
                },
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scroll, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.noteUserScroll() }
                },
            ]
            if let table {
                // Rows grow below a pinned reader without moving the clip
                // origin; re-pin on content size changes while following.
                table.postsFrameChangedNotifications = true
                scrollObservers.append(center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: table, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.contentSizeChanged() }
                })
            }
            scroll.contentView.postsBoundsChangedNotifications = true
        }

        func teardown(scroll: NSScrollView) {
            scrollObservers.forEach(NotificationCenter.default.removeObserver)
            scrollObservers = []
            scroll.contentView.postsBoundsChangedNotifications = false
            table = nil
        }

        func noteUserScroll() {
            userHasScrolled = true
        }

        private func contentSizeChanged() {
            guard followsLatest, didInitialScroll, !pinScheduled else { return }
            // Coalesce: one layout pass can resize the table many times, and
            // scrolling inside the table's own layout pass is unsafe.
            pinScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pinScheduled = false
                if self.followsLatest { self.scrollToBottom(animated: false) }
            }
        }

        private func scrollGeometryChanged(scroll: NSScrollView) {
            guard let table else { return }
            let visible = scroll.contentView.documentVisibleRect
            // The mount-time pin lands before layout exists; pin again on the
            // first valid geometry. Later explicit jumps arrive after mount.
            if !didInitialScroll, visible.height > 0, table.numberOfRows > 0 {
                didInitialScroll = true
                lastTableWidth = table.bounds.width
                scrollToBottom(animated: false)
                return
            }
            if abs(table.bounds.width - lastTableWidth) > 0.5 {
                lastTableWidth = table.bounds.width
                // Re-render on-screen rows at the new width now; offscreen rows
                // keep their last height until they are displayed again.
                let visibleIndexes = visibleRowIndexes()
                if !visibleIndexes.isEmpty {
                    preservingPosition {
                        table.reloadData(forRowIndexes: visibleIndexes, columnIndexes: IndexSet(integer: 0))
                    }
                }
            }
            // NSTableView is flipped: row 0 (oldest) sits at y = 0, so the
            // reading top is minY and the latest edge is the table's maxY.
            // Only the reader moves follow state; programmatic pins stay put.
            if userHasScrolled {
                setFollowsLatest(table.bounds.height - visible.maxY <= 44)
            }
            loadEarlierIfReading(scroll: scroll, visible: visible)
        }

        private func setFollowsLatest(_ value: Bool) {
            guard followsLatest != value else { return }
            followsLatest = value
            onFollowChange?(value)
        }

        private func visibleRowIndexes() -> IndexSet {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return [] }
            let range = table.rows(in: clip.documentVisibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return [] }
            return IndexSet(integersIn: range.location..<min(rows.count, range.location + range.length))
        }

        private func currentAnchor() -> Anchor? {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return nil }
            let visible = clip.documentVisibleRect
            guard let first = visibleRowIndexes().first, rows.indices.contains(first) else { return nil }
            return Anchor(id: rows[first].id, offset: table.rect(ofRow: first).minY - visible.minY)
        }

        /// Applies a layout change without moving what the reader sees: the
        /// latest edge stays pinned while following, otherwise the first
        /// visible row keeps its place in the viewport.
        private func preservingPosition(_ change: () -> Void) {
            let anchor = followsLatest ? nil : currentAnchor()
            change()
            if followsLatest {
                scrollToBottom(animated: false)
            } else if let anchor, let table, let clip = table.enclosingScrollView?.contentView,
                      let index = rows.firstIndex(where: { $0.id == anchor.id }) {
                setClipOrigin(table.rect(ofRow: index).minY - anchor.offset, clip: clip)
            }
        }

        private func setClipOrigin(_ y: CGFloat, clip: NSClipView) {
            guard let table else { return }
            let maxY = max(table.frame.height - clip.bounds.height, 0)
            let target = NSPoint(x: 0, y: min(max(y, 0), maxY))
            guard abs(clip.bounds.origin.y - target.y) > 0.25 else { return }
            clip.scroll(to: target)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        private func loadEarlierIfReading(scroll: NSScrollView, visible: CGRect) {
            guard let load = onNeedEarlier, !isAutoLoading, !autoLoadHeld else { return }
            let contentHeight = scroll.documentView?.frame.height ?? 0
            let containerHeight = scroll.contentView.bounds.height
            guard containerHeight > 0, contentHeight > 0 else { return }
            // Short transcripts fill immediately; readers near the top page
            // earlier. The reading position survives through syncRows.
            let overflows = contentHeight - containerHeight > 1
            let distanceFromTop = visible.minY
            guard !overflows || (userHasScrolled && distanceFromTop < containerHeight) else { return }
            isAutoLoading = true
            Task { @MainActor in
                let loaded = await load()
                if !loaded { self.autoLoadHeld = true }
                self.isAutoLoading = false
            }
        }

        private func showLatest() {
            setFollowsLatest(true)
            scrollToBottom(animated: false)
        }

        /// Pins the document end, not just the last row: a row taller than the
        /// viewport would otherwise stop at its top edge.
        func scrollToBottom(animated: Bool) {
            guard let table, table.numberOfRows > 0,
                  let scroll = table.enclosingScrollView else { return }
            let clip = scroll.contentView
            let end = NSPoint(x: 0, y: max(0, table.frame.height - clip.bounds.height))
            if animated {
                NSAnimationContext.runAnimationGroup { _ in clip.animator().setBoundsOrigin(end) }
            } else if abs(clip.bounds.origin.y - end.y) > 0.25 {
                clip.scroll(to: end)
            }
            scroll.reflectScrolledClipView(clip)
        }
    }
}
#endif
