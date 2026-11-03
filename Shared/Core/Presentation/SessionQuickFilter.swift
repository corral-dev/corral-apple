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
        (self == .all ? Self.attention : self).apply(sessions: sessions).count
    }
}
