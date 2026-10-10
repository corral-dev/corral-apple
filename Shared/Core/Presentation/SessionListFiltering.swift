import Foundation

/// Session-list quick-filter dimensions and the production filter path.
///
/// - Runtime and project selections are sets; empty means All. Choices within
///   a dimension form a union, and the two dimensions intersect.
///   Dormant identities never surface as options; see `ActiveRuntimeVisibility`.
/// - Project identity is the canonical working directory (`cwd` trimmed,
///   falling back to the display path only for older hosts that omit `cwd`).
///   Display paths are presentation only and never split or merge identities.
/// - Labels are derived with the pure path-keyed `labelsByPath`, never by
///   mutating the shared row-label map in `SessionPresentation`, so two host
///   catalogs cannot overwrite each other and duplicate sessions in one
///   directory never force unnecessary full paths.
/// - Filtering never mutates source sessions, caches, pins, notifications, or
///   live subscriptions: every entry point below is a pure read over the
///   window the caller passes in. Search (`SessionSummary.matches`) stays in
///   `SessionListStore`; callers intersect by applying both.
enum SessionRuntimeFilter: String, Hashable, CaseIterable, Sendable {
    case all
    case claude
    case codex
    case opencode
    case cursor
    case pi

    /// Fixed slot order: All first, then the five active runtimes.
    static let ordered: [SessionRuntimeFilter] = [
        .all, .claude, .codex, .opencode, .cursor, .pi,
    ]

    /// Case-insensitive runtime match. Unknown or missing runtimes only pass
    /// under All; each concrete option matches exactly its own id.
    func matches(_ session: SessionSummary) -> Bool {
        guard self != .all else { return true }
        return (session.runtime ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == rawValue
    }
}

/// Project quick-filter dimension. `.project` carries the canonical
/// directory identity; `.noProject` covers sessions without one.
enum SessionProjectFilter: Hashable, Sendable {
    case all
    case project(path: String)
    case noProject

    func matches(_ session: SessionSummary) -> Bool {
        switch self {
        case .all:
            return true
        case .noProject:
            return SessionListFiltering.directoryIdentity(of: session).isEmpty
        case .project(let path):
            return SessionListFiltering.directoryIdentity(of: session) == path
        }
    }
}

/// One project choice: canonical directory identity plus its short label.
struct SessionProjectOption: Hashable, Sendable {
    /// Canonical directory identity used for matching. Never a bare basename.
    let path: String
    /// Short disambiguated display name; duplicates carry parent context.
    let label: String
}

enum SessionListFiltering {
    /// Quick-row choice cap. The complete set lives behind the More sheet.
    static let recentLimit = 6

    /// All clears just this dimension; concrete choices toggle independently.
    static func toggle<Option: Hashable>(
        _ option: Option,
        all: Option,
        in selection: inout Set<Option>
    ) {
        if option == all {
            selection.removeAll()
        } else if selection.remove(option) == nil {
            selection.insert(option)
        }
    }

    /// Canonical project identity: the working directory when present, with
    /// redundant trailing slashes removed. Older hosts that omit `cwd` fall
    /// back to the display path. Empty means the session has no directory.
    /// The display path is presentation only: two summaries for the same `cwd`
    /// share one identity even when their `cwdDisplay` values differ.
    static func directoryIdentity(of session: SessionSummary) -> String {
        let cwd = session.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty { return normalizeDirectory(cwd) }
        return normalizeDirectory(session.cwdDisplay)
    }

    /// Pure short labels for canonical paths. The generic leaf rule is a
    /// minimum context (ambiguous names like ios/cli always carry at least
    /// `parent / leaf`); when that minimum still collides — e.g. two
    /// different `shared/ios` directories — the colliding identities take
    /// the longer unique suffix from the window table instead. Path-keyed,
    /// so duplicate sessions in one directory never force longer labels.
    /// Mirrors `SessionPresentation.projectName` leaf semantics without
    /// touching its shared session-keyed map.
    static func labelsByPath(_ paths: [String]) -> [String: String] {
        let unique = Array(Set(paths)).filter { !$0.isEmpty }
        let table = SessionPresentation.disambiguationSuffixes(
            pathsByKey: Dictionary(uniqueKeysWithValues: unique.map { ($0, $0) })
        )
        let minimum = Dictionary(
            uniqueKeysWithValues: unique.map { ($0, genericLabel($0)) }
        )
        var collisions = Set<String>()
        var seen = Set<String>()
        for path in unique.sorted() {
            let label = minimum[path] ?? path
            if !seen.insert(label).inserted { collisions.insert(label) }
        }
        var out: [String: String] = [:]
        for path in unique {
            if collisions.contains(minimum[path] ?? path) {
                out[path] = table[path] ?? minimum[path] ?? path
            } else {
                out[path] = minimum[path] ?? path
            }
        }
        return out
    }

    /// Complete project list for the More sheet: every identity with sessions
    /// in this window, alphabetical and stable.
    static func allOptions(sessions: [SessionSummary]) -> [SessionProjectOption] {
        let table = labelsByPath(visiblePaths(in: sessions))
        return table.keys.sorted().map {
            SessionProjectOption(path: $0, label: table[$0] ?? $0)
        }.sorted {
            let order = $0.label.localizedCaseInsensitiveCompare($1.label)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.path < $1.path
        }
    }

