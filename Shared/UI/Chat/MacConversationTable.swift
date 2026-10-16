#if os(macOS)
import AppKit
import SwiftUI

/// What one conversation row renders. Equality decides whether a row is
/// rendered and measured again.
enum MacConversationRowValue: Equatable {
    case loadError(String)
    case earlierHistory(isLoading: Bool)
    case timeline(ConversationTimelineItem, separator: Date?, gap: CGFloat)
    case prompts(ChatPromptsCardState)
    case activity(ChatActivityState)
}

/// Ids match the lazy stack's scroll targets ("message-<seq>", "tools-<seq>",
/// "prompts", "activity"), so jumps and reading anchors keep their meaning.
struct MacConversationRow: Equatable, Identifiable {
    let id: String
    let value: MacConversationRowValue
}

/// Inputs that change every row's rendering and size.
struct MacConversationRenderKey: Equatable {
    var interfaceScale: CGFloat
    var sessionTextScale: CGFloat
    var colorScheme: ColorScheme
    var runtimeID: String?
    var document: ObjectIdentifier?
}

/// Row heights measured for one conversation document. The document outlives
/// its table, so a table rebuilt when a pane returns from its terminal reuses
/// them; re-measuring every row of a long history through SwiftUI blocked the
/// window for seconds on each return (2026-10-14). Keys still include content
/// and width, so only changed rows are measured again.
@MainActor
final class MacConversationRowHeights {
    fileprivate var measured: [String: MacConversationTable.Coordinator.Measured] = [:]

    /// Drop rows that left the conversation once they clearly outnumber it.
    fileprivate func prune(keeping ids: [String: Int]) {
        guard measured.count > ids.count * 2 + 64 else { return }
        measured = measured.filter { ids[$0.key] != nil }
    }
}

