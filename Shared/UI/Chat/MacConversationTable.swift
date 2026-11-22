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
    var mediaRevision: Int = 0
}

/// Inputs that change every row's rendering and size.
struct MacConversationRenderKey: Equatable {
    var interfaceScale: CGFloat
    var sessionTextScale: CGFloat
    var colorScheme: ColorScheme
    var runtimeID: String?
    var document: ObjectIdentifier?
    var imageLoader: ObjectIdentifier? = nil
    var mediaAvailable: Bool = false
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
        // AppKit includes style-dependent margins outside the column. Let its
        // native fitting API own that space so the document never overflows.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.resizingMask = .autoresizingMask
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

        override func menu(for event: NSEvent) -> NSMenu? { paneSessionContextMenu() }

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

        override func menu(for event: NSEvent) -> NSMenu? { paneSessionContextMenu() }

        /// Width or style changes re-measure before the rows are tiled, so a
        /// row is never drawn at a height measured for another geometry.
        override func layout() {
            coordinator?.tableWillLayout()
            #if DEBUG
            let w1Start = DispatchTime.now().uptimeNanoseconds
            #endif
            super.layout()
            #if DEBUG
            Coordinator.w1NoteLayoutPass((Double(DispatchTime.now().uptimeNanoseconds - w1Start) / 1_000_000))
            #endif
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

        #if DEBUG
        override func layout() {
            let start = DispatchTime.now().uptimeNanoseconds
            super.layout()
            Coordinator.w1NoteCellLayout((Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
        }
        #endif

        func show(_ root: AnyView, id: String) {
            rowID = id
            hosting.rootView = root
        }
    }

    /// Rows contain no scrollable SwiftUI content: wheel and trackpad
    /// scrolling over a row always belongs to the conversation.
    final class RowHostingView: NSHostingView<AnyView> {
        override func menu(for event: NSEvent) -> NSMenu? { paneSessionContextMenu() }

        #if DEBUG
        override func layout() {
            let start = DispatchTime.now().uptimeNanoseconds
            super.layout()
            Coordinator.w1NoteRowLayout((Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
        }
        #endif

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
            var mediaRevision: Int = 0
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
        private var onLoadEarlier: (() async -> Bool)?
        private var onFollowChange: ((Bool) -> Void)?
        private var scrollToMessageID: Binding<String?>?
        private var lastLatestRequest: Int?

        private var heights = MacConversationRowHeights()
        private var cells: [RowCell] = []
        private let measurer = NSHostingController(rootView: AnyView(EmptyView()))
        /// Effective content width the current row heights were measured for.
        private var measuredWidth: CGFloat = 0
        private static let rowHorizontalPadding = Space.base
        private var needsRemeasure = false
        /// Offscreen rows still measured at an older width, drained in bounded
        /// batches once a resize stops. Measuring every row on every width step
        /// blocked the main thread for 136 ms per 4 pt at 120 messages and 479 ms
        /// at 300 (2026-11-16 probe), so a live drag remeasures only what the
        /// reader can see and the rest follows after the drag settles.
        private var reflowBacklog: [String] = []
        private var reflowTask: Task<Void, Never>?
        /// Bumped on every width change so a running sweep abandons its work.
        private var reflowGeneration = 0
        private var measuringViewport = false
        /// Rows per deferred batch; each costs one hosting measurement (~1.2 ms).
        private static let reflowBatchRows = 6

        #if DEBUG
        /// W1 first-scroll attribution: row realizations are grouped by the
        /// bounds change that revealed them. A batch closes on the next
        /// bounds change, so batch #0 is the open and batch #1 the first
        /// scroll. Prints only when CORRAL_W1_BATCH_LOG is set.
        private static let w1LogEnabled = ProcessInfo.processInfo.environment["CORRAL_W1_BATCH_LOG"] != nil
        private static var w1BatchIndex = 0
        private static var w1BatchViews = 0
        private static var w1BatchNewCells = 0
        private static var w1BatchViewMs: Double = 0
        private static var w1BatchViewMaxMs: Double = 0
        private static var w1BatchLayouts = 0
        private static var w1BatchLayoutMs: Double = 0
        private static var w1BatchMeasures = 0
        private static var w1BatchMeasureMs: Double = 0
        private static var w1BatchMakes = 0
        private static var w1BatchRowLayouts = 0
        private static var w1BatchRowLayoutMs: Double = 0
        private static var w1BatchCellLayouts = 0
        private static var w1BatchCellLayoutMs: Double = 0
        private static var w1BatchDismantles = 0
        private static var w1BatchCorrections = 0
        private static var w1PrevMakes = 0
        private static var w1PrevDismantles = 0
        private static var w1PrevCorrections = 0
        #endif

        private(set) var followsLatest = true
        private var userHasScrolled = false
        private var isReaderScrolling = false
        private var isAutoLoading = false
        private var autoLoadHeld = false
        private var historyCheckScheduled = false
        private var lastHistoryLoadRows: [MacConversationRow]?
        private var lastReadAck = Date.distantPast
        private var adjustingPosition = false
        private var observers: [NSObjectProtocol] = []
        private var liveCorrectionScheduled = false
        private var pinScheduled = false
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
            reflowTask?.cancel()
            reflowTask = nil
            reflowBacklog.removeAll()
            reflowGeneration &+= 1
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification,
                                                      object: nil)
            scroll?.contentView.postsBoundsChangedNotifications = false
            measurer.rootView = AnyView(EmptyView())
            rows.removeAll()
            indexByID.removeAll()
            rowContent = nil
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
            if old.map(\.id) != newRows.map(\.id) {
                // A structural change reloads the whole table; the width sweep's
                // remaining ids are no longer a valid work list.
                reflowBacklog.removeAll()
                reflowTask?.cancel()
                reflowTask = nil
                reflowGeneration &+= 1
            }
            if old.map(\.id) == newRows.map(\.id) {
                if renderChanged {
                    // Pure style/text-scale change, no structural edit:
                    // measuring every row synchronously costs ~270 ms at 120
                    // rows (W2 2026-11-16), so rewrap the viewport now and
                    // settle the rest in post-interaction batches. Offscreen
                    // rows are briefly stale by owner decision, then exact.
                    reflowRenderChange()
                } else {
                    var changed = IndexSet()
                    for index in newRows.indices {
                        let row = newRows[index]
                        if row != old[index]
                            || heights.measured[row.id]?.key.content != contentKey(for: row, isFirst: index == 0) {
                            changed.insert(index)
                        }
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

        /// The single native column spans the clip view, even when its row
        /// content is centered in a narrower readable column.
        private var rowWidth: CGFloat {
            table?.tableColumns.first?.width ?? 0
        }

        private var measurementWidth: CGFloat { measurementWidth(for: rowWidth) }

        private func measurementWidth(for columnWidth: CGFloat) -> CGFloat {
            guard let readableWidth = ChatLayout.readableWidth else { return columnWidth }
            return min(columnWidth, readableWidth * environment.interfaceScale + 2 * Self.rowHorizontalPadding)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 1 }
            let item = rows[row]
            let width = measurementWidth
            #if DEBUG
            MacConversationTableCounters.heightQueries &+= 1
            #endif
            guard canMeasure, let contentKey = contentKey(for: item, isFirst: row == 0) else {
                // Hidden or not yet sized: keep the last known height and
                // measure every row before this table is next laid out.
                needsRemeasure = true
                return heights.measured[item.id]?.height ?? 1
            }
            let key = HeightKey(content: contentKey, width: width)
            if let cached = heights.measured[item.id], cached.key == key { return cached.height }
            #if DEBUG
            MacConversationTableCounters.heightMisses &+= 1
            #endif
            let height = measure(item, isFirst: row == 0, width: width)
            heights.measured[item.id] = Measured(key: key, height: height)
            // One delegate query must not acknowledge a width change for all
            // rows. tableWillLayout invalidates the table-wide geometry.
            return height
        }

        private func measure(_ row: MacConversationRow, isFirst: Bool, width: CGFloat) -> CGFloat {
            measurer.rootView = content(for: row, isFirst: isFirst, measuring: true)
            #if DEBUG
            let w1Start = DispatchTime.now().uptimeNanoseconds
            #endif
            let size = measurer.sizeThatFits(in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            #if DEBUG
            let w1Ms = Double(DispatchTime.now().uptimeNanoseconds - w1Start) / 1_000_000
            MacConversationTableCounters.measurements &+= 1
            MacConversationTableCounters.measureMs += w1Ms
            Self.w1BatchMeasures += 1
            Self.w1BatchMeasureMs += w1Ms
            #endif
            guard size.height.isFinite, size.height > 0 else { return 1 }
            return ceil(size.height)
        }

        func tableWillLayout() {
            guard let table, canMeasure, let scroll, !measuringViewport else { return }
            defer { scheduleHistoryCheck() }
            if abs(table.frame.width - scroll.contentView.bounds.width) > 0.25 {
                table.sizeLastColumnToFit()
            }
            let width = measurementWidth
            guard needsRemeasure || abs(width - measuredWidth) > 0.25 else {
                // Scrolling before the settle sweep can expose previously
                // offscreen rows. Bring them current before native tiling.
                if !reflowBacklog.isEmpty {
                    let stale = IndexSet(visibleRowIndexes().filter { needsHeight(at: $0, width: width) })
                    measureViewport(stale)
                }
                return
            }
            // Opening a conversation must never use estimated heights. Once
            // mounted, only rows that can be seen need measuring on each step.
            let firstPass = measuredWidth <= 1
            needsRemeasure = false
            measuredWidth = width
            guard !firstPass else {
                reflowBacklog.removeAll()
                reflowGeneration &+= 1
                reflowTask?.cancel()
                reflowTask = nil
                measureAllRows()
                return
            }
            reflowViewportFirst()
        }

        func tableDidMoveToWindow() {
            guard canMeasure else { return }
            table?.needsLayout = true
        }

        private func measureAllRows() {
            guard let table, !rows.isEmpty else { return }
            let anchor = followsLatest ? nil : currentAnchor()
            withoutAnimation {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            }
            restore(anchor)
        }

        /// Width changed while the reader is dragging: rewrap what is visible now
        /// and leave the rest of the conversation for after the drag settles.
        /// A text-scale change reuses this path: widths are unchanged but the
        /// full height keys are stale, so the same viewport-then-sweep
        /// scheduling applies.
        /// - Returns: whether there was a visible range to reflow.
        @discardableResult
        private func reflowViewportFirst() -> Bool {
            guard table != nil, !rows.isEmpty else { return false }
            reflowGeneration &+= 1
            reflowTask?.cancel()
            reflowTask = nil
            let visible = visibleRowIndexes()
            guard !visible.isEmpty else {
                // No realized viewport (hidden or mid-rebuild pane): fall back to
                // the exact pass rather than leaving rows at a stale width.
                reflowBacklog.removeAll()
                measureAllRows()
                return false
            }
            let measured = measureViewport(visible)
            reflowBacklog = rows.indices.reversed().compactMap { index in
                needsHeight(at: index, width: measuredWidth) ? rows[index].id : nil
            }
            #if DEBUG
            MacConversationTableCounters.reflows &+= 1
            MacConversationTableCounters.reflowLow = measured.first ?? 0
            MacConversationTableCounters.reflowHigh = (measured.last ?? -1) + 1
            MacConversationTableCounters.deferredRemeasures &+= reflowBacklog.count
            #endif
            scheduleReflowSweep()
            return true
        }

        private func needsHeight(at index: Int, width: CGFloat) -> Bool {
            let row = rows[index]
            guard let cached = heights.measured[row.id] else { return true }
            // A width mismatch already settles staleness, and the backlog scan
            // over every row must not build a full content key per row per step.
            if abs(cached.key.width - width) > 0.25 { return true }
            guard let content = contentKey(for: row, isFirst: index == 0) else { return true }
            // Staleness includes style and content; zoom can leave the width unchanged.
            return cached.key != HeightKey(content: content, width: width)
        }

        @discardableResult
        private func measureViewport(_ indexes: IndexSet) -> IndexSet {
            guard let table, !indexes.isEmpty else { return [] }
            measuringViewport = true
            defer { measuringViewport = false }
            let anchor = followsLatest ? nil : currentAnchor()
            var visible = indexes
            var measured = IndexSet()
            while !visible.isEmpty {
                withoutAnimation { table.noteHeightOfRows(withIndexesChanged: visible) }
                restore(anchor)
                measured.formUnion(visible)
                // Widening can reveal more rows after heights shrink. Measure
                // them too, without taxing every step for offscreen neighbors.
                visible = visibleRowIndexes().subtracting(measured)
            }
            return measured
        }

        /// Pure style/text-scale change over unchanged row ids: rewrap the
        /// viewport now, settle the rest in the sweep. noteHeightOfRows
        /// re-measures heights but does not rebuild row content, so every
        /// realized row is also reloaded to show the new style; heights inside
        /// the viewport range are already exact, which leaves only the few
        /// realized rows outside it to be measured here.
        private func reflowRenderChange() {
            guard let table else { return }
            // Interface zoom moves the readable cap even if the native column
            // stays the same width. Use that new width for the deferred sweep.
            if canMeasure, measuredWidth > 1 { measuredWidth = measurementWidth }
            guard reflowViewportFirst() else { return }
            var realized = IndexSet()
            table.enumerateAvailableRowViews { _, row in realized.insert(row) }
            guard !realized.isEmpty else { return }
            withoutAnimation {
                table.reloadData(forRowIndexes: realized, columnIndexes: IndexSet(integer: 0))
            }
        }

        /// Drained after the drag stops, bottom-first so heights that only change
        /// the content length cannot shift the reading position.
        private func scheduleReflowSweep() {
            guard !reflowBacklog.isEmpty else { return }
            let generation = reflowGeneration
            reflowTask = Task { @MainActor [weak self] in
                // Every new width step cancels this task, so a drag costs one
                // sweep instead of one sweep per step.
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self, generation == self.reflowGeneration else { return }
                await self.drainReflow(generation: generation)
            }
        }

        private func drainReflow(generation: Int) async {
            guard let table else {
                reflowBacklog.removeAll()
                return
            }
            while !reflowBacklog.isEmpty, generation == reflowGeneration {
                guard abs(measurementWidth - measuredWidth) <= 0.25 else {
                    // The reader changed the width again; that pass owns the rewrite.
                    reflowBacklog.removeAll()
                    return
                }
                // A hidden or rebuilt table cannot host a measurement; the rows
                // keep their last height until the table is measurable again.
                guard canMeasure else { return }
                let count = min(Self.reflowBatchRows, reflowBacklog.count)
                let chunk = reflowBacklog.suffix(count)
                reflowBacklog.removeLast(count)
                let indexes = IndexSet(chunk.compactMap { indexByID[$0] }
                    .filter { needsHeight(at: $0, width: measuredWidth) })
                guard !indexes.isEmpty else { continue }
                // The table owns its row-height cache, so it must be the one to
                // invalidate: handing it these indexes makes it re-ask this
                // batch's heights now, and only this batch's.
                let anchor = followsLatest ? nil : currentAnchor()
                withoutAnimation { table.noteHeightOfRows(withIndexesChanged: indexes) }
                restore(anchor)
                #if DEBUG
                MacConversationTableCounters.reflowBatches &+= 1
                #endif
                // Let input, display and scrolling run between batches.
                await Task.yield()
            }
            if generation == reflowGeneration { reflowBacklog.removeAll() }
        }

        /// A displayed row reports its natural height. It only differs from the
        /// measured one when the row's own state changed (an image finished
        /// loading, a question was expanded); apply that as a content change.
        fileprivate func row(_ id: String, content: ContentKey?, reportedHeight height: CGFloat, width: CGFloat) {
            // Reports from a cell still showing older content are not news.
            guard table != nil, abs(width - rowWidth) <= 0.5,
                  let index = indexByID[id], let measured = heights.measured[id],
                  measured.key.content == content, abs(measured.key.width - measurementWidth(for: width)) <= 0.5,
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
            #if DEBUG
            let w1Start = DispatchTime.now().uptimeNanoseconds
            #endif
            let cell: RowCell
            #if DEBUG
            let w1IsNew: Bool
            if let reused = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell {
                cell = reused
                w1IsNew = false
            } else {
                cell = RowCell()
                w1IsNew = true
                // macOS 27 SwiftUI keeps hover/tooltip hit-test references to
                // hosting views; one freed while its window lives crashes the
                // next mouse movement. Cells live as long as the table (the
                // pool is bounded by the rows realized at once).
                cells.append(cell)
            }
            #else
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
            #endif
            let item = rows[row]
            cell.show(content(for: item, isFirst: row == 0, measuring: false), id: item.id)
            #if DEBUG
            Self.w1NoteViewFor((Double(DispatchTime.now().uptimeNanoseconds - w1Start) / 1_000_000), isNew: w1IsNew)
            #endif
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        private func contentKey(for row: MacConversationRow, isFirst: Bool) -> ContentKey? {
            guard let renderKey else { return nil }
            return ContentKey(value: row.value, mediaRevision: row.mediaRevision, isFirst: isFirst,
                              render: renderKey)
        }

        private func content(for row: MacConversationRow, isFirst: Bool, measuring: Bool) -> AnyView {
            let base = rowContent?(row) ?? AnyView(EmptyView())
            let contentKey = contentKey(for: row, isFirst: isFirst)
            let content = base
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatReadableColumn()
                // The lazy stack's spacing and content margins, now per row.
                .interfacePadding(.top, isFirst ? 0 : Space.xs)
                .padding(.horizontal, Self.rowHorizontalPadding)
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

        var navigationPosition: (id: String?, offset: CGFloat, followsLatest: Bool) {
            let anchor = currentAnchor()
            return (anchor?.id, anchor?.offset ?? 0, followsLatest)
        }

        /// Reuse row/offset anchoring after a browser return, including reflow.
        @discardableResult
        func restoreNavigationPosition(id: String?, offset: CGFloat, followsLatest: Bool) -> Bool {
            guard !rows.isEmpty, followsLatest || id.map({ indexByID[$0] != nil }) == true else { return false }
            setFollowsLatest(followsLatest)
            userHasScrolled = !followsLatest
            restore(id.map { Anchor(id: $0, offset: offset) })
            return true
        }

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

        private func setReadingTop(_ y: CGFloat) {
            guard let scroll else { return }
            let clip = scroll.contentView
            let maxTop = max(contentHeight - readingRect.height, 0)
            let origin = NSPoint(x: clip.bounds.minX, y: min(max(y, 0), maxTop) - insets.top)
            guard abs(clip.bounds.origin.y - origin.y) > 0.25 else { return }
            adjustingPosition = true
            defer { adjustingPosition = false }
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }

        private func setFollowsLatest(_ value: Bool) {
            guard followsLatest != value else { return }
            followsLatest = value
            let report = onFollowChange
            DispatchQueue.main.async { report?(value) }
        }

        private func requestLatest() {
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
            #if DEBUG
            Self.w1CloseBatch()
            #endif
            publishInspection()
            guard !adjustingPosition, !measuringViewport else { return }
            if !reflowBacklog.isEmpty { table?.needsLayout = true }
            if isReaderScrolling {
                updateFollowFromViewport()
                acknowledgeRead(force: false)
            }
            loadEarlierIfReading()
        }

        private func updateFollowFromViewport() {
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
                  let load = onLoadEarlier, !isAutoLoading, !autoLoadHeld,
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

        /// Prompt jumps land the target in one unanimated move (owner,
        /// 2026-10-19); row heights are exact, so no settle pass is needed.
        private func jump(to id: String) {
            guard table != nil, let index = indexByID[id] else { return }
            setFollowsLatest(false)
            userHasScrolled = true
            setReadingTop(jumpTarget(id, fallback: index))
            loadEarlierIfReading()
        }

        /// Lands the target row on the reading viewport's top edge.
        private func jumpTarget(_ id: String, fallback: Int) -> CGFloat {
            guard let table else { return 0 }
            return table.rect(ofRow: indexByID[id] ?? fallback).minY
        }

        // MARK: Helpers

        private func withoutAnimation(_ body: () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                body()
            }
        }

        #if DEBUG
        /// W1 attribution helpers. All batch state is DEBUG-only; the print
        /// gate keeps every other probe and test run quiet.
        fileprivate static func w1NoteViewFor(_ ms: Double, isNew: Bool) {
            MacConversationTableCounters.viewForCalls &+= 1
            MacConversationTableCounters.viewForMs += ms
            if ms > MacConversationTableCounters.viewForMaxMs { MacConversationTableCounters.viewForMaxMs = ms }
            if isNew { MacConversationTableCounters.viewForNewCells &+= 1 }
            w1BatchViews &+= 1
            if isNew { w1BatchNewCells &+= 1 }
            w1BatchViewMs += ms
            if ms > w1BatchViewMaxMs { w1BatchViewMaxMs = ms }
        }

        fileprivate static func w1NoteLayoutPass(_ ms: Double) {
            MacConversationTableCounters.layoutPasses &+= 1
            MacConversationTableCounters.layoutPassMs += ms
            if ms > MacConversationTableCounters.layoutMaxMs { MacConversationTableCounters.layoutMaxMs = ms }
            w1BatchLayouts &+= 1
            w1BatchLayoutMs += ms
        }

        fileprivate static func w1NoteRowLayout(_ ms: Double) {
            MacConversationTableCounters.rowLayouts &+= 1
            MacConversationTableCounters.rowLayoutMs += ms
            if ms > MacConversationTableCounters.rowLayoutMaxMs { MacConversationTableCounters.rowLayoutMaxMs = ms }
            w1BatchRowLayouts &+= 1
            w1BatchRowLayoutMs += ms
        }

        fileprivate static func w1NoteCellLayout(_ ms: Double) {
            w1BatchCellLayouts &+= 1
            w1BatchCellLayoutMs += ms
        }

        private static func w1CloseBatch() {
            w1BatchMakes = MacTextRowSwitchCounters.makes - w1PrevMakes
            w1BatchDismantles = MacTextRowSwitchCounters.dismantles - w1PrevDismantles
            w1BatchCorrections = MacConversationTableCounters.liveCorrections - w1PrevCorrections
            let active = w1BatchViews > 0 || w1BatchLayouts > 0 || w1BatchMeasures > 0
                || w1BatchRowLayouts > 0 || w1BatchCellLayouts > 0
                || w1BatchMakes > 0 || w1BatchDismantles > 0 || w1BatchCorrections > 0
            if Self.w1LogEnabled, active {
                print(String(format: "w1 batch #%d: views=%d newCells=%d viewFor=%6.1fms max=%5.1f layouts=%d layoutMs=%6.1f rowLayouts=%d rowMs=%7.1f cellLayouts=%d cellMs=%6.1f measures=%d measureMs=%5.1f makes=+%d dismantles=+%d corrections=+%d",
                             w1BatchIndex, w1BatchViews, w1BatchNewCells, w1BatchViewMs, w1BatchViewMaxMs,
                             w1BatchLayouts, w1BatchLayoutMs, w1BatchRowLayouts, w1BatchRowLayoutMs,
                             w1BatchCellLayouts, w1BatchCellLayoutMs,
                             w1BatchMeasures, w1BatchMeasureMs,
                             w1BatchMakes, w1BatchDismantles, w1BatchCorrections))
                fflush(stdout)
            }
            w1BatchIndex &+= 1
            w1BatchViews = 0
            w1BatchNewCells = 0
            w1BatchViewMs = 0
            w1BatchViewMaxMs = 0
            w1BatchLayouts = 0
            w1BatchLayoutMs = 0
            w1BatchRowLayouts = 0
            w1BatchRowLayoutMs = 0
            w1BatchCellLayouts = 0
            w1BatchCellLayoutMs = 0
            w1BatchMeasures = 0
            w1BatchMeasureMs = 0
            w1PrevMakes = MacTextRowSwitchCounters.makes
            w1PrevDismantles = MacTextRowSwitchCounters.dismantles
            w1PrevCorrections = MacConversationTableCounters.liveCorrections
            w1BatchMakes = 0
            w1BatchDismantles = 0
            w1BatchCorrections = 0
        }
        #endif

        private func publishInspection() {
            #if DEBUG
            guard let key = environment.macConversationTextDocument?.debugIdentity, let table else { return }
            let reading = readingRect
            let ids = readingRowIndexes().map { rows[$0].id }
            MacChatScrollGeometryProbe.latest[key, default: [:]].merge([
                "visibleMinY": reading.minY - insets.top,
                "readingMinY": reading.minY, "insetsTop": insets.top,
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
            .environment(\.chatWorkingDirectory, environment.chatWorkingDirectory)
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
            onLoadEarlier: onLoadEarlier,
            onFollowChange: { followsLatest = $0; onFollowChange($0) }
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
        .overlay(alignment: .bottom) {
            if !followsLatest {
                HStack {
                    Spacer(minLength: 0)
                    ChatJumpToLatestButton { latestBump += 1 }
                }
                .chatReadableColumn()
            }
        }
    }
}

#if DEBUG
/// Row measurement work and post-display corrections, for inspections.
@MainActor
enum MacConversationTableCounters {
    static var measurements = 0
    static var liveCorrections = 0
    static var wheelEvents = 0
    /// W1 first-scroll attribution: height cache behavior and realization cost.
    static var heightQueries = 0
    static var heightMisses = 0
    static var measureMs: Double = 0
    static var viewForCalls = 0
    static var viewForNewCells = 0
    static var viewForMs: Double = 0
    static var viewForMaxMs: Double = 0
    static var layoutPasses = 0
    static var layoutPassMs: Double = 0
    static var layoutMaxMs: Double = 0
    static var rowLayouts = 0
    static var rowLayoutMs: Double = 0
    static var rowLayoutMaxMs: Double = 0
    /// Rows postponed to a post-drag sweep on width changes.
    static var deferredRemeasures = 0
    static var reflows = 0
    static var reflowLow = 0
    static var reflowHigh = 0
    static var reflowBatches = 0
}
#endif
#endif
