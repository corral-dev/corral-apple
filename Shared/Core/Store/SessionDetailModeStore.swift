import Foundation
import Observation

/// Display presentation mode for a mobile conversation surface.
nonisolated enum SessionDetailMode: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case chat
    case terminal

    var id: String { rawValue }

    var toggled: SessionDetailMode {
        self == .chat ? .terminal : .chat
    }

    var switchSymbol: String {
        self == .chat ? "terminal" : "bubble.left.and.text.bubble.right"
    }
}

/// Persists each mobile session's chosen display mode (`chat` vs `terminal`)
/// per `(hostID, canonicalSessionKey)` in `UserDefaults`, bounded by LRU eviction.
@MainActor
final class SessionDetailModeStore {
    static let shared = SessionDetailModeStore()
    static let defaultsKey = "corral.ios.sessionDetailModes"
    static let defaultModeKey = "corral.ios.defaultSessionMode"
    static let defaultLimit = 500

    private let defaults: UserDefaults
    private let writes: Bool
    private let key: String
    private let defaultKey: String
    private let limit: Int
    private var entries: [String: ModeCell]
    private var order: [String]
    private let defaultModeCell: DefaultModeCell

    init(
        defaults: UserDefaults = .standard,
        persists: Bool? = nil,
        key: String = SessionDetailModeStore.defaultsKey,
        defaultKey: String = SessionDetailModeStore.defaultModeKey,
        limit: Int = SessionDetailModeStore.defaultLimit
    ) {
        self.defaults = defaults
        writes = persists ?? Self.writesAllowed
        self.key = key
        self.defaultKey = defaultKey
        self.limit = max(limit, 0)

        let storedDefault = defaults.string(forKey: defaultKey)
            .flatMap(SessionDetailMode.init(rawValue:)) ?? .chat
        defaultModeCell = DefaultModeCell(storedDefault)

        let raw = defaults.dictionary(forKey: key) ?? [:]
        let loaded: [String: ModeCell] = raw.compactMapValues { value in
            guard let rawValue = value as? String,
                  let decoded = SessionDetailMode(rawValue: rawValue)
            else { return nil }
            return ModeCell(decoded)
        }
        entries = loaded

        let storedOrder = defaults.stringArray(forKey: key + "Order") ?? []
        var seen: Set<String> = []
        let recorded = storedOrder.filter { loaded[$0] != nil && seen.insert($0).inserted }
        order = loaded.keys.filter { !seen.contains($0) }.sorted() + recorded
    }

