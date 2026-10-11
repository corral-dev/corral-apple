import Foundation

/// The TUI's sidebar memory as the host shares it with desktop clients
/// (`layout.watch` and `layout` channel events). Phone clients never read it.
nonisolated struct DesktopLayout: Decodable, Sendable, Equatable {
    var revision: Int
    var groups: [DesktopGroup]
    /// Independently pinned session keys → pin time (seconds since 1970).
    var pinnedSessions: [String: Double]

    static let empty = DesktopLayout(revision: 0, groups: [], pinnedSessions: [:])

    init(revision: Int, groups: [DesktopGroup], pinnedSessions: [String: Double]) {
        self.revision = revision
        self.groups = groups
        self.pinnedSessions = pinnedSessions
    }

    enum CodingKeys: String, CodingKey {
        case revision, groups
        case pinnedSessions = "pinned_sessions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = container.decodeFlexibleInt(forKey: .revision, default: 0)
        groups = (try? container.decodeIfPresent([FailableDecodable<DesktopGroup>].self, forKey: .groups))?
            .compactMap(\.value) ?? []
        pinnedSessions = (try? container.decodeIfPresent([String: Double].self, forKey: .pinnedSessions)) ?? [:]
    }

    func group(containing key: String) -> DesktopGroup? {
        groups.first { $0.members.contains(key) }
    }
}

nonisolated struct DesktopGroup: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    /// The host's hidden internal identity; splits are never named on screen.
    var name: String
    var project: String
    var members: [String]
    var focus: String
    var collapsed: Bool
    var pinned: Bool
    var pinnedAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, project, members, focus, collapsed, pinned
        case pinnedAt = "pinned_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String, name: String, project: String = "", members: [String],
        focus: String = "", collapsed: Bool = false, pinned: Bool = false,
        pinnedAt: Double = 0, updatedAt: Double = 0
    ) {
        self.id = id
        self.name = name
        self.project = project
        self.members = members
        self.focus = focus
        self.collapsed = collapsed
        self.pinned = pinned
        self.pinnedAt = pinnedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id)
        name = container.decodeFlexibleString(forKey: .name)
        project = container.decodeFlexibleString(forKey: .project)
        members = (try? container.decodeIfPresent([String].self, forKey: .members)) ?? []
        focus = container.decodeFlexibleString(forKey: .focus)
        collapsed = container.decodeFlexibleBool(forKey: .collapsed)
        pinned = container.decodeFlexibleBool(forKey: .pinned)
        pinnedAt = (try? container.decodeIfPresent(Double.self, forKey: .pinnedAt)) ?? 0
        updatedAt = (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
    }
}

/// One full-text hit, as the TUI's Ctrl+F shows it.
nonisolated struct FulltextSearchResponse: Decodable, Sendable {
    var total: Int
    var matches: [FulltextMatch]

    enum CodingKeys: String, CodingKey { case total, matches }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.decodeFlexibleInt(forKey: .total, default: 0)
        matches = (try? container.decodeIfPresent([FailableDecodable<FulltextMatch>].self, forKey: .matches))?
            .compactMap(\.value) ?? []
    }
}

nonisolated struct FulltextMatch: Decodable, Sendable, Identifiable {
    let key: String
    let title: String
    let totalHits: Int
    let lines: [FulltextLine]

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, title, lines
        case totalHits = "total_hits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.decodeFlexibleString(forKey: .key)
        title = container.decodeFlexibleString(forKey: .title)
        totalHits = container.decodeFlexibleInt(forKey: .totalHits, default: 0)
        lines = (try? container.decodeIfPresent([FailableDecodable<FulltextLine>].self, forKey: .lines))?
            .compactMap(\.value) ?? []
    }
}

nonisolated struct FulltextLine: Decodable, Sendable, Hashable {
    let role: String
    let text: String
    /// Highlight ranges as character offsets into `text`.
    let spans: [[Int]]

    enum CodingKeys: String, CodingKey { case role, text, spans }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = container.decodeFlexibleString(forKey: .role)
        text = container.decodeFlexibleString(forKey: .text)
        spans = (try? container.decodeIfPresent([[Int]].self, forKey: .spans)) ?? []
    }
}
