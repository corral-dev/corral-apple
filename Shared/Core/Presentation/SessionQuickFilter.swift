import Foundation

/// One quick-filter cycle shared by Apple clients; evidence remains host-owned.
enum SessionQuickFilter: String, CaseIterable {
    case all
    case attention
    case active

    var titleKey: String {
        self == .active ? "sessions.filter.active" : "sessions.filter.attention"
    }

    mutating func advance() {
        switch self {
        case .all: self = .attention
        case .attention: self = .active
        case .active: self = .all
        }
    }

    func apply(
        sessions: [SessionSummary],
        runtimes: Set<SessionRuntimeFilter> = [],
        projects: Set<SessionProjectFilter> = []
    ) -> [SessionSummary] {
        SessionListFiltering.apply(
            sessions: sessions, runtimes: runtimes, projects: projects,
            attentionOnly: self == .attention, activeOnly: self == .active
        )
    }

    func apply(
        to sections: [SessionListStore.Section],
        runtimes: Set<SessionRuntimeFilter> = [],
        projects: Set<SessionProjectFilter> = []
    ) -> [SessionListStore.Section] {
        SessionListFiltering.apply(
            to: sections, runtimes: runtimes, projects: projects,
            attentionOnly: self == .attention, activeOnly: self == .active
        )
    }

    /// The unselected chip advertises Focus, the first mode entered on click.
    func count(sessions: [SessionSummary]) -> Int {
        let effective = self == .all ? Self.attention : self
        let now = Date()
        return sessions.reduce(0) { total, session in
            guard ActiveRuntimeVisibility.isListVisible(session) else { return total }
            let matched: Bool
            switch effective {
            case .all:
                matched = true
            case .attention:
                matched = SessionListFiltering.needsAttention(session, now: now)
            case .active:
                matched = SessionPresentation.activityMarker(for: session) != nil
            }
            return total + (matched ? 1 : 0)
        }
    }
}