/// The Mac conversation (owner decision 2026-10-13): a native table whose every
/// row height is measured from that row's own SwiftUI layout before the table
/// tiles it. A lazy stack places unrealized rows at estimated heights, which
/// left blank viewports and stale positions after switching, zoom and fast
/// scrolling. Cells are reused; the native text views inside stay owned by the
/// conversation's shared text document.
struct MacConversationTable: NSViewRepresentable {
    var rows: [MacConversationRow]
    var renderKey: MacConversationRenderKey
    var rowContent: (MacConversationRow) -> AnyView
    /// Safe-area insets the content scrolls under (pane chrome, composer).
    var insets: EdgeInsets
    var scrollToLatestRequest: Int
    @Binding var scrollToMessageID: String?
    var jumpGlides: (_ target: String, _ visible: String?) -> Bool
    /// Nil when no older pages exist. Returns whether older rows arrived.
    var onLoadEarlier: (() async -> Bool)?
    var onFollowChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scroll = ConversationScrollView()
        scroll.coordinator = coordinator
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.horizontalScrollElasticity = .none
        let table = ConversationTableView()
        table.coordinator = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.headerView = nil
        table.style = .fullWidth
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.refusesFirstResponder = true
        table.focusRingType = .none
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        // The coordinator keeps the single column exactly as wide as the table,
        // the width every row is measured at.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.resizingMask = []
        table.addTableColumn(column)
        scroll.documentView = table
        coordinator.attach(scroll: scroll, table: table)
        coordinator.update(self, environment: context.environment)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self, environment: context.environment)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Native views

    final class ConversationScrollView: NSScrollView {
        weak var coordinator: Coordinator?

        /// Wheel and trackpad scrolling belong to the reader. Discrete mouse
        /// wheels have no phase, so each event counts as one reading step.
        override func scrollWheel(with event: NSEvent) {
            #if DEBUG
            MacConversationTableCounters.wheelEvents &+= 1
            #endif
            coordinator?.readerScrollWillChange(phase: event.phase, momentum: event.momentumPhase)
            super.scrollWheel(with: event)
            coordinator?.readerScrollDidChange(phase: event.phase, momentum: event.momentumPhase)
        }
    }

    final class ConversationTableView: NSTableView {
        weak var coordinator: Coordinator?

        /// Width or style changes re-measure before the rows are tiled, so a
        /// row is never drawn at a height measured for another geometry.
        override func layout() {
            coordinator?.tableWillLayout()
            super.layout()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.tableDidMoveToWindow()
        }
    }

    /// Reusable cell: a SwiftUI host that fills the row the table assigns.
    final class RowCell: NSView {
        static let identifier = NSUserInterfaceItemIdentifier("MacConversationRow")
        private let hosting = RowHostingView(rootView: AnyView(EmptyView()))
        private(set) var rowID: String?

        override init(frame: NSRect) {
            super.init(frame: frame)
            identifier = Self.identifier
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = bounds
            addSubview(hosting)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }

        func show(_ root: AnyView, id: String) {
            rowID = id
            hosting.rootView = root
        }
    }

    /// Rows contain no scrollable SwiftUI content: wheel and trackpad
    /// scrolling over a row always belongs to the conversation.
    final class RowHostingView: NSHostingView<AnyView> {
        override func scrollWheel(with event: NSEvent) {
            if let scroll = enclosingScrollView {
                scroll.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// Everything a row's rendering depends on besides its width.
        fileprivate struct ContentKey: Equatable {
            var value: MacConversationRowValue
            var isFirst: Bool
            var render: MacConversationRenderKey
        }

        fileprivate struct HeightKey: Equatable {
            var content: ContentKey
            var width: CGFloat
        }

        fileprivate struct Measured {
            var key: HeightKey
            var height: CGFloat
        }

        /// A reading position: a row and its top edge relative to the viewport top.
        private struct Anchor {
            var id: String
            var offset: CGFloat
        }

        private weak var scroll: ConversationScrollView?
        private weak var table: ConversationTableView?
        private var rows: [MacConversationRow] = []
        private var indexByID: [String: Int] = [:]
        private var renderKey: MacConversationRenderKey?
        private var rowContent: ((MacConversationRow) -> AnyView)?
        private var environment = EnvironmentValues()
        private var insets = NSEdgeInsets()
        private var jumpGlides: ((String, String?) -> Bool)?
        private var onLoadEarlier: (() async -> Bool)?
        private var onFollowChange: ((Bool) -> Void)?
        private var scrollToMessageID: Binding<String?>?
        private var lastLatestRequest: Int?

        private var heights = MacConversationRowHeights()
        private var cells: [RowCell] = []
        private let measurer = NSHostingController(rootView: AnyView(EmptyView()))
        /// Width the current row heights were measured for.
        private var measuredWidth: CGFloat = 0
        private var needsRemeasure = false

        private(set) var followsLatest = true
        private var userHasScrolled = false
        private var isReaderScrolling = false
        private var isAutoLoading = false
        private var autoLoadHeld = false
        private var historyCheckScheduled = false
        private var lastHistoryLoadRows: [MacConversationRow]?
        private var isJumping = false
        private var jumpGeneration = 0
        private var lastReadAck = Date.distantPast
        private var adjustingPosition = false
        private var observers: [NSObjectProtocol] = []
        private var liveCorrectionScheduled = false
        private var pinScheduled = false
        private var isGliding = false
        private var pendingLiveCorrections: Set<String> = []

        override init() {
            super.init()
            measurer.sizingOptions = []
        }

        func attach(scroll: ConversationScrollView, table: ConversationTableView) {
            self.scroll = scroll
            self.table = table
            let center = NotificationCenter.default
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            table.postsFrameChangedNotifications = true
            observers = [
                center.addObserver(forName: NSView.frameDidChangeNotification, object: table,
                                   queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.geometryDidChange() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView,
                                   queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.geometryDidChange() }
                },
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                   queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.viewportDidScroll() }
                },
                center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll,
                                   queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveScroll(started: true) }
                },
                center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll,
                                   queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveScroll(started: false) }
                },
            ]
            center.addObserver(self, selector: #selector(selectionDidChange(_:)),
                               name: NSTextView.didChangeSelectionNotification, object: nil)
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification,
                                                      object: nil)
            scroll?.contentView.postsBoundsChangedNotifications = false
            table?.coordinator = nil
            scroll?.coordinator = nil
        }

        // MARK: Updates

        func update(_ view: MacConversationTable, environment: EnvironmentValues) {
            self.environment = environment
            if let document = environment.macConversationTextDocument {
                if let shared = document.tableRowHeights as? MacConversationRowHeights {
                    if shared !== heights { heights = shared }
                } else {
                    document.tableRowHeights = heights
                }
            }
            rowContent = view.rowContent
            jumpGlides = view.jumpGlides
            onLoadEarlier = view.onLoadEarlier
            onFollowChange = view.onFollowChange
            scrollToMessageID = view.$scrollToMessageID
            let newInsets = NSEdgeInsets(top: view.insets.top + Space.base, left: 0,
                                         bottom: view.insets.bottom + Space.base, right: 0)
            let renderChanged = renderKey != view.renderKey
            renderKey = view.renderKey
            applyRows(view.rows, renderChanged: renderChanged)
            if let scroll, !NSEdgeInsetsEqual(scroll.contentInsets, newInsets) {
                let anchor = followsLatest ? nil : currentAnchor()
                insets = newInsets
                scroll.contentInsets = newInsets
                restore(anchor)
            }
            if lastLatestRequest != view.scrollToLatestRequest {
                let isFirst = lastLatestRequest == nil
                lastLatestRequest = view.scrollToLatestRequest
                if !isFirst { requestLatest() }
            }
            if let target = view.scrollToMessageID {
                DispatchQueue.main.async { view.$scrollToMessageID.wrappedValue = nil }
                jump(to: target)
            }
            scheduleHistoryCheck()
        }

        private func applyRows(_ newRows: [MacConversationRow], renderChanged: Bool) {
            guard let table else { return }
            let old = rows
            guard renderChanged || old != newRows else { return }
            let anchor = followsLatest ? nil : currentAnchor()
            rows = newRows
            indexByID = Dictionary(newRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            heights.prune(keeping: indexByID)
            if old.map(\.id) == newRows.map(\.id) {
                var changed = IndexSet()
                for index in newRows.indices where renderChanged || newRows[index] != old[index] {
                    changed.insert(index)
                }
                // The table also keeps prepared rows outside the viewport;
                // every realized row must show its current content.
                var realized = IndexSet()
                table.enumerateAvailableRowViews { _, row in realized.insert(row) }
                withoutAnimation {
                    table.noteHeightOfRows(withIndexesChanged: changed)
                    let stale = realized.intersection(changed)
                    if !stale.isEmpty {
                        table.reloadData(forRowIndexes: stale, columnIndexes: IndexSet(integer: 0))
                    }
                }
            } else {
                // Structural change (open, new rows, prepended history): heights
                // of unchanged rows stay cached, so this measures only new rows.
                withoutAnimation { table.reloadData() }
            }
            restore(anchor)
        }

        // MARK: Heights

        private var canMeasure: Bool {
            guard let table, table.window != nil, !table.isHiddenOrHasHiddenAncestor else { return false }
            return rowWidth > 1
        }

        /// The single column spans the clip view; rows are measured and laid
        /// out at exactly this width.
        private var rowWidth: CGFloat {
            scroll?.contentView.bounds.width ?? 0
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 1 }
            let item = rows[row]
            let width = rowWidth
            guard canMeasure, let renderKey else {
                // Hidden or not yet sized: keep the last known height and
                // measure every row before this table is next laid out.
                needsRemeasure = true
                return heights.measured[item.id]?.height ?? 1
            }
            let key = HeightKey(content: ContentKey(value: item.value, isFirst: row == 0, render: renderKey),
                                width: width)
            if let cached = heights.measured[item.id], cached.key == key { return cached.height }
            let height = measure(item, isFirst: row == 0, width: width)
            heights.measured[item.id] = Measured(key: key, height: height)
            // One delegate query must not acknowledge a width change for all
            // rows. tableWillLayout invalidates the table-wide geometry.
            return height
        }

        private func measure(_ row: MacConversationRow, isFirst: Bool, width: CGFloat) -> CGFloat {
            measurer.rootView = content(for: row, isFirst: isFirst, measuring: true)
            let size = measurer.sizeThatFits(in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            #if DEBUG
            MacConversationTableCounters.measurements &+= 1
            #endif
            guard size.height.isFinite, size.height > 0 else { return 1 }
            return ceil(size.height)
        }

        func tableWillLayout() {
            guard let table, canMeasure, let column = table.tableColumns.first else { return }
            defer { scheduleHistoryCheck() }
            let width = rowWidth
            if abs(column.width - width) > 0.25 { column.width = width }
            guard needsRemeasure || abs(width - measuredWidth) > 0.25 else { return }
            needsRemeasure = false
            measuredWidth = width
            remeasureAll()
        }

        func tableDidMoveToWindow() {
            guard canMeasure else { return }
            table?.needsLayout = true
        }

        private func remeasureAll() {
            guard let table, !rows.isEmpty else { return }
            let anchor = followsLatest ? nil : currentAnchor()
            withoutAnimation {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            }
            restore(anchor)
        }

        /// A displayed row reports its natural height. It only differs from the
        /// measured one when the row's own state changed (an image finished
        /// loading, a question was expanded); apply that as a content change.
        fileprivate func row(_ id: String, content: ContentKey?, reportedHeight height: CGFloat, width: CGFloat) {
            // Reports from a cell still showing older content are not news.
            guard table != nil, abs(width - rowWidth) <= 0.5,
                  let index = indexByID[id], let measured = heights.measured[id],
                  measured.key.content == content, abs(measured.key.width - width) <= 0.5,
                  abs(measured.height - ceil(height)) > 0.5 else { return }
            heights.measured[id]?.height = ceil(height)
            #if DEBUG
            MacConversationTableCounters.liveCorrections &+= 1
            #endif
            pendingLiveCorrections.insert(rows[index].id)
            guard !liveCorrectionScheduled else { return }
            liveCorrectionScheduled = true
            // Never change row heights inside the table's own layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                self.liveCorrectionScheduled = false
                let indexes = IndexSet(self.pendingLiveCorrections.compactMap { self.indexByID[$0] })
                self.pendingLiveCorrections.removeAll()
                let anchor = self.followsLatest ? nil : self.currentAnchor()
                self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: indexes) }
                self.restore(anchor)
            }
        }

        // MARK: Cells

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let cell: RowCell
            if let reused = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell {
                cell = reused
            } else {
                cell = RowCell()
                // macOS 27 SwiftUI keeps hover/tooltip hit-test references to
                // hosting views; one freed while its window lives crashes the
                // next mouse movement. Cells live as long as the table (the
                // pool is bounded by the rows realized at once).
                cells.append(cell)
            }
            let item = rows[row]
            cell.show(content(for: item, isFirst: row == 0, measuring: false), id: item.id)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        private func content(for row: MacConversationRow, isFirst: Bool, measuring: Bool) -> AnyView {
            let base = rowContent?(row) ?? AnyView(EmptyView())
            let contentKey = renderKey.map { ContentKey(value: row.value, isFirst: isFirst, render: $0) }
            let content = base
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatReadableColumn()
                // The lazy stack's spacing and content margins, now per row.
                .interfacePadding(.top, isFirst ? 0 : Space.xs)
                .padding(.horizontal, Space.base)
                .environment(\.macRowMeasurement, measuring)
            guard !measuring else {
                return AnyView(content.modifier(InheritedEnvironment(environment: environment)))
            }
            let id = row.id
            return AnyView(
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                        self?.row(id, content: contentKey, reportedHeight: size.height, width: size.width)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .modifier(InheritedEnvironment(environment: environment))
                    // A reused cell must realize this row's own views.
                    .id(id)
            )
        }

        // MARK: Position

        private var visibleRect: NSRect {
            scroll?.contentView.documentVisibleRect ?? .zero
        }

        /// The reading viewport, excluding the content insets.
        private var readingRect: NSRect {
            guard let clip = scroll?.contentView else { return .zero }
            let bounds = clip.bounds
            return NSRect(x: bounds.minX, y: bounds.minY + insets.top, width: bounds.width,
                          height: max(bounds.height - insets.top - insets.bottom, 0))
        }

        /// Height of the rows themselves; the table frame also stretches to
        /// fill a viewport taller than the conversation.
        private var contentHeight: CGFloat {
            guard let table, !rows.isEmpty else { return 0 }
            return table.rect(ofRow: rows.count - 1).maxY
        }

        private func visibleRowIndexes() -> IndexSet {
            guard let table else { return [] }
            let range = table.rows(in: visibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return [] }
            return IndexSet(integersIn: range.location..<min(rows.count, range.location + range.length))
        }

        private func readingRowIndexes() -> IndexSet {
            guard let table else { return [] }
            let range = table.rows(in: readingRect)
            guard range.location != NSNotFound, range.length > 0 else { return [] }
            return IndexSet(integersIn: range.location..<min(rows.count, range.location + range.length))
        }

        private func currentAnchor() -> Anchor? {
            guard let table, let first = readingRowIndexes().first, rows.indices.contains(first) else { return nil }
            return Anchor(id: rows[first].id, offset: table.rect(ofRow: first).minY - readingRect.minY)
        }

        /// Keeps what the reader sees: the latest edge while following,
        /// otherwise the anchored row's place in the viewport.
        private func restore(_ anchor: Anchor?) {
            guard let table else { return }
            // Row height changes resize the table lazily; position against
            // the size the reader is about to see.
            table.tile()
            if followsLatest {
                pinToLatest()
            } else if let anchor, let index = indexByID[anchor.id] {
                setReadingTop(table.rect(ofRow: index).minY - anchor.offset)
            }
        }

        private var overflows: Bool {
            ChatLatestFollowPolicy.shouldScrollToEdge(contentHeight: contentHeight,
                                                      containerHeight: readingRect.height)
        }

        /// Short conversations rest at the top; longer ones show their end.
        private func pinToLatest() {
            guard let table, table.numberOfRows > 0 else { return }
            if overflows {
                setReadingTop(contentHeight - readingRect.height)
            } else {
                setReadingTop(0)
            }
        }

        private func setReadingTop(_ y: CGFloat, animated: Bool = false) {
            guard let scroll else { return }
            let clip = scroll.contentView
            let maxTop = max(contentHeight - readingRect.height, 0)
            let origin = NSPoint(x: clip.bounds.minX, y: min(max(y, 0), maxTop) - insets.top)
            guard abs(clip.bounds.origin.y - origin.y) > 0.25 else { return }
            adjustingPosition = true
            defer { adjustingPosition = false }
            if animated {
                isGliding = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = MacConversationMotion.glideDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    clip.animator().setBoundsOrigin(origin)
                }
            } else {
                if isGliding {
                    // Supersede an in-flight jump glide, or it would pull the
                    // viewport back into history after this move.
                    isGliding = false
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        clip.animator().setBoundsOrigin(origin)
                    }
                }
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
        }

        private func setFollowsLatest(_ value: Bool) {
            guard followsLatest != value else { return }
            followsLatest = value
            let report = onFollowChange
            DispatchQueue.main.async { report?(value) }
        }

        private func requestLatest() {
            if isJumping {
                jumpGeneration += 1
                isJumping = false
                scroll?.alphaValue = 1
            }
            setFollowsLatest(true)
            pinToLatest()
        }

        func showLatest() { requestLatest() }

        // MARK: Reader scrolling

        func readerScrollWillChange(phase: NSEvent.Phase, momentum: NSEvent.Phase) {
            if phase.contains(.began) || phase.contains(.mayBegin) || (phase.isEmpty && momentum.isEmpty) {
                isReaderScrolling = true
                if !userHasScrolled { userHasScrolled = true }
                autoLoadHeld = false
                lastHistoryLoadRows = nil
                acknowledgeRead(force: phase.contains(.began))
            }
        }

        func readerScrollDidChange(phase: NSEvent.Phase, momentum: NSEvent.Phase) {
            let discrete = phase.isEmpty && momentum.isEmpty
            if discrete || momentum.contains(.ended) || momentum.contains(.cancelled)
                || (phase.contains(.ended) && momentum.isEmpty) || phase.contains(.cancelled) {
                updateFollowFromViewport()
                if discrete || momentum.contains(.ended) || momentum.contains(.cancelled) {
                    isReaderScrolling = false
                }
            }
            // At the top, a wheel can leave clip bounds unchanged. The input
            // still requests earlier history; a bounds notification is optional.
            scheduleHistoryCheck()
        }

        private func liveScroll(started: Bool) {
            if started {
                isReaderScrolling = true
                if !userHasScrolled { userHasScrolled = true }
                autoLoadHeld = false
                lastHistoryLoadRows = nil
            } else {
                updateFollowFromViewport()
                isReaderScrolling = false
            }
            scheduleHistoryCheck()
        }

        /// Content or viewport size changed outside a row update (layout,
        /// window or pane resize): keep the latest edge while following.
        /// Deferred: scrolling inside the table's own layout pass is unsafe.
        private func geometryDidChange() {
            scheduleHistoryCheck()
            guard followsLatest, !isReaderScrolling, !pinScheduled else { return }
            pinScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pinScheduled = false
                if self.followsLatest, !self.isReaderScrolling { self.pinToLatest() }
            }
        }

        private func viewportDidScroll() {
            publishInspection()
            guard !adjustingPosition else { return }
            if isReaderScrolling {
                updateFollowFromViewport()
                acknowledgeRead(force: false)
            }
            loadEarlierIfReading()
        }

        private func updateFollowFromViewport() {
            guard !isJumping else { return }
            let distance = contentHeight - readingRect.maxY
            setFollowsLatest(distance <= 44)
        }

        private func acknowledgeRead(force: Bool) {
            guard force || Date.now.timeIntervalSince(lastReadAck) > 1.5 else { return }
            lastReadAck = Date.now
            environment.conversationScrollReadAction()
        }

        @objc private func selectionDidChange(_ note: Notification) {
            guard followsLatest, let view = note.object as? NSTextView,
                  let table, view.isDescendant(of: table),
                  view.window?.firstResponder === view, view.selectedRange().length > 0 else { return }
            // Selecting is reading: zoom or new rows must not move the selection away.
            setFollowsLatest(false)
        }

        /// Evaluate outside native tiling and after SwiftUI can publish a new
        /// slice. This also fills a short, unscrollable initial viewport.
        private func scheduleHistoryCheck() {
            guard !historyCheckScheduled else { return }
            historyCheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self else { return }
                self.historyCheckScheduled = false
                self.loadEarlierIfReading()
            }
        }

        private func loadEarlierIfReading() {
            guard canMeasure, !needsRemeasure, measuredWidth > 1,
                  let load = onLoadEarlier, !isAutoLoading, !autoLoadHeld, !isJumping,
                  lastHistoryLoadRows != rows,
                  ChatAutoLoadEarlierPolicy.shouldLoad(
                      contentHeight: contentHeight,
                      containerHeight: readingRect.height,
                      distanceFromTop: max(0, readingRect.minY),
                      userHasScrolled: userHasScrolled
                  ) else { return }
            isAutoLoading = true
            lastHistoryLoadRows = rows
            Task { @MainActor [weak self] in
                let loaded = await load()
                guard let self else { return }
                if !loaded { self.autoLoadHeld = true }
                self.isAutoLoading = false
                if loaded { self.scheduleHistoryCheck() }
            }
        }

        // MARK: Jumps

        /// Prompt jumps: a nearby target glides, a far one fades out, moves and
        /// fades back in (owner request 2026-10-07). Reduce Motion always fades.
        private func jump(to id: String) {
            guard table != nil, let index = indexByID[id] else { return }
            setFollowsLatest(false)
            userHasScrolled = true
            isJumping = true
            jumpGeneration += 1
            let generation = jumpGeneration
            let topID = readingRowIndexes().first.map { rows[$0].id }
            let glides = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && (jumpGlides?(id, topID) ?? true)
            if glides {
                setReadingTop(jumpTarget(id, fallback: index), animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + MacConversationMotion.glideDuration + 0.05) { [weak self] in
                    guard let self, generation == self.jumpGeneration else { return }
                    self.isGliding = false
                    self.isJumping = false
                    self.loadEarlierIfReading()
                }
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = MacConversationMotion.fadeOutDuration
                    scroll?.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, generation == self.jumpGeneration else { return }
                        self.setReadingTop(self.jumpTarget(id, fallback: index))
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = MacConversationMotion.fadeInDuration
                            self.scroll?.animator().alphaValue = 1
                        }
                        self.isJumping = false
                        self.loadEarlierIfReading()
                    }
                }
            }
        }

        /// Centers the target row in the reading viewport.
        private func jumpTarget(_ id: String, fallback: Int) -> CGFloat {
            guard let table else { return 0 }
            return table.rect(ofRow: indexByID[id] ?? fallback).midY - readingRect.height / 2
        }

        // MARK: Helpers

        private func withoutAnimation(_ body: () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                body()
            }
        }

        private func publishInspection() {
            #if DEBUG
            guard let key = environment.macConversationTextDocument?.debugIdentity, let table else { return }
            let reading = readingRect
            let ids = readingRowIndexes().map { rows[$0].id }
            MacChatScrollGeometryProbe.latest[key, default: [:]].merge([
                "visibleMinY": reading.minY - insets.top,
                "visibleHeight": scroll?.contentView.bounds.height ?? 0, "wheelEvents": MacConversationTableCounters.wheelEvents,
                "contentHeight": contentHeight, "tableHeight": table.frame.height, "bottomInset": insets.bottom,
                "followsLatest": followsLatest, "latestID": rows.last?.id ?? "", "visibleIDs": ids,
                "measurements": MacConversationTableCounters.measurements,
                "columnWidth": table.tableColumns.first?.width ?? 0, "rowWidth": rowWidth,
                // Never query row views here: this runs inside table layout.
                "rowDetails": readingRowIndexes().map { index -> String in
                    let id = rows[index].id
                    return "\(id) h=\(table.rect(ofRow: index).height) measuredW=\(heights.measured[id]?.key.width ?? -1)"
                },
                "liveCorrections": MacConversationTableCounters.liveCorrections,
            ]) { $1 }
            #endif
        }
    }
}

