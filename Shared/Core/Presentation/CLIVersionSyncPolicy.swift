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

public nonisolated enum HostShellPathPolicy {
    public static let sentinelBegin = "__CORRAL_PATH_BEGIN__"
    public static let sentinelEnd = "__CORRAL_PATH_END__"
    public static let minimalBasePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func probeCommand(forShell shellPath: String) -> String {
        if URL(fileURLWithPath: shellPath).lastPathComponent == "fish" {
            return "printf '\(sentinelBegin)%s\(sentinelEnd)' (string join : $PATH)"
        }
        return "printf '\(sentinelBegin)%s\(sentinelEnd)' \"$PATH\""
    }

    public static func extractSentinelPath(from data: Data) -> String? {
        let output = String(decoding: data, as: UTF8.self)
        guard let beginRange = output.range(of: sentinelBegin, options: .backwards),
              let endRange = output.range(
                  of: sentinelEnd,
                  range: beginRange.upperBound..<output.endIndex
              ) else {
            return nil
        }
        let extracted = output[beginRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? nil : extracted
    }

    public static func splitPath(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func mergePaths(_ groups: [[String]]) -> String {
        var merged: [String] = []
        var seen = Set<String>()
        for group in groups {
            for raw in group {
                let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty, seen.insert(entry).inserted else { continue }
                merged.append(entry)
            }
        }
        return merged.joined(separator: ":")
    }

    public static func commonToolBinDirectories(
        home: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        var found: [String] = []
        func isDir(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        func addIfDir(_ url: URL) {
            if isDir(url) { found.append(url.path) }
        }
        func semverKey(_ name: String) -> [Int] {
            name.split { !$0.isNumber }.compactMap { Int($0) }
        }
        func addMatchingBins(parent: URL, prefix: String) {
            guard let items = try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            let filtered = items.filter {
                prefix.isEmpty || $0.lastPathComponent.hasPrefix(prefix)
            }.sorted { lhs, rhs in
                let la = semverKey(lhs.lastPathComponent)
                let rb = semverKey(rhs.lastPathComponent)
                for idx in 0..<max(la.count, rb.count) {
                    let av = idx < la.count ? la[idx] : 0
                    let bv = idx < rb.count ? rb[idx] : 0
                    if av != bv { return av > bv }
                }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            for item in filtered {
                addIfDir(item.appending(path: "bin"))
            }
        }

        addIfDir(home.appending(path: ".local/share/nodejs/current/bin"))
        addMatchingBins(parent: home.appending(path: ".local/share/nodejs"), prefix: "current")
        addMatchingBins(parent: home.appending(path: ".nvm/versions/node"), prefix: "")

        let optionalRelativeDirs = [
            ".volta/bin",
            ".fnm/aliases/default/bin",
            "Library/Application Support/fnm/aliases/default/bin",
            ".local/share/fnm/aliases/default/bin",
            ".local/share/mise/shims",
            ".asdf/shims",
            ".nodenv/shims",
            ".npm-global/bin",
            "Library/pnpm",
            ".local/share/pnpm",
            ".bun/bin",
            ".claude/local/bin",
            ".claude/local",
            ".opencode/bin",
            ".antigravity/antigravity/bin",
            ".cargo/bin",
        ]
        for rel in optionalRelativeDirs {
            addIfDir(home.appending(path: rel))
        }

        found.append(contentsOf: [
            home.appending(path: ".local/bin").path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ])
        return found
    }
}