    /// Label for a (possibly selected, possibly out-of-window) identity,
    /// reusing the window disambiguation so duplicate leaf names stay distinct.
    static func option(
        for path: String,
        sessions: [SessionSummary]
    ) -> SessionProjectOption {
        let table = labelsByPath(visiblePaths(in: sessions))
        return SessionProjectOption(
            path: path,
            label: table[path] ?? genericLabel(path)
        )
    }

    /// Whether any visible session in this window has no directory.
    static func hasNoProject(sessions: [SessionSummary]) -> Bool {
        sessions.contains {
            ActiveRuntimeVisibility.isListVisible($0) && directoryIdentity(of: $0).isEmpty
        }
    }

    /// Stable quick-choice snapshot for one host page. Once populated,
    /// activity changes alone never evict or shift existing choices: survivors
    /// keep positions and only refresh labels. Genuinely new identities append
    /// (most-recent first, path tie-break) only while under `limit`; at full
    /// capacity newcomers stay in More. Actual removals free vacancies, which
    /// the next reconcile fills from present-but-unlisted identities in the
    /// same recency order. Never re-sorts.
    static func reconcileChoices(
        current: [SessionProjectOption],
        sessions: [SessionSummary],
        limit: Int = recentLimit
    ) -> [SessionProjectOption] {
        var latestByPath: [String: Double] = [:]
        for session in sessions {
            guard ActiveRuntimeVisibility.isListVisible(session) else { continue }
            let path = directoryIdentity(of: session)
            guard !path.isEmpty else { continue }
            latestByPath[path] = max(latestByPath[path] ?? -.infinity, session.mtime)
        }
        let table = labelsByPath(Array(latestByPath.keys))
        func make(_ path: String) -> SessionProjectOption {
            SessionProjectOption(
                path: path,
                label: table[path] ?? genericLabel(path)
            )
        }
        var next: [SessionProjectOption] = []
        var seen = Set<String>()
        for choice in current where latestByPath[choice.path] != nil {
            next.append(make(choice.path))
            seen.insert(choice.path)
        }
        let newcomers = latestByPath.keys.filter { !seen.contains($0) }.sorted {
            if latestByPath[$0, default: 0] != latestByPath[$1, default: 0] {
                return latestByPath[$0, default: 0] > latestByPath[$1, default: 0]
            }
            return $0 < $1
        }
        for path in newcomers where next.count < max(1, limit) {
            next.append(make(path))
            seen.insert(path)
        }
        return next
    }

    /// Production filter path used by the list: dormant-identity exclusion
    /// plus the runtime/project intersection. Order-preserving; empty filters
    /// pass everything through.
    static func apply(
        sessions: [SessionSummary],
        runtimes: Set<SessionRuntimeFilter>,
        projects: Set<SessionProjectFilter>
    ) -> [SessionSummary] {
        sessions.filter { session in
            ActiveRuntimeVisibility.isListVisible(session)
                && (runtimes.isEmpty || runtimes.contains { $0.matches(session) })
                && (projects.isEmpty || projects.contains { $0.matches(session) })
        }
    }

    /// Filter grouped sections for display: sessions intersected, emptied
    /// sections dropped so counts and headers always match the visible rows.
    static func apply(
        to sections: [SessionListStore.Section],
        runtimes: Set<SessionRuntimeFilter>,
        projects: Set<SessionProjectFilter>
    ) -> [SessionListStore.Section] {
        sections.compactMap { section in
            let kept = apply(sessions: section.sessions, runtimes: runtimes, projects: projects)
            guard !kept.isEmpty else { return nil }
            switch section {
            case .waiting: return .waiting(kept)
            case .pinned: return .pinned(kept)
            case .today: return .today(kept)
            case .yesterday: return .yesterday(kept)
            case .earlier: return .earlier(kept)
            }
        }
    }

    // MARK: - Private

    /// Canonical identities with visible sessions in this window.
    private static func visiblePaths(in sessions: [SessionSummary]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for session in sessions {
            guard ActiveRuntimeVisibility.isListVisible(session) else { continue }
            let path = directoryIdentity(of: session)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    /// Generic minimum-context label for one canonical path: `~` for home,
    /// always `parent / leaf` for ambiguous leaves, otherwise the bare leaf.
    /// `labelsByPath` extends this only where uniqueness requires more.
    private static func genericLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" || trimmed == "~/" { return "~" }
        let body: String
        if trimmed.hasPrefix("~/") {
            body = String(trimmed.dropFirst(2))
        } else {
            body = trimmed
        }
        let segments = body.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let leaf = segments.last else { return trimmed }
        if SessionPresentation.ambiguousLeafNames.contains(leaf.lowercased()),
           segments.count >= 2 {
            return segments[segments.count - 2] + " / " + leaf
        }
        return leaf
    }

    private static func normalizeDirectory(_ raw: String) -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "" }
        var out = path
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
