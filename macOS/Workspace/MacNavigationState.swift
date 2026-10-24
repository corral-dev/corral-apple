import AppKit
import Observation

/// Search and visit state belong to the host, not a transient sheet or socket.
@MainActor @Observable
final class MacSearchState {
    var query = ""
    var selection: String?
    @ObservationIgnored var scrollOffset: Double?
    @ObservationIgnored private weak var nativeScroll: NSScrollView?
    @ObservationIgnored private var scrollObserver: NSObjectProtocol?
    @ObservationIgnored private var restoringScroll = false
    #if DEBUG
    @ObservationIgnored var inspectionScrollAttached = false
    @ObservationIgnored var inspectionScrollRestoreApplied: Double?
    #endif
    let store = FulltextSearchStore()

    func attachScroll(_ scroll: NSScrollView) {
        guard nativeScroll !== scroll else { return }
        detachScroll()
        nativeScroll = scroll
        #if DEBUG
        inspectionScrollAttached = true
        #endif
        restoringScroll = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll, !self.restoringScroll else { return }
                    self.scrollOffset = scroll.contentView.bounds.minY
                }
            }
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, self.nativeScroll === scroll else { return }
            if let offset = self.scrollOffset {
                var rect = scroll.contentView.bounds
                rect.origin.y = offset
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(rect).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                #if DEBUG
                self.inspectionScrollRestoreApplied = scroll.contentView.bounds.minY
                #endif
            }
            self.restoringScroll = false
        }
    }

    func detachScroll() {
        if let nativeScroll, !restoringScroll { scrollOffset = nativeScroll.contentView.bounds.minY }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        nativeScroll = nil
        restoringScroll = false
        #if DEBUG
        inspectionScrollAttached = false
        inspectionScrollRestoreApplied = nil
        #endif
    }

    func resetScroll() {
        detachScroll()
        scrollOffset = nil
    }

    #if DEBUG
    func inspectScroll(to offset: Double? = nil) {
        guard let nativeScroll else { return }
        inspectionScrollAttached = true
        if let offset {
            var rect = nativeScroll.contentView.bounds
            rect.origin.y = offset
            nativeScroll.contentView.scroll(to: nativeScroll.contentView.constrainBoundsRect(rect).origin)
            nativeScroll.reflectScrolledClipView(nativeScroll.contentView)
        }
        inspectionScrollOffset = Double(nativeScroll.contentView.bounds.minY)
        inspectionScrollClipHeight = nativeScroll.contentView.bounds.height
        inspectionScrollDocumentHeight = Double(nativeScroll.documentView?.frame.height ?? 0)
    }
    var inspectionScrollOffset: Double?
    var inspectionScrollClipHeight: Double = 0
    var inspectionScrollDocumentHeight: Double = 0
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
