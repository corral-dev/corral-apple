import Foundation
import Observation

nonisolated struct ProjectEntry: Codable, Identifiable, Sendable {
    let path: String
    let name: String?
    var id: String { path }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return path.isEmpty ? "—" : (path as NSString).lastPathComponent
    }

    /// New Session project search: case-insensitive on the shown name or the path.
    static func matching(_ projects: [ProjectEntry], query: String) -> [ProjectEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return projects }
        return projects.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.path.localizedCaseInsensitiveContains(needle)
        }
    }
}

nonisolated struct RuntimeEntry: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    var available: Bool? = nil
    var isUsable: Bool { available != false }
    /// Corral 产品侧活跃运行时 allowlist；dormant 兼容（如 kimi）保留于服务端但不在手机 UI 中出现。
    static let activeIDs: Set<String> = ["claude", "codex", "opencode", "cursor", "pi"]
    /// Catalog membership stays a strict allowlist: unknown ids must never be
    /// listed, auto-selected, or creatable in new-session/handoff pickers.
    var isActive: Bool { Self.activeIDs.contains(id.lowercased()) }
}

/// Phone-wide session-history visibility. Known dormant identities keep stored
/// history but must not appear in any list, search hit, cache snapshot, or
/// routable detail. Either signal hides: a dormant runtime, or a dormant
/// canonical key prefix (runtime is optional in wire/history shapes, so a kimi
/// identity key with missing metadata still hides). Anything else — the five
/// active assistants, unknown future ids, or a missing/empty runtime on a
/// non-dormant key — stays visible (unknown-compatibility fallback).
nonisolated enum ActiveRuntimeVisibility {
    /// Dormant ids per the root AGENTS 运行时支持 policy (compat preserved,
    /// no maintenance, no UI entrypoint).
    static let dormantIDs: Set<String> = ["kimi"]
    static func isDormant(runtime: String?, key: String?) -> Bool {
        if let runtime, !runtime.isEmpty, dormantIDs.contains(runtime.lowercased()) {
            return true
        }
        if let key,
           let prefix = key.split(separator: ":", maxSplits: 1).first,
           dormantIDs.contains(prefix.lowercased()) {
            return true
        }
        return false
    }
    static func isListVisible(_ session: SessionSummary) -> Bool {
        !isDormant(runtime: session.runtime, key: session.key)
    }
}

/// Owns catalog readiness separately from creation and its errors.
@MainActor @Observable
final class NewSessionOptions {
    private(set) var runtimes: [RuntimeEntry] = []
    private(set) var projects: [ProjectEntry] = []
    private(set) var isLoading = false
    private(set) var isReady = false
    private(set) var errorMessage: String?
    var selectedRuntime = ""
    var selectedProject = ""

    var canCreate: Bool {
        isReady && !isLoading
            && runtimes.contains { $0.id == selectedRuntime && $0.isUsable }
            && projects.contains { $0.path == selectedProject }
    }

    func load(call: (String) async throws -> Any) async {
        guard !isLoading else { return }
        isLoading = true
        isReady = false
        errorMessage = nil
        defer { isLoading = false }
        do {
            let runtimeData = try await call(WireProtocol.mRuntimesList)
            guard let items = (runtimeData as? [String: Any])?["runtimes"] as? [[String: Any]] else {
                throw InvalidResponse()
            }
            runtimes = items.compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let entry = RuntimeEntry(id: id, name: item["name"] as? String,
                                    available: item["available"] as? Bool)
                guard entry.isActive else { return nil }
                return entry
            }
            if !runtimes.contains(where: { $0.id == selectedRuntime && $0.isUsable }) {
                selectedRuntime = runtimes.first(where: \.isUsable)?.id ?? ""
            }
            let projectData = try await call(WireProtocol.mProjectsList)
            guard let items = (projectData as? [String: Any])?["projects"] as? [[String: Any]] else {
                throw InvalidResponse()
            }
            let decoded: [ProjectEntry] = items.compactMap { item in
                // Empty is an explicit no-project choice; a missing path is malformed.
                guard let path = (item["path"] as? String) ?? (item["cwd"] as? String) else { return nil }
                return ProjectEntry(path: path, name: (item["name"] as? String) ?? (item["label"] as? String))
            }
            guard !decoded.isEmpty else { throw InvalidResponse() }
            let hadSelection = projects.contains { $0.path == selectedProject }
            projects = decoded
            if !hadSelection || !projects.contains(where: { $0.path == selectedProject }) {
                selectedProject = projects.first(where: { !$0.path.isEmpty })?.path ?? projects[0].path
            }
            isReady = true
        } catch is CancellationError {
            // Dismissing the sheet cancels loading; reopening starts a fresh attempt.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct InvalidResponse: LocalizedError {
        var errorDescription: String? { String(localized: "session.new.bad_response") }
    }
}
