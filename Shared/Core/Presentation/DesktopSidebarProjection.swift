import Foundation

/// The desktop sidebar as the TUI lays it out, computed from the host session
/// window plus the shared layout (groups and pins). Pure and portable so the
/// rules stay testable: authority is the TUI knowledge base, "侧边栏会话组与置顶".
///
/// - Pinned block first (groups and independent sessions by newest pin time).
/// - Unpinned items in local-calendar day buckets: today (and live), yesterday,
///   weekday names within the last seven days, then one older bucket.
/// - A group shows only when at least two of its members are visible after
///   filtering; otherwise its members appear as independent rows.
/// - Unpinned order is stable for the life of the window (`StableOrder`): rows
///   that are already shown never move because their mtime changed; sessions
///   first seen later are inserted at the top.
enum DesktopSidebarProjection {
    enum Bucket: Hashable, Sendable {
        case today
        case yesterday
        /// 1 = Sunday … 7 = Saturday (Calendar weekday).
        case weekday(Int)
        case older
    }

    enum Item: Identifiable, Equatable {
        case session(SessionSummary)
        case group(DesktopGroup, members: [SessionSummary])

        var id: String {
            switch self {
            case .session(let session): "session:\(session.key)"
            case .group(let group, _): "group:\(group.id)"
            }
        }

        var newestMtime: Double {
            switch self {
            case .session(let session): session.mtime
            case .group(_, let members): members.map(\.mtime).max() ?? 0
            }
        }

        var isLive: Bool {
            switch self {
            case .session(let session): session.live
            case .group(_, let members): members.contains(where: \.live)
            }
        }
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

        /// A group ranks at its best-placed member.
        func position(of item: Item) -> Int {
            switch item {
            case .session(let session): position(of: session.key)
            case .group(_, let members): members.map { position(of: $0.key) }.min() ?? Int.max
            }
        }
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
        let visibleByKey = Dictionary(uniqueKeysWithValues: visible.map { ($0.key, $0) })

        var items: [Item] = []
        var grouped: Set<String> = []
        for group in layout.groups {
            // The first group claiming a session keeps it; a later group left
            // with fewer than two members dissolves into standalone rows.
            var claimed: Set<String> = []
            let members = group.members.compactMap { key -> SessionSummary? in
                guard !grouped.contains(key), claimed.insert(key).inserted else { return nil }
                return visibleByKey[key]
            }
            guard members.count >= 2 else { continue }
            items.append(.group(group, members: members))
            grouped.formUnion(members.map(\.key))
        }
        for session in visible where !grouped.contains(session.key) {
            items.append(.session(session))
        }

        // First-seen order is per session (recency at that moment, newest first),
        // so a group formed later — or whose layout arrives after the first
        // render — sits where its members already were instead of jumping up.
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
            result.append(Section(kind: .pinned, items: pinned.sorted { $0.0 > $1.0 }.map(\.1)))
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
        switch item {
        case .group(let group, _):
            return group.pinned ? max(group.pinnedAt, 1) : nil
        case .session(let session):
            if let at = layout.pinnedSessions[session.key] { return max(at, 1) }
            return nil
        }
    }

    static func bucket(for item: Item, now: Date, calendar: Calendar) -> Bucket {
        let mtime = item.newestMtime
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

    /// Collapsed group summary: counts per dot in the TUI's fixed order.
    /// Red unread is independent from the activity dots: a session with both
    /// an activity and unread results counts once in each bucket, so the
    /// counts can sum past the member count. `recent` shares the working bucket.
    static func attentionSummary(_ members: [SessionSummary]) -> [(SessionPresentation.StatusMarker, Int)] {
        let activities = members.compactMap { SessionPresentation.activityMarker(for: $0) }
        let unreadCount = members.filter { SessionPresentation.hasUnread(for: $0) }.count
        let order: [SessionPresentation.StatusMarker] = [.waiting, .working, .unread]
        return order.compactMap { marker in
            let count: Int
            switch marker {
            case .waiting:
                count = activities.filter { $0 == .waiting }.count
            case .working:
                count = activities.filter { $0 == .working || $0 == .recent }.count
            case .unread:
                count = unreadCount
            case .recent:
                return nil
            }
            return count > 0 ? (marker, count) : nil
        }
    }
}
