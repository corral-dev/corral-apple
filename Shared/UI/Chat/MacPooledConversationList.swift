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
/// Off-screen rows have no views at all. Row heights resolve through the same
/// detached measurement path via Auto Layout fitting, so no height math is
/// duplicated here.
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
        let scroll = NSScrollView()
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
        // Automatic heights measure cells without a settled width and stick;
        // the delegate below resolves every row explicitly instead.
        table.usesAutomaticRowHeights = false
        table.rowHeight = 44
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        scroll.documentView = table
        coordinator.reloadAllRows()
        coordinator.scrollToBottom(animated: false)
        coordinator.observeScroll(of: scroll)
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
        private var hosting: NSHostingView<AnyView>?

        func setRoot(_ root: AnyView) {
            if let hosting {
                hosting.rootView = root
            } else {
                let created = NSHostingView(rootView: root)
                created.frame = bounds
                created.autoresizingMask = [.width, .height]
                addSubview(created)
                hosting = created
            }
        }

        override func layout() {
            super.layout()
            hosting?.frame = bounds
        }
    }

    /// Plain single-column table; all behavior lives in the coordinator so
    /// the view stays free of product logic.
    final class PooledConversationTable: NSTableView {
        weak var coordinator: Coordinator?
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: PooledConversationTable?
        private var rows: [MacPooledRow] = []
        private var lastRows: [MacPooledRow] = []
        private var lastDetailSourceID: ObjectIdentifier?
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
        private var scrollObserver: NSObjectProtocol?
        private var jumpSerial = 0
        private var didInitialScroll = false
        // Row heights keyed per row by geometry context. A hit returns
        // instantly; a context mismatch returns the last height (fast during
        // resize drags) and display converges it (see didAdd). New rows are
        // estimated once via detached text measurement plus stable chrome.
        private struct HeightEntry {
            var width: CGFloat
            var interfaceScale: CGFloat
            var sessionTextScale: CGFloat
            var document: ObjectIdentifier?
            var height: CGFloat

            func matches(width: CGFloat, coordinator: Coordinator) -> Bool {
                abs(width - self.width) < 0.5
                    && interfaceScale == coordinator.interfaceScale
                    && sessionTextScale == coordinator.sessionTextScale
                    && document == coordinator.document.map(ObjectIdentifier.init)
            }
        }
        private var heightEntries: [String: HeightEntry] = [:]

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
            let width = tableView.bounds.width
            let id = rows[row].id
            if let entry = heightEntries[id], entry.matches(width: width, coordinator: self) {
                return entry.height
            }
            if let entry = heightEntries[id] {
                // Stale geometry: serve fast, converge on display.
                return entry.height
            }
            let estimated = estimateHeight(for: rows[row], tableWidth: max(width, 1))
            heightEntries[id] = HeightEntry(width: max(width, 1), interfaceScale: interfaceScale,
                                            sessionTextScale: sessionTextScale,
                                            document: document.map(ObjectIdentifier.init),
                                            height: estimated)
            return estimated
        }

        /// Detached text measurement (shared cache) plus stable chrome. Exact
        /// for the dominant text term; display corrects the remainder.
        private func estimateHeight(for row: MacPooledRow, tableWidth: CGFloat) -> CGFloat {
            let font = Typography.sessionUIFont(.bubbleBody, scale: sessionTextScale * interfaceScale)
            switch row {
            case .timeline(let item):
                let gap = gaps[item.id] ?? 0
                switch item {
                case .message(let message):
                    let isUser = message.role.lowercased() == "user"
                    let column = min(tableWidth - 2 * Space.base, ChatLayout.readableWidth ?? tableWidth)
                    let textWidth = max(column - (isUser ? 2 * Space.base : 0), 40)
                    var textHeight = font.pointSize + 10
                    if document?.text(for: message.seq) != nil,
                       let measurement = document?.measurement(for: message.seq),
                       let text = document?.text(for: message.seq) {
                        let measured = measurement.size(for: text, font: font, width: textWidth)
                        textHeight = ceil(max(measured.height, font.pointSize + 4))
                    }
                    // Stable chrome; images/failure cards are rare and converge
                    // on display via didAdd below.
                    var chrome = gap + (isUser ? 2 * Space.md : Space.xs)
                    if separators[item.id] != nil { chrome += 24 * interfaceScale }
                    return ceil(textHeight + chrome)
                case .toolGroup:
                    return ceil(gap + 44)
                }
            case .prompts:
                return 200
            case .activity:
                return 36
            }
        }

        /// Display converges stale estimates: re-estimate at the settled
        /// width when a row appears with an entry from another context.
        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard rows.indices.contains(row) else { return }
            let width = tableView.bounds.width
            let id = rows[row].id
            guard let entry = heightEntries[id], !entry.matches(width: width, coordinator: self) else { return }
            heightEntries[id] = HeightEntry(width: width, interfaceScale: interfaceScale,
                                            sessionTextScale: sessionTextScale,
                                            document: document.map(ObjectIdentifier.init),
                                            height: estimateHeight(for: rows[row], tableWidth: max(width, 1)))
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: PooledRowCell.identifier, owner: nil) as? PooledRowCell) ?? PooledRowCell()
            cell.identifier = PooledRowCell.identifier
            cell.setRoot(AnyView(rowContent(for: rows[row])))
            return cell
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
            .environment(\.macConversationTextDocument, document)
            .chatReadableColumn()
        }

        // MARK: - Updates

        /// Diff by stable id, then by value: streaming edits reload one row,
        /// structural changes rebuild and restore position. Changed rows drop
        /// their height entries so heights re-estimate instead of going stale.
        func syncRows() {
            guard let table else { return }
            let newIDs = rows.map(\.id)
            let oldIDs = lastRows.map(\.id)
            if newIDs != oldIDs || detailSourceID != lastDetailSourceID {
                let anchor = topVisibleID()
                let oldByID = Dictionary(uniqueKeysWithValues: lastRows.map { ($0.id, $0) })
                for row in rows where row != oldByID[row.id] {
                    heightEntries[row.id] = nil
                }
                lastRows = rows
                lastDetailSourceID = detailSourceID
                table.reloadData()
                if followsLatest {
                    scrollToBottom(animated: false)
                } else if let anchor, let index = newIDs.firstIndex(of: anchor) {
                    table.scrollRowToVisible(index)
                }
                return
            }
            var changed = IndexSet()
            for (index, row) in rows.enumerated() where row != lastRows[index] {
                changed.insert(index)
                heightEntries[row.id] = nil
            }
            lastRows = rows
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
        }

        func reloadAllRows() {
            lastRows = rows
            lastDetailSourceID = detailSourceID
            table?.reloadData()
        }

        func consumeScrollIntents(scrollToMessageID: Binding<String?>, scrollToLatestRequest: Int) {
            guard let table else { return }
            if let target = scrollToMessageID.wrappedValue {
                if let index = rows.map(\.id).firstIndex(of: target) {
                    // Estimates drift over dozens of rows; warm the landing
                    // zone first so the jump lands, then re-pin once display
                    // has converged heights.
                    ensureHeights(around: index, radius: 10)
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn:
                        max(0, index - 10)..<min(rows.count, index + 11)))
                    table.scrollRowToVisible(index)
                    jumpSerial &+= 1
                    let serial = jumpSerial
                    let targetID = target
                    DispatchQueue.main.async { [weak self] in
                        guard let self, serial == self.jumpSerial,
                              let table = self.table,
                              let settled = self.rows.map(\.id).firstIndex(of: targetID) else { return }
                        table.scrollRowToVisible(settled)
                    }
                }
                DispatchQueue.main.async { scrollToMessageID.wrappedValue = nil }
            }
            if scrollToLatestRequest != lastScrollRequest {
                lastScrollRequest = scrollToLatestRequest
                showLatest()
            }
        }

        /// Measure the landing zone synchronously so programmatic scrolls use
        /// real heights instead of accumulated estimates.
        private func ensureHeights(around index: Int, radius: Int) {
            guard let table else { return }
            let width = max(table.bounds.width, 1)
            for i in max(0, index - radius)..<min(rows.count, index + radius + 1) {
                let id = rows[i].id
                heightEntries[id] = HeightEntry(width: width, interfaceScale: interfaceScale,
                                                sessionTextScale: sessionTextScale,
                                                document: document.map(ObjectIdentifier.init),
                                                height: estimateHeight(for: rows[i], tableWidth: width))
            }
        }

        // MARK: - Scrolling

        func observeScroll(of scroll: NSScrollView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in self?.scrollGeometryChanged(scroll: scroll) }
            scroll.contentView.postsBoundsChangedNotifications = true
        }

        func teardown(scroll: NSScrollView) {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scroll.contentView.postsBoundsChangedNotifications = false
            table = nil
        }

        private func scrollGeometryChanged(scroll: NSScrollView) {
            guard let table else { return }
            let visible = scroll.contentView.documentVisibleRect
            // The mount-time scroll request lands before layout exists; pin
            // the initial position on the first valid geometry instead. Later
            // explicit jumps always arrive after mount and win.
            if !didInitialScroll, visible.height > 0, table.numberOfRows > 0 {
                didInitialScroll = true
                scrollToBottom(animated: false)
                return
            }
            if abs(table.bounds.width - lastTableWidth) > 0.5 {
                lastTableWidth = table.bounds.width
                // Refresh visible rows now; offscreen rows converge on display
                // instead of re-estimating the whole history mid-drag.
                let visibleIndexes = table.rows(in: visible)
                if visibleIndexes.location != NSNotFound, visibleIndexes.length > 0 {
                    let range = visibleIndexes.location..<(visibleIndexes.location + visibleIndexes.length)
                    for index in range where rows.indices.contains(index) {
                        heightEntries[rows[index].id] = nil
                    }
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: range))
                }
            }
            if !userHasScrolled, visible.height > 0 { userHasScrolled = true }
            // Table coordinates grow upward with row 0 (oldest) at the top:
            // the bottom edge is minY, the top edge is maxY.
            let nearBottom = visible.minY <= 44
            if followsLatest != nearBottom {
                followsLatest = nearBottom
                onFollowChange?(nearBottom)
            }
            loadEarlierIfReading(scroll: scroll, visible: visible)
        }

        private func topVisibleID() -> String? {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return nil }
            let indexes = table.rows(in: clip.documentVisibleRect)
            guard indexes.location != NSNotFound, rows.indices.contains(indexes.location) else { return nil }
            return rows[indexes.location].id
        }

        private func loadEarlierIfReading(scroll: NSScrollView, visible: CGRect) {
            guard let load = onNeedEarlier, !isAutoLoading, !autoLoadHeld else { return }
            let contentHeight = scroll.documentView?.frame.height ?? 0
            let containerHeight = scroll.contentView.bounds.height
            guard containerHeight > 0, contentHeight > 0 else { return }
            // Short transcripts fill immediately; readers near the top page earlier.
            let overflows = contentHeight - containerHeight > 1
            let distanceFromTop = contentHeight - visible.maxY
            guard !overflows || (userHasScrolled && distanceFromTop < containerHeight) else { return }
            isAutoLoading = true
            let anchor = followsLatest ? nil : topVisibleID()
            Task { @MainActor in
                let loaded = await load()
                if loaded, let anchor, let index = self.rows.map(\.id).firstIndex(of: anchor) {
                    self.ensureHeights(around: index, radius: 10)
                    self.table?.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn:
                        max(0, index - 10)..<min(self.rows.count, index + 11)))
                    self.table?.scrollRowToVisible(index)
                }
                if !loaded { self.autoLoadHeld = true }
                self.isAutoLoading = false
            }
        }

        private func showLatest() {
            followsLatest = true
            if !rows.isEmpty {
                ensureHeights(around: rows.count - 1, radius: 12)
                table?.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn:
                    max(0, rows.count - 13)..<rows.count))
            }
            scrollToBottom(animated: false)
        }

        func scrollToBottom(animated: Bool) {
            guard let table, table.numberOfRows > 0 else { return }
            let last = table.numberOfRows - 1
            if animated {
                NSAnimationContext.runAnimationGroup { _ in
                    table.scrollRowToVisible(last)
                }
            } else {
                table.scrollRowToVisible(last)
            }
        }

        func scroll(to id: String, centered: Bool) {
            guard let table, let index = rows.map(\.id).firstIndex(of: id) else { return }
            if centered, let clip = table.enclosingScrollView?.contentView,
               let rowView = table.rowView(atRow: index, makeIfNecessary: false) {
                let visibleHeight = clip.documentVisibleRect.height
                let contentHeight = table.bounds.height
                let y = rowView.frame.midY - visibleHeight / 2
                clip.scroll(to: NSPoint(x: 0, y: min(max(y, 0), max(contentHeight - visibleHeight, 0))))
                table.enclosingScrollView?.reflectScrolledClipView(clip)
            } else {
                table.scrollRowToVisible(index)
            }
        }
    }
}
#endif