    private static var writesAllowed: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        return !process.arguments.contains { $0.hasPrefix("-CorralInspect") }
            && !process.environment.keys.contains { $0.hasPrefix("CORRAL_INSPECTION_") }
        #else
        true
        #endif
    }

    var defaultMode: SessionDetailMode {
        get { defaultModeCell.value }
        set {
            guard defaultModeCell.value != newValue else { return }
            defaultModeCell.value = newValue
            if writes {
                defaults.set(newValue.rawValue, forKey: defaultKey)
            }
        }
    }

    func mode(for sessionKey: String, hostID: String) -> SessionDetailMode? {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return nil }
        return entry(Self.storageKey(hostID: hostID, sessionKey: sessionKey)).value
    }

    func effectiveMode(for sessionKey: String, hostID: String) -> SessionDetailMode {
        mode(for: sessionKey, hostID: hostID) ?? .chat
    }

    /// Preview of what a deliberate open will use (explicit choice wins; unseen
    /// sessions running in an external terminal stay in Chat View).
    func effectiveOpenMode(
        for sessionKey: String,
        hostID: String,
        runsElsewhere: Bool = false
    ) -> SessionDetailMode {
        if let stored = mode(for: sessionKey, hostID: hostID) {
            return stored
        }
        return runsElsewhere ? .chat : defaultMode
    }

    /// Record the configured default mode for a session created by this client.
    /// Only non-`.chat` choices write a per-session entry, matching `MacWorkspace`.
    @discardableResult
    func applyDefaultModeForCreatedSession(sessionKey: String, hostID: String) -> SessionDetailMode {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return .chat }
        let preferred = defaultMode
        if preferred != .chat {
            setMode(preferred, for: sessionKey, hostID: hostID)
        }
        return preferred
    }

    /// Adopt `defaultMode` on a deliberate first open when no explicit choice exists
    /// and the session is not running in another terminal window.
    @discardableResult
    func adoptDefaultModeIfUnset(
        for sessionKey: String,
        hostID: String,
        runsElsewhere: Bool = false
    ) -> SessionDetailMode {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return .chat }
        if let stored = mode(for: sessionKey, hostID: hostID) {
            return stored
        }
        if runsElsewhere {
            return .chat
        }
        let preferred = defaultMode
        if preferred != .chat {
            setMode(preferred, for: sessionKey, hostID: hostID)
        }
        return preferred
    }

    func setMode(_ mode: SessionDetailMode, for sessionKey: String, hostID: String) {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return }
        let prefix = Self.prefix(hostID: hostID)
        let key = prefix + sessionKey
        let current = entry(key)
        guard current.value != mode else { return }
        current.value = mode
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > limit {
            let oldestFirst = order.filter { !$0.hasPrefix(prefix) } + order.filter { $0.hasPrefix(prefix) }
            let victims = Set(oldestFirst.prefix(order.count - limit))
            for victim in victims {
                entries[victim]?.value = nil
            }
            order.removeAll { victims.contains($0) }
        }
        persist()
    }

    func promote(oldKey: String, to canonicalKey: String, hostID: String) {
        guard !hostID.isEmpty, !oldKey.isEmpty, !canonicalKey.isEmpty, oldKey != canonicalKey else { return }
        rekey(prefix: Self.prefix(hostID: hostID), pairs: [(oldKey, canonicalKey)])
    }

    /// Reconcile any previously stored provisional aliases that are already resolved
    /// in a cached list snapshot.
    func reconcileAliases(hostID: String, resolve: (String) -> String) {
        guard !hostID.isEmpty else { return }
        let prefix = Self.prefix(hostID: hostID)
        // More recently chosen aliases win when no canonical choice exists.
        let pairs = order.reversed().compactMap { storageKey -> (String, String)? in
            guard storageKey.hasPrefix(prefix) else { return nil }
            let session = String(storageKey.dropFirst(prefix.count))
            let canonical = resolve(session)
            return canonical.isEmpty || canonical == session ? nil : (session, canonical)
        }
        rekey(prefix: prefix, pairs: pairs)
    }

    func remove(sessionKey: String, hostID: String) {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return }
        let storageKey = Self.storageKey(hostID: hostID, sessionKey: sessionKey)
        var changed = false
        if let cell = entries[storageKey], cell.value != nil {
            cell.value = nil
            changed = true
        }
        let previousCount = order.count
        order.removeAll { $0 == storageKey }
        if order.count != previousCount { changed = true }
        if changed { persist() }
    }

    func removeAll(hostID: String) {
        guard !hostID.isEmpty else { return }
        let prefix = Self.prefix(hostID: hostID)
        var changed = false
        for (storageKey, cell) in entries where storageKey.hasPrefix(prefix) {
            if cell.value != nil {
                cell.value = nil
                changed = true
            }
        }
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        let previousCount = order.count
        order.removeAll { $0.hasPrefix(prefix) }
        if order.count != previousCount { changed = true }
        if changed { persist() }
    }

    func discardEmptyEntries() {
        entries = entries.filter { $0.value.value != nil }
    }

    private func rekey(prefix: String, pairs: [(String, String)]) {
        var changed = false
        for (oldKey, canonicalKey) in pairs where oldKey != canonicalKey {
            let source = prefix + oldKey
            let target = prefix + canonicalKey
            guard let retired = entries[source], let value = retired.value else { continue }
            let current = entry(target)
            if current.value == nil {
                current.value = value
                if let index = order.firstIndex(of: source) {
                    order[index] = target
                }
            }
            retired.value = nil
            order.removeAll { $0 == source }
            changed = true
        }
        if changed { persist() }
    }

    private func entry(_ storageKey: String) -> ModeCell {
        if let cell = entries[storageKey] { return cell }
        let cell = ModeCell(nil)
        entries[storageKey] = cell
        return cell
    }

    private func persist() {
        guard writes else { return }
        let serialized = entries.compactMapValues { $0.value?.rawValue }
        defaults.set(serialized, forKey: key)
        defaults.set(order, forKey: key + "Order")
    }

    private static func prefix(hostID: String) -> String {
        "\(hostID)\u{1f}"
    }

    private static func storageKey(hostID: String, sessionKey: String) -> String {
        "\(hostID)\u{1f}\(sessionKey)"
    }
}

@MainActor
@Observable
private final class ModeCell {
    var value: SessionDetailMode?

    init(_ value: SessionDetailMode?) {
        self.value = value
    }
}

@MainActor
@Observable
private final class DefaultModeCell {
    var value: SessionDetailMode

    init(_ value: SessionDetailMode) {
        self.value = value
    }
}
