import Foundation

/// Flat Mac session rows, with shared host split membership used only for
/// metadata and inherited pins. Group collapse never hides a conversation.
/// Dates and first-seen order belong to each session independently.
enum DesktopSidebarProjection {
    enum Bucket: Hashable, Sendable {
        case today
        case yesterday
        /// 1 = Sunday … 7 = Saturday (Calendar weekday).
        case weekday(Int)
        case older
    }

    struct Item: Identifiable, Equatable {
        let session: SessionSummary
        let split: DesktopGroup?
        var id: String { "session:\(session.key)" }
    }

    struct Section: Identifiable, Equatable {
        enum Kind: Hashable { case pinned, bucket(Bucket) }
        let kind: Kind
        let items: [Item]
        var id: String {
            switch kind {
            case .pinned: "pinned"
            case .bucket(.today): "today"
            case .bucket(.yesterday): "yesterday"
            case .bucket(.weekday(let day)): "weekday-\(day)"
            case .bucket(.older): "older"
            }
        }
    }

    /// Remembers first-seen positions so live updates never reshuffle rows.
    struct StableOrder: Equatable {
        private(set) var rank: [String: Int] = [:]
        private var ids: [String] = []
        private var firstSeenTime: [String: Double] = [:]

        /// Discovery can bring back an old session. Keep existing rows stable
        /// and insert each unseen identity using its original effective time.
        mutating func register(_ sessions: [SessionSummary]) {
            for session in sessions where rank[session.key] == nil {
                let index = ids.firstIndex {
                    firstSeenTime[$0, default: 0] < session.mtime
                } ?? ids.endIndex
                ids.insert(session.key, at: index)
                firstSeenTime[session.key] = session.mtime
                rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            }
        }

        func position(of id: String) -> Int { rank[id] ?? Int.max }

        func position(of item: Item) -> Int { position(of: item.session.key) }
    }

    static func sections(
        sessions: [SessionSummary],
        layout: DesktopLayout,
        filter: String,
        order: inout StableOrder,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        // Every session yields exactly one row: a native list misplaces rows
        // whose identities repeat.
        var seenKeys: Set<String> = []
        let visible = sessions.filter { matches($0, filter: filter) && seenKeys.insert($0.key).inserted }
        let items = visible.map { Item(session: $0, split: layout.group(containing: $0.key)) }

        // Layout arrival and split membership cannot reorder session rows.
        order.register(visible.sorted { $0.mtime > $1.mtime })

        var pinned: [(Double, Item)] = []
        var buckets: [Bucket: [Item]] = [:]
        for item in items {
            if let pinTime = pinTime(of: item, layout: layout) {
                pinned.append((pinTime, item))
            } else {
                buckets[bucket(for: item, now: now, calendar: calendar), default: []].append(item)
            }
        }

        var result: [Section] = []
        if !pinned.isEmpty {
            result.append(Section(kind: .pinned, items: pinned.sorted {
                $0.0 == $1.0 ? order.position(of: $0.1) < order.position(of: $1.1) : $0.0 > $1.0
            }.map(\.1)))
        }
        for bucket in orderedBuckets(now: now, calendar: calendar) {
            guard let bucketItems = buckets[bucket], !bucketItems.isEmpty else { continue }
            let ordered = bucketItems.sorted { order.position(of: $0) < order.position(of: $1) }
            result.append(Section(kind: .bucket(bucket), items: ordered))
        }
        return result
    }

    /// Local filter (the TUI's project filter box): title or project path.
    /// Splits are never named, so a split matches only through its members.
    /// Conversation bodies are searched separately (full-text search).
    static func matches(_ session: SessionSummary, filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if SessionPresentation.displayTitle(for: session).lowercased().contains(needle) { return true }
        return session.cwd.lowercased().contains(needle) || session.cwdDisplay.lowercased().contains(needle)
    }

    static func pinTime(of item: Item, layout: DesktopLayout) -> Double? {
        let ownPin = layout.pinnedSessions[item.session.key].map { max($0, 1) }
        let splitPin = item.split.flatMap { $0.pinned ? max($0.pinnedAt, 1) : nil }
        return [ownPin, splitPin].compactMap { $0 }.max()
    }

    static func bucket(for item: Item, now: Date, calendar: Calendar) -> Bucket {
        let mtime = item.session.mtime
        guard mtime > 0 else { return .older }
        let date = Date(timeIntervalSince1970: mtime)
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return .older }
        if date >= yesterday { return .yesterday }
        guard let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) else { return .older }
        if date >= weekAgo { return .weekday(calendar.component(.weekday, from: date)) }
        return .older
    }

    /// Today, yesterday, then the five preceding days newest first, then older.
    static func orderedBuckets(now: Date, calendar: Calendar) -> [Bucket] {
        var buckets: [Bucket] = [.today, .yesterday]
        let today = calendar.startOfDay(for: now)
        for offset in 2...6 {
            if let day = calendar.date(byAdding: .day, value: -offset, to: today) {
                buckets.append(.weekday(calendar.component(.weekday, from: day)))
            }
        }
        buckets.append(.older)
        return buckets
    }
}
