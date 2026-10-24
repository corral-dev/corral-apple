import Foundation
import Observation

/// 会话列表的分组、搜索与排序状态。
///
/// 分组规则：「等你回复」单独置顶，再是用户手动置顶，最后按今天 / 昨天 / 更早切时间档。
@MainActor
@Observable
final class SessionListStore {
    enum Section: Identifiable, Equatable {
        case waiting([SessionSummary])
        case pinned([SessionSummary])
        case today([SessionSummary])
        case yesterday([SessionSummary])
        case earlier([SessionSummary])

        var id: String {
            switch self {
            case .waiting: "waiting"
            case .pinned: "pinned"
            case .today: "today"
            case .yesterday: "yesterday"
            case .earlier: "earlier"
            }
        }

        var sessions: [SessionSummary] {
            switch self {
            case let .waiting(items), let .pinned(items), let .today(items),
                 let .yesterday(items), let .earlier(items):
                items
            }
        }
    }

    private(set) var sections: [Section] = []
    private(set) var version: String = ""
    var searchQuery: String = "" {
        didSet {
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchKeys = nil
                lastServerQuery = ""
                pruneUnownedRecords()
            }
            rebuildSections()
        }
    }

    private var hostID: String = ""
    /// One metadata record per host and canonical session identity. Window membership
    /// is kept separately so search and an opened detail never own competing copies.
    private var recordsByKey: [String: SessionSummary] = [:]
    private var listKeys: [String] = []
    private var searchKeys: [String]?
    private var lastServerQuery: String = ""
    private var openedKeys: Set<String> = []
    /// Explicit visits outlive replacement host windows; search previews do not.
    private var revealedKeys: [String] = []
    static let maxRevealedSessions = 100
    /// Provisional → canonical redirects so an open detail keeps resolving after migrate.
    private var aliasByKey: [String: String] = [:]
    private var revisionByKey: [String: UInt64] = [:]
    private var acceptedRevision: UInt64 = 0
    /// Host-confirmed deletions outlive reconnects and delayed list/search events.
    private var deletedKeys: Set<String> = []
    /// Sessions acknowledged on this client while red, with the activity time seen then.
    /// A host row still saying unread for that activity is a stale echo of the
    /// pre-read state; newer activity brings the dot back.
    private var locallyReadMtime: [String: Double] = [:]
    /// Bumped on every metadata merge so SwiftUI detail headers invalidate reliably.
    private(set) var metadataEpoch: UInt64 = 0
    private(set) var presentationDate: Date
    private(set) var presentationCalendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let currentCalendar: () -> Calendar

    init(now: @escaping () -> Date = { Date() }, calendar: @escaping () -> Calendar = { .current }) {
        self.now = now
        currentCalendar = calendar
        presentationDate = now()
        presentationCalendar = calendar()
    }

    /// Date buckets are local presentation, independent of the host's data version.
    func refreshCalendar() {
        if updateCalendarContext() { rebuildSections() }
    }

    @discardableResult
    private func updateCalendarContext() -> Bool {
        let date = now()
        let calendar = currentCalendar()
        guard calendar != presentationCalendar
            || calendar.startOfDay(for: date) != calendar.startOfDay(for: presentationDate) else { return false }
        presentationDate = date
        presentationCalendar = calendar
        return true
    }

    func loadPersisted(hostID: String) {
        refreshCalendar()
        guard self.hostID != hostID else { return }
        if self.hostID != hostID {
            recordsByKey.removeAll()
            listKeys.removeAll()
            searchKeys = nil
            lastServerQuery = ""
            openedKeys.removeAll()
            revealedKeys.removeAll()
            aliasByKey.removeAll()
            revisionByKey.removeAll()
            acceptedRevision = 0
            deletedKeys.removeAll()
            locallyReadMtime.removeAll()
            version = ""
            searchQuery = ""
            metadataEpoch &+= 1
        }
        self.hostID = hostID
        guard let cached = SessionListCache.load(hostID: hostID) else {
            rebuildSections()
            return
        }
        version = cached.version
        listKeys = Self.uniqueKeys(cached.sessions.map(\.key))
        revealedKeys = Array(Self.uniqueKeys(cached.revealedKeys ?? []).suffix(Self.maxRevealedSessions))
        for session in cached.sessions where ActiveRuntimeVisibility.isListVisible(session) {
            recordsByKey[session.key] = session
        }
        rebuildSections()
    }

    /// Host revisions are process-local. A replacement connection starts a new
    /// ordering epoch without discarding offline rows or titles.
    func beginConnectionEpoch() {
        acceptedRevision = 0
        revisionByKey.removeAll()
        version = ""
    }

    func applyListResponse(_ response: SessionsListResponse, persist: Bool = true) {
        refreshCalendar()
        if response.unchanged {
            if let next = response.version, !next.isEmpty {
                version = next
            }
            return
        }
        replaceWindow(response.sessions, version: response.version, revision: response.revision, persist: persist)
    }

    func updateSessions(_ sessions: [SessionSummary]) {
        replaceWindow(sessions, version: version, revision: nil, persist: true)
    }

    func applySearchHits(_ sessions: [SessionSummary], query: String) {
        lastServerQuery = query
        for session in sessions { merge(session) }
        searchKeys = Self.uniqueKeys(sessions.map { resolvedKey($0.key) })
        pruneUnownedRecords()
        rebuildSections()
    }

    func patchSession(_ session: SessionSummary, revision: UInt64? = nil) {
        let key = resolvedKey(session.key)
        let normalized = session.key == key ? session : session.replacingKey(key)
        if !listKeys.contains(key) { listKeys.append(key) }
        merge(normalized, revision: revision)
        persistIfNeeded()
        rebuildSections()
    }

    func applySessionEvent(_ session: SessionSummary, revision: UInt64? = nil) {
        guard revision.map({ $0 >= acceptedRevision }) ?? true else { return }
        if let revision { acceptedRevision = revision }
        let key = resolvedKey(session.key)
        let normalized = session.key == key ? session : session.replacingKey(key)
        if !listKeys.contains(key), openedKeys.contains(key) || openedKeys.contains(session.key) {
            // A watched detail may legitimately be outside the current list window.
            // Keep its record without changing list membership.
            merge(normalized, revision: revision)
            rebuildSections()
        } else {
            patchSession(normalized, revision: revision)
        }
    }

    func removeSession(key: String) {
        let resolved = resolvedKey(key)
        deletedKeys.formUnion([key, resolved])
        for (alias, target) in aliasByKey where target == key || target == resolved {
            deletedKeys.insert(alias)
        }
        listKeys.removeAll { $0 == key || $0 == resolved }
        searchKeys?.removeAll { $0 == key || $0 == resolved }
        openedKeys.remove(key)
        openedKeys.remove(resolved)
        revealedKeys.removeAll { $0 == key || $0 == resolved }
        recordsByKey[key] = nil
        recordsByKey[resolved] = nil
        revisionByKey[key] = nil
        revisionByKey[resolved] = nil
        locallyReadMtime[key] = nil
        locallyReadMtime[resolved] = nil
        aliasByKey[key] = nil
        for (alias, target) in aliasByKey where target == key || target == resolved {
            aliasByKey[alias] = nil
        }
        metadataEpoch &+= 1
        persistIfNeeded()
        rebuildSections()
    }

    /// Opening or manually scrolling a session clears red here before the host
    /// confirms. The result gates the scroll path's RPC, avoiding per-frame writes.
    @discardableResult
    func markReadLocally(key: String) -> Bool {
        let key = resolvedKey(key)
        guard let current = recordsByKey[key], current.isUnread else { return false }
        locallyReadMtime[key] = current.mtime
        recordsByKey[key] = current.clearingUnread()
        metadataEpoch &+= 1
        persistIfNeeded()
        rebuildSections()
        return true
    }

    func session(for key: String) -> SessionSummary? {
        guard let found = recordsByKey[resolvedKey(key)],
              ActiveRuntimeVisibility.isListVisible(found)
        else { return nil }
        return found
    }

    /// Deleted on this client; search results must not resurrect it.
    func isDeleted(_ key: String) -> Bool {
        deletedKeys.contains(key) || deletedKeys.contains(resolvedKey(key))
    }

    func rememberOpened(_ session: SessionSummary) {
        openedKeys.insert(session.key)
        openedKeys.insert(resolvedKey(session.key))
    }

    /// A deliberate open joins ordinary navigation without modifying activity.
    /// Keep preview retention separate: rendering a search row is not a visit.
    func revealSession(_ session: SessionSummary) {
        guard !isDeleted(session.key), ActiveRuntimeVisibility.isListVisible(session) else { return }
        let key = resolvedKey(session.key)
        revealedKeys.removeAll { $0 == key }
        revealedKeys.append(key)
        if revealedKeys.count > Self.maxRevealedSessions {
            revealedKeys.removeFirst(revealedKeys.count - Self.maxRevealedSessions)
        }
        merge(session.key == key ? session : session.replacingKey(key))
        rememberOpened(session)
        pruneUnownedRecords()
        persistIfNeeded()
        rebuildSections()
    }

    func forgetOpened(key: String) {
        openedKeys.remove(key)
        openedKeys.remove(resolvedKey(key))
        pruneUnownedRecords()
    }

    /// Decode a single-session host patch from either `summary` or `session` object shapes.
    static func sessionPatch(from eventData: [String: Any]) -> (SessionSummary, UInt64?)? {
        let patch: [String: Any]?
        if let summary = eventData["summary"] as? [String: Any] {
            patch = summary
        } else if let session = eventData["session"] as? [String: Any] {
            patch = session
        } else {
            patch = nil
        }
        guard let patch,
              let session = try? RemoteJSONDecoder.decode(SessionSummary.self, from: patch)
        else { return nil }
        return (session, revision(from: eventData))
    }

    static func revision(from eventData: [String: Any]) -> UInt64? {
        if let number = eventData["revision"] as? NSNumber {
            return UInt64(max(0, number.int64Value))
        }
        if let value = eventData["revision"] as? Int {
            return UInt64(max(0, value))
        }
        if let value = eventData["revision"] as? Double {
            return UInt64(max(0, value))
        }
        if let number = eventData["epoch"] as? NSNumber {
            return UInt64(max(0, number.int64Value))
        }
        return nil
    }

    /// The canonical key a provisional key was promoted to (itself otherwise).
    func resolvedKey(_ key: String) -> String {
        var current = key
        var seen = Set<String>()
        while let next = aliasByKey[current], !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }

    /// Canonical host-window projection for filter choices: every visible
    /// session in this window regardless of text search. Read-only; view
    /// filters and search apply on top of it, so choices stay available while
    /// search narrows the displayed rows.
    var windowSessions: [SessionSummary] {
        browsableKeys.compactMap { recordsByKey[$0] }.filter {
            ActiveRuntimeVisibility.isListVisible($0)
        }
    }

    private var browsableKeys: [String] { Self.uniqueKeys(listKeys + revealedKeys) }

    var filteredSessions: [SessionSummary] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceKeys: [String]
        if needle.isEmpty { sourceKeys = browsableKeys }
        else if lastServerQuery == searchQuery, let hits = searchKeys { sourceKeys = hits }
        else { sourceKeys = browsableKeys }
        return sourceKeys.compactMap { recordsByKey[$0] }.filter { session in
            ActiveRuntimeVisibility.isListVisible(session)
                && (needle.isEmpty || session.matches(query: searchQuery))
        }
    }

    var waitingCount: Int {
        browsableKeys.compactMap { recordsByKey[$0] }.filter {
            ActiveRuntimeVisibility.isListVisible($0)
                && SessionPresentation.activityMarker(for: $0) == .waiting
        }.count
    }

    private func replaceWindow(
        _ sessions: [SessionSummary],
        version: String?,
        revision: UInt64?,
        persist: Bool
    ) {
        if let revision, revision < acceptedRevision { return }
        if let revision { acceptedRevision = revision }
        listKeys = Self.uniqueKeys(sessions.map { resolvedKey($0.key) })
        for session in sessions { merge(session, revision: revision) }
        if let next = version, !next.isEmpty {
            self.version = next
        }
        pruneUnownedRecords()
        if persist { persistIfNeeded() }
        rebuildSections()
    }

    /// Current surfaces own metadata; historical searches are not a second archive.
    private func pruneUnownedRecords() {
        let retained = Set(browsableKeys + (searchKeys ?? [])).union(openedKeys.map { resolvedKey($0) })
        for key in recordsByKey.keys where !retained.contains(key) {
            recordsByKey[key] = nil
            revisionByKey[key] = nil
            locallyReadMtime[key] = nil
        }
        for (alias, target) in aliasByKey where !retained.contains(target) {
            aliasByKey[alias] = nil
        }
    }

    private func persistIfNeeded() {
        guard !hostID.isEmpty else { return }
        SessionListCache.save(
            hostID: hostID,
            snapshot: SessionListSnapshot(
                version: version,
                sessions: browsableKeys.compactMap { recordsByKey[$0] },
                revealedKeys: revealedKeys
            )
        )
    }

    /// Merge a host record without allowing a late response to erase a durable title.
    /// Dormant runtimes are never stored: this single choke point covers live
    /// lists, search hits, single patches, and watched events. Any pre-existing
    /// record under the key is purged so legacy snapshots cannot linger in memory;
    /// the next persist rewrites the snapshot without them (host files untouched).
    private func merge(_ incoming: SessionSummary, revision: UInt64? = nil) {
        let key = resolvedKey(incoming.key)
        guard !deletedKeys.contains(incoming.key), !deletedKeys.contains(key) else { return }
        guard ActiveRuntimeVisibility.isListVisible(incoming) else {
            recordsByKey[key] = nil
            revisionByKey[key] = nil
            return
        }
        if let revision, let previous = revisionByKey[key], revision < previous { return }
        var merged = incoming
        if merged.key != key {
            merged = incoming.replacingKey(key)
        }
        if let current = recordsByKey[key], merged.title.isEmpty, !current.title.isEmpty {
            merged.title = current.title
        }
        if let readAt = locallyReadMtime[key] {
            if merged.isUnread, merged.mtime <= readAt {
                merged = merged.clearingUnread()
            } else {
                locallyReadMtime[key] = nil
            }
        }
        recordsByKey[key] = merged
        if let revision { revisionByKey[key] = revision }
        metadataEpoch &+= 1
    }

    /// Keep provisional detail routes alive when the host promotes them to a canonical key.
    func migrateSession(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        if deletedKeys.contains(oldKey) || deletedKeys.contains(resolvedKey(oldKey))
            || deletedKeys.contains(newKey) || deletedKeys.contains(resolvedKey(newKey)) {
            aliasByKey[oldKey] = newKey
            removeSession(key: oldKey)
            return
        }
        aliasByKey[oldKey] = newKey
        for (alias, target) in aliasByKey where target == oldKey {
            aliasByKey[alias] = newKey
        }
        if recordsByKey[newKey] == nil, let old = recordsByKey[oldKey] {
            // The host's canonical payload will replace this identity on the next event.
            recordsByKey[newKey] = old.replacingKey(newKey)
        }
        if let target = recordsByKey[newKey],
           !ActiveRuntimeVisibility.isListVisible(target) {
            // Canonical identity is dormant: keep the alias so the old key still
            // resolves, but hold no record, list, or search membership and persist
            // without it. Lookups stay unroutable (see `session(for:)`).
            recordsByKey[newKey] = nil
            revisionByKey[newKey] = nil
            listKeys.removeAll { $0 == oldKey || $0 == newKey }
            revealedKeys.removeAll { $0 == oldKey || $0 == newKey }
            searchKeys?.removeAll { $0 == oldKey || $0 == newKey }
            metadataEpoch &+= 1
            persistIfNeeded()
            rebuildSections()
            return
        }
        recordsByKey[oldKey] = nil
        revisionByKey[newKey] = max(revisionByKey[newKey] ?? 0, revisionByKey[oldKey] ?? 0)
        revisionByKey[oldKey] = nil
        listKeys = Self.uniqueKeys(listKeys.map { $0 == oldKey ? newKey : $0 })
        revealedKeys = Self.uniqueKeys(revealedKeys.map { $0 == oldKey ? newKey : $0 })
        searchKeys = searchKeys.map { Self.uniqueKeys($0.map { $0 == oldKey ? newKey : $0 }) }
        if openedKeys.remove(oldKey) != nil { openedKeys.insert(newKey) }
        metadataEpoch &+= 1
        persistIfNeeded()
        rebuildSections()
    }

    /// A key may appear once: duplicate identities make native lists draw
    /// rows on top of one another.
    private static func uniqueKeys(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    private func rebuildSections() {
        updateCalendarContext()
        let source = filteredSessions
        // Waiting membership follows the activity dot only; an independent red
        // unread overlay never moves a session in or out of this section.
        let waiting = source
            .filter { SessionPresentation.activityMarker(for: $0) == .waiting }
            .sorted(by: Self.byRecency)

        let pinned = source
            .filter { SessionPresentation.activityMarker(for: $0) != .waiting && ($0.pinned == true || $0.group?.pinned == true) }
            .sorted(by: Self.byRecency)

        let remaining = source.filter { session in
            SessionPresentation.activityMarker(for: session) != .waiting
                && session.pinned != true
                && session.group?.pinned != true
        }

        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var earlier: [SessionSummary] = []

        for session in remaining.sorted(by: Self.byRecency) {
            switch timeBucket(for: session.mtime) {
            case .today: today.append(session)
            case .yesterday: yesterday.append(session)
            case .earlier: earlier.append(session)
            }
        }

        var built: [Section] = []
        if !waiting.isEmpty { built.append(.waiting(waiting)) }
        if !pinned.isEmpty { built.append(.pinned(pinned)) }
        if !today.isEmpty { built.append(.today(today)) }
        if !yesterday.isEmpty { built.append(.yesterday(yesterday)) }
        if !earlier.isEmpty { built.append(.earlier(earlier)) }
        sections = built
    }

    private enum TimeBucket {
        case today, yesterday, earlier
    }

    private func timeBucket(for mtime: Double) -> TimeBucket {
        guard mtime > 0 else { return .earlier }
        let date = Date(timeIntervalSince1970: mtime)
        let calendar = presentationCalendar
        let today = calendar.startOfDay(for: presentationDate)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        return .earlier
    }

    private static func byRecency(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
        return lhs.key > rhs.key
    }
}

private extension SessionSummary {
    var isUnread: Bool {
        SessionPresentation.hasUnread(for: self)
    }

    /// The same row with only the red unread state removed. A waiting/working
    /// activity behind the red overlay is preserved untouched.
    func clearingUnread() -> SessionSummary {
        let isUnreadMarker = marker?.lowercased() == "unread"
        return SessionSummary(
            key: key, runtime: runtime, sessionID: sessionID, shortID: shortID,
            title: title, cwd: cwd, cwdDisplay: cwdDisplay, mtime: mtime, time: time,
            sizeKB: sizeKB, status: status, live: live, hosted: hosted,
            attention: attention == .unread ? .none : attention,
            lastUser: lastUser, lastAgent: lastAgent, rich: rich, group: group,
            pinned: pinned, marker: isUnreadMarker ? "" : marker, completionID: completionID
        )
    }
}
