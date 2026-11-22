import Foundation

public nonisolated enum CLIChannel: String, Codable, Sendable, Equatable {
    case brew
    case pipx
    case pip
    case dev
}

public nonisolated struct CLIStatusSnapshot: Sendable, Equatable {
    public let version: String
    public let channel: CLIChannel?
    public let editableLike: Bool

    public init(version: String, channel: CLIChannel?, editableLike: Bool) {
        self.version = version
        self.channel = channel
        self.editableLike = editableLike
    }
}

public nonisolated enum CLIInstallMethod: Sendable, Equatable {
    case brew
    case script
    case needsHomebrew
}

public nonisolated enum CLISyncAction: Sendable, Equatable {
    case upToDate
    case ahead(cliVersion: String)
    case devCheckout(cliVersion: String)
    case install(targetVersion: String, method: CLIInstallMethod)
    case upgrade(targetVersion: String, channel: CLIChannel?, viaVersionFlag: Bool)
}

public nonisolated enum CLIVersionSyncPolicy {
    public static func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Parses a dotted numeric semantic version (ignoring pre-release/build suffixes).
    public static func parseSemanticVersion(_ raw: String) -> [Int]? {
        let stripped = normalizedVersion(raw)
        guard !stripped.isEmpty else { return nil }
        let base = stripped.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? stripped
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var nums: [Int] = []
        for part in parts {
            guard !part.isEmpty, let value = Int(part) else { return nil }
            nums.append(value)
        }
        return nums
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = parseSemanticVersion(lhs), let b = parseSemanticVersion(rhs) else {
            return nil
        }
        let count = max(a.count, b.count)
        for idx in 0..<count {
            let av = idx < a.count ? a[idx] : 0
            let bv = idx < b.count ? b[idx] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func parseCLIStatusJSON(_ data: Data) -> CLIStatusSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) != false,
              let cli = obj["cli"] as? [String: Any],
              let version = cli["version"] as? String else {
            return nil
        }
        let channelRaw = cli["channel"] as? String
        let channel = channelRaw.flatMap(CLIChannel.init(rawValue:))
        let editableLike = (cli["editable_like"] as? Bool) ?? (channel == .dev)
        return CLIStatusSnapshot(
            version: normalizedVersion(version),
            channel: channel,
            editableLike: editableLike
        )
    }

    /// Parses fallback `corral --version` plain text like `corral 1.0.0 (/path)`.
    public static func parsePlainVersionOutput(_ text: String) -> String? {
        for token in text.split(whereSeparator: \.isWhitespace) {
            let candidate = normalizedVersion(String(token))
            if parseSemanticVersion(candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    public static func decide(
        appVersion: String,
        snapshot: CLIStatusSnapshot?,
        supportsVersionUpdateFlag: Bool,
        hasHomebrew: Bool,
        hasScriptPrerequisites: Bool
    ) -> CLISyncAction {
        let target = normalizedVersion(appVersion)
        guard let snapshot else {
            if hasHomebrew {
                return .install(targetVersion: target, method: .brew)
            }
            if hasScriptPrerequisites {
                return .install(targetVersion: target, method: .script)
            }
            return .install(targetVersion: target, method: .needsHomebrew)
        }
        if snapshot.editableLike || snapshot.channel == .dev {
            return .devCheckout(cliVersion: snapshot.version)
        }
        guard let cmp = compareVersions(snapshot.version, target) else {
            return .upgrade(
                targetVersion: target,
                channel: snapshot.channel,
                viaVersionFlag: supportsVersionUpdateFlag
            )
        }
        switch cmp {
        case .orderedAscending:
            return .upgrade(
                targetVersion: target,
                channel: snapshot.channel,
                viaVersionFlag: supportsVersionUpdateFlag
            )
        case .orderedSame:
            return .upToDate
        case .orderedDescending:
            return .ahead(cliVersion: snapshot.version)
        }
    }
}
