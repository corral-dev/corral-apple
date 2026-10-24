import AppKit
import Observation

/// Search and visit state belong to the host, not a transient sheet or socket.
@MainActor @Observable
final class MacSearchState {
    var query = ""
    var selection: String?
    /// First visible result row, owned outside the sheet's view lifetime.
    @ObservationIgnored var scrollRow: Int?
    @ObservationIgnored private weak var nativeScroll: NSScrollView?
    @ObservationIgnored private var scrollObserver: NSObjectProtocol?
    #if DEBUG
    @ObservationIgnored var inspectionScrollAttached = false
    #endif
    let store = FulltextSearchStore()

    /// Observe the mounted native results list. A control-free background view
    /// supplies the scroll view; AppKit still owns scrolling and clipping.
    func attachScroll(_ scroll: NSScrollView) {
        guard nativeScroll !== scroll else { return }
        detachScroll()
        nativeScroll = scroll
        #if DEBUG
        inspectionScrollAttached = true
        #endif
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll else { return }
                    self.recordScrollRow(scroll)
                }
            }
    }

    private func firstVisibleRow(in table: NSTableView, scroll: NSScrollView) -> Int? {
        let clip = scroll.contentView
        let converted = table.convert(clip.bounds, from: clip)
        let range = table.rows(in: converted)
        if range.location != NSNotFound, range.length > 0 { return range.location }
        let anchor = table.row(at: NSPoint(x: 0, y: converted.minY + 1))
        return anchor >= 0 ? anchor : nil
    }

    private func recordScrollRow(_ scroll: NSScrollView) {
        guard let table = scroll.documentView as? NSTableView,
              let row = firstVisibleRow(in: table, scroll: scroll) else { return }
        scrollRow = row
    }

    func detachScroll() {
        if let nativeScroll { recordScrollRow(nativeScroll) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        nativeScroll = nil
        #if DEBUG
        inspectionScrollAttached = false
        #endif
    }

    func resetScroll() {
        detachScroll()
        scrollRow = nil
    }

    #if DEBUG
    var inspectionScrollVisible: Bool { nativeScroll?.window?.isVisible == true }

    @discardableResult
    func inspectScroll(toRow row: Int? = nil) -> Int? {
        guard let nativeScroll, let table = nativeScroll.documentView as? NSTableView else { return nil }
        inspectionScrollAttached = true
        if let row {
            table.scrollRowToVisible(row)
            recordScrollRow(nativeScroll)
        }
        inspectionScrollRow = firstVisibleRow(in: table, scroll: nativeScroll)
        let converted = table.convert(nativeScroll.contentView.bounds, from: nativeScroll.contentView)
        inspectionScrollDiagnostics = [
            "visibleRect": NSStringFromRect(table.visibleRect),
            "rowRange": NSStringFromRange(table.rows(in: table.visibleRect)),
            "clipBounds": NSStringFromRect(nativeScroll.contentView.bounds),
            "converted": NSStringFromRect(converted),
        ]
        inspectionScrollClipHeight = nativeScroll.contentView.bounds.height
        inspectionScrollDocumentHeight = Double(nativeScroll.documentView?.frame.height ?? 0)
        return inspectionScrollRow
    }
    var inspectionScrollRow: Int?
    var inspectionScrollClipHeight: Double = 0
    var inspectionScrollDocumentHeight: Double = 0
    var inspectionScrollDiagnostics: [String: String] = [:]
    #endif
}

@MainActor @Observable
final class MacNavigationState {
    enum ReadingPosition {
        case chat(id: String?, offset: Double, followsLatest: Bool, generation: Int)
        case terminal(row: Int, followsLatest: Bool)
    }

    @MainActor @Observable
    final class HostState {
        var history = SessionNavigationHistory()
        let search = MacSearchState()
        var revealKey: String?
        var revealSerial = 0
        @ObservationIgnored var reading: [String: ReadingPosition] = [:]
        #if DEBUG
        var inspectionSidebarKey: String?
        var inspectionSidebar: [String: Bool] = [:]
        var inspectionEvents: [String] = []
        #endif
    }

    private(set) var host = HostState()
    var isNavigating = false
    @ObservationIgnored var requestID = UUID()
    @ObservationIgnored private var hosts: [String: HostState] = [:]

    func selectHost(_ id: String?) {
        requestID = UUID()
        isNavigating = false
        guard let id else { host = HostState(); return }
        if let existing = hosts[id] { host = existing }
        else { let created = HostState(); hosts[id] = created; host = created }
    }

    func visit(_ key: String?) {
        requestID = UUID()
        isNavigating = false
        guard let key else { return }
        host.history.visit(key)
        let retained = Set(host.history.keys)
        host.reading = host.reading.filter { retained.contains($0.key) }
    }

    func reveal(_ key: String) {
        host.revealKey = key
        host.revealSerial &+= 1
    }
}