/// Rows render in their own hosting views. Pass the specific values they read
/// (as the pane host does), never the whole environment of another graph.
private struct InheritedEnvironment: ViewModifier {
    let environment: EnvironmentValues

    func body(content: Content) -> some View {
        content
            .environment(\.interfaceScale, environment.interfaceScale)
            .environment(\.sessionTextScale, environment.sessionTextScale)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.calendar, environment.calendar)
            .environment(\.timeZone, environment.timeZone)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.font, environment.font)
            .environment(\.controlSize, environment.controlSize)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.macConversationTextDocument, environment.macConversationTextDocument)
            .environment(\.chatImageLoader, environment.chatImageLoader)
    }
}

/// The conversation table inside the pane: content scrolls under the pane's
/// safe-area chrome (the composer) with the same insets the lazy stack used,
/// and the jump-to-latest control appears while reading history.
struct MacConversationScroller: View {
    var rows: [MacConversationRow]
    var renderKey: MacConversationRenderKey
    var rowContent: (MacConversationRow) -> AnyView
    var scrollToLatestRequest: Int
    @Binding var scrollToMessageID: String?
    var jumpGlides: (_ target: String, _ visible: String?) -> Bool
    var onLoadEarlier: (() async -> Bool)?
    var onFollowChange: (Bool) -> Void = { _ in }

