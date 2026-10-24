import Foundation
import Observation

/// Search and visit state belong to the host, not a transient sheet or socket.
@MainActor @Observable
final class MacSearchState {
    var query = ""
    var selection: String?
    let store = FulltextSearchStore()
}

@MainActor @Observable
final class MacNavigationState {
    enum ReadingPosition {
        case chat(id: String?, offset: Double, followsLatest: Bool, generation: Int)
        case terminal(Double)
    }

    @MainActor @Observable
    final class HostState {
        var history = SessionNavigationHistory()
        let search = MacSearchState()
        var revealKey: String?
        var revealSerial = 0
        @ObservationIgnored var reading: [String: ReadingPosition] = [:]
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
