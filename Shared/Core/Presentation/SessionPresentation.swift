import Foundation

/// 会话列表展示用的派生字段（项目位置、相对时间等）。
///
/// 工作目录就是展示用位置：`cwdDisplay` 优先（开发机已把 `~` 展开成可读
/// 前缀），否则用 `cwd`。不做「项目根猜测」——子目录会话仍按真实目录展示。
enum SessionPresentation {
    /// 缩写目录里需要补父级才能认出的末级名（如 ios / cli / app-macos）。
    /// 命中即带父级；其余只取末级。过滤器引擎复用同一集合做无副作用的
    /// 路径标注；行展示仍走下方的共享窗口消歧表。
    static let ambiguousLeafNames: Set<String> = [
        "ios", "android", "cli", "app", "app-macos", "macos", "server",
        "client", "web", "frontend", "backend", "src", "source", "demo",
    ]

    /// 按当前列表窗口做同名消歧：同名末级补最少上级路径（VS Code 标签页风格）。
    /// 只在需要区分时补，不全局加长。
    private static var disambiguationSuffixByKey: [String: String] = [:]
    private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        cache.totalCostLimit = 256 * 1024
        return cache
    }()

    /// Drop derived row text under system memory pressure.
    static func purgePreviewCache() {
        previewCache.removeAllObjects()
    }
    /// 与电脑端侧栏一致：「刚刚」上界（秒）。
    static let justNowSeconds: TimeInterval = 180
    /// 超过一天退回绝对日期时间。
    static let todaySeconds: TimeInterval = 86_400

    /// 列表第二行：可读位置。规则：
    /// - 空目录 → ""（由调用方按本地化显示「工作区未知」，不伪造项目名）；
    /// - `~` 本体 → 原样返回，由行视图本地化为「主目录 / Home」；
    /// - 歧义末级（ios/cli/…）→ `父级 / 末级`；
    /// - 同名末级（按当前窗口消歧）→ 补最少上级；
    /// - 其余 → 末级名。
    static func projectName(from session: SessionSummary) -> String {
        projectName(cwd: session.cwdDisplay.isEmpty ? session.cwd : session.cwdDisplay, key: session.key)
    }

    /// 可单测的纯路径版本（不依赖 SessionSummary）。
    static func projectName(cwd raw: String, key: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 主目录本体：调用方本地化，不在这里写死中文。
        if trimmed == "~" || trimmed == "~/" { return "~" }
        let withoutTilde: String
        if trimmed == "~" {
            withoutTilde = ""
        } else if trimmed.hasPrefix("~/") {
            withoutTilde = String(trimmed.dropFirst(2))
        } else {
            withoutTilde = trimmed
        }
        let segments = withoutTilde.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let leaf = segments.last else { return trimmed }
        // 歧义末级（ios/cli/…）永远带父级，不依赖窗口消歧。
        let lowered = leaf.lowercased()
        if ambiguousLeafNames.contains(lowered), segments.count >= 2 {
            return segments[segments.count - 2] + " / " + leaf
        }
        // 同名消歧：窗口内已有结论且与末级不同（即确实需要补上级）时才用。
        if let key, let suffix = disambiguationSuffixByKey[key], !suffix.isEmpty,
           suffix != leaf {
            return suffix
        }
        return leaf
    }

    /// 进入列表/搜索前按当前窗口重算同名消歧。key 取 SessionSummary.key。
    static func updateDisambiguation(for sessions: [SessionSummary]) {
        var pathsByKey: [String: String] = [:]
        for session in sessions {
            let raw = session.cwdDisplay.isEmpty ? session.cwd : session.cwdDisplay
            pathsByKey[session.key] = raw
        }
        disambiguationSuffixByKey = disambiguationSuffixes(pathsByKey: pathsByKey)
    }

    /// 可单测的消歧核心：同名末级补最少上级路径，直到唯一。
    static func disambiguationSuffixes(pathsByKey: [String: String]) -> [String: String] {
        var segmentsByKey: [String: [String]] = [:]
        for (key, raw) in pathsByKey {
            var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("~/") { path = String(path.dropFirst(2)) }
            let segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            segmentsByKey[key] = segments
        }
        var depthByKey: [String: Int] = [:]
        for key in pathsByKey.keys { depthByKey[key] = 1 }
        while true {
            var labels: [String: String] = [:]
            for (key, segments) in segmentsByKey {
                guard !segments.isEmpty else { labels[key] = pathsByKey[key] ?? ""; continue }
                let depth = min(depthByKey[key] ?? 1, segments.count)
                labels[key] = segments.suffix(depth).joined(separator: " / ")
            }
            var groups: [String: [String]] = [:]
            for (key, label) in labels { groups[label, default: []].append(key) }
            var changed = false
            for members in groups.values where members.count > 1 {
                for key in members {
                    let count = segmentsByKey[key]?.count ?? 0
                    if (depthByKey[key] ?? 1) < count {
                        depthByKey[key] = (depthByKey[key] ?? 1) + 1
                        changed = true
                    }
                }
            }
            if !changed { return labels }
        }
    }

    /// 工作区详情：完整目录（展示用原文，不猜项目根）。
    static func fullWorkspacePath(from session: SessionSummary) -> String {
        let raw = session.cwdDisplay.isEmpty ? session.cwd : session.cwdDisplay
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum StatusMarker: String, Equatable {
        case waiting, working, unread, recent
    }

    /// Red unread state. Independent from the activity dot below: unread is
    /// only an explanation that there are unseen messages, never an activity
    /// signal. It can coexist with a waiting/working activity behind it, and
    /// clearing it must leave that activity untouched.
    static func hasUnread(for session: SessionSummary) -> Bool {
        if session.attention == .unread { return true }
        return session.marker?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unread"
    }

    /// The activity dot (yellow waiting / green working+recent). Ignores the
    /// red unread overlay: when `marker` says unread, the activity behind it
    /// comes from `attention` (working/waiting); an emptied marker (locally
    /// cleared red) falls back to `attention` the same way so clearing red
    /// never kills a green/yellow dot. Pure red yields nil (red is not active).
    /// Hosts without `marker` fall back to attention only.
    static func activityMarker(for session: SessionSummary) -> StatusMarker? {
        if let raw = session.marker?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty, raw != "unread", let marker = StatusMarker(rawValue: raw) {
            return marker
        }
        switch session.attention {
        case .waiting: return .waiting
        case .working: return .working
        case .unread, .none: return nil
        }
    }

    /// Legacy single-dot projection (marker first, then attention). Kept for
    /// compat and existing tests; UI renders `activityMarker(for:)` plus the
    /// independent `hasUnread(for:)` red dot instead of this.
    static func statusMarker(for session: SessionSummary) -> StatusMarker? {
        if let marker = session.marker {
            return StatusMarker(rawValue: marker.lowercased())
        }
        switch session.attention {
        case .waiting: return .waiting
        case .working: return .working
        case .unread: return .unread
        case .none: return nil
        }
    }

    /// 列表时间：按 `mtime` 现算相对文案（刚刚 / N分钟前 / N小时前），超过一天用 `MM-dd HH:mm`。
    /// 与电脑端 `_format_relative_time` 同档；不直接用服务端绝对 `time` 字符串。
    static func timeLabel(for session: SessionSummary, now: Date = Date()) -> String {
        guard session.mtime > 0 else { return session.time }
        return relativeTimeLabel(mtime: session.mtime, now: now)
    }

    /// 可单测的相对时间格式化。
    static func relativeTimeLabel(mtime: Double, now: Date) -> String {
        let delta = now.timeIntervalSince1970 - mtime
        if delta < justNowSeconds {
            return String(localized: "sessions.time.just_now")
        }
        if delta < 3600 {
            let minutes = max(1, Int(delta / 60))
            return String(localized: "sessions.time.minutes_ago \(minutes)")
        }
        if delta < todaySeconds {
            let hours = max(1, Int(delta / 3600))
            return String(localized: "sessions.time.hours_ago \(hours)")
        }
        return olderDateFormatter.string(from: Date(timeIntervalSince1970: mtime))
    }

    /// Creating a DateFormatter costs ~50 µs; every list row re-render used to build one.
    /// Autoupdating locale and time zone keep a shared instance correct after a settings change.
    private static let olderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// 列表预览：优先助手最近一段，否则用户最近一段。
    static func preview(for session: SessionSummary) -> String {
        let source = session.lastAgent.isEmpty ? session.lastUser : session.lastAgent
        // A list excerpt is bounded; full source remains available in the conversation.
        let excerpt = String(source.prefix(1_024))
        let key = excerpt as NSString
        if let cached = previewCache.object(forKey: key) { return cached as String }
        // CJK punctuation beside emphasis delimiters can remain literal in CommonMark.
        let normalized = excerpt.replacingOccurrences(
            of: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#,
            with: "$1", options: .regularExpression
        )
        let parsed = try? AttributedString(
            markdown: normalized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let plain = parsed.map { String($0.characters) } ?? normalized
        let result = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        previewCache.setObject(result as NSString, forKey: key, cost: max(32, result.utf8.count * 2))
        return result
    }

    static func displayTitle(for session: SessionSummary) -> String {
        session.title.isEmpty ? session.key : session.title
    }
}