    @State private var insets = EdgeInsets()
    @State private var followsLatest = true
    @State private var latestBump = 0

    var body: some View {
        MacConversationTable(
            rows: rows,
            renderKey: renderKey,
            rowContent: rowContent,
            insets: insets,
            scrollToLatestRequest: scrollToLatestRequest + latestBump,
            scrollToMessageID: $scrollToMessageID,
            jumpGlides: jumpGlides,
            onLoadEarlier: onLoadEarlier,
            onFollowChange: { followsLatest = $0; onFollowChange($0) }
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
        .overlay(alignment: .bottomTrailing) {
            if !followsLatest {
                ChatJumpToLatestButton { latestBump += 1 }
                    .padding(.bottom, insets.bottom)
            }
        }
    }
}

/// Jump motion, matching the lazy-stack conversation (`ChatJumpMotion`).
private enum MacConversationMotion {
    static let glideDuration: TimeInterval = seconds(0.45)
    static let fadeOutDuration: TimeInterval = seconds(0.12)
    static let fadeInDuration: TimeInterval = seconds(0.22)

    private static func seconds(_ value: Double) -> Double {
        #if DEBUG
        let slowdown = Double(ProcessInfo.processInfo.environment["CORRAL_INSPECTION_MOTION_SLOWDOWN"] ?? "") ?? 1
        return value * max(slowdown, 1)
        #else
        return value
        #endif
    }
}

#if DEBUG
/// Row measurement work and post-display corrections, for inspections.
@MainActor
enum MacConversationTableCounters {
    static var measurements = 0
    static var liveCorrections = 0
    static var wheelEvents = 0
}
#endif
#endif
