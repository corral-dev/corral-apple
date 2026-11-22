import Foundation
import Observation

/// Remembered presentation on this Mac. Neither a choice nor an automatic
/// pane presentation is part of the host's shared split layout.
@MainActor
final class MacSessionPresentationPreferences {
    enum Mode: String { case chat, terminal }

    static let newSessionModeKey = "corral.mac.newSessionMode"
    private let defaults: UserDefaults
    private let modes: Choices<Mode, String>
    private let prompts: Choices<Bool, Bool>

    init(defaults: UserDefaults = .standard, persists: Bool? = nil, limit: Int = 500) {
        self.defaults = defaults
        let writes = persists ?? Self.writesAllowed
        modes = Choices(defaults: defaults, writes: writes, key: "corral.mac.paneModes", limit: limit,
                        decode: Mode.init(rawValue:), encode: { $0.rawValue })
        prompts = Choices(defaults: defaults, writes: writes, key: "corral.mac.promptsCardOpen", limit: limit,
                          decode: { $0 }, encode: { $0 })
    }

    private static var writesAllowed: Bool {
        #if DEBUG
        // Debug and Release share a defaults domain. Inspection must not
        // overwrite choices made by the person in the installed app.
        let process = ProcessInfo.processInfo
        return !process.arguments.contains { $0.hasPrefix("-CorralInspect") }
            && !process.environment.keys.contains { $0.hasPrefix("CORRAL_INSPECTION_") }
        #else
        true
        #endif
    }

    var defaultMode: Mode {
        defaults.string(forKey: Self.newSessionModeKey).flatMap(Mode.init(rawValue:)) ?? .chat
    }

    func mode(for key: String, host: String?) -> Mode? { modes.value(for: Self.prefix(host) + key) }
    func promptsOpen(for key: String, host: String?) -> Bool? { prompts.value(for: Self.prefix(host) + key) }

    func setMode(_ mode: Mode, for key: String, host: String?) { modes.set(mode, for: key, prefix: Self.prefix(host)) }
    func setPromptsOpen(_ open: Bool, for key: String, host: String?) { prompts.set(open, for: key, prefix: Self.prefix(host)) }

    func promote(_ old: String, to canonical: String, host: String?) {
        let prefix = Self.prefix(host)
        modes.rekey(prefix: prefix, pairs: [(old, canonical)])
        prompts.rekey(prefix: prefix, pairs: [(old, canonical)])
    }

    /// A cached list can already know the alias before the first layout pass,
    /// without ever delivering the promotion event to this window.
    func reconcileAliases(host: String?, resolve: (String) -> String) {
        let prefix = Self.prefix(host)
        modes.reconcileAliases(prefix: prefix, resolve: resolve)
        prompts.reconcileAliases(prefix: prefix, resolve: resolve)
    }

    /// Readers for the old host leave with its panes. Keep saved choices, but
    /// release the observation cells browsed there that never saved a choice.
    func discardEmptyEntries() {
        modes.discardEmptyEntries()
        prompts.discardEmptyEntries()
    }

    private static func prefix(_ host: String?) -> String { "\(host ?? ""):" }

    #if DEBUG
    func promptsSnapshot() -> [String: Bool] { prompts.snapshot() }
    func restorePrompts(_ snapshot: [String: Bool]) { prompts.restore(snapshot) }
    #endif

    /// One typed value per observed session and field. Changing or evicting a
    /// value notifies its readers without a global dictionary/revision update.
    private final class Choices<Value: Equatable, Stored> {
        private typealias Entry = MacSessionChoiceValue<Value>
        private var entries: [String: Entry]
        private var order: [String]
        private let defaults: UserDefaults
        private let writes: Bool
        private let key: String
        private let limit: Int
        private let encode: (Value) -> Stored

        init(defaults: UserDefaults, writes: Bool, key: String, limit: Int,
             decode: (Stored) -> Value?, encode: @escaping (Value) -> Stored) {
            self.defaults = defaults
            self.writes = writes
            self.key = key
            self.limit = max(limit, 0)
            self.encode = encode
            let loaded: [String: Entry] = (defaults.dictionary(forKey: key) ?? [:]).compactMapValues {
                guard let value = ($0 as? Stored).flatMap(decode) else { return nil }
                return Entry(value)
            }
            entries = loaded
            let stored = defaults.stringArray(forKey: key + "Order") ?? []
            var seen: Set<String> = []
            let recorded = stored.filter { loaded[$0] != nil && seen.insert($0).inserted }
            order = loaded.keys.filter { !seen.contains($0) }.sorted() + recorded
        }

        func value(for key: String) -> Value? { entry(key).value }

        func set(_ value: Value, for session: String, prefix: String) {
            let key = prefix + session
            let current = entry(key)
            guard current.value != value else { return }
            current.value = value
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > limit {
                let oldestFirst = order.filter { !$0.hasPrefix(prefix) } + order.filter { $0.hasPrefix(prefix) }
                let victims = Set(oldestFirst.prefix(order.count - limit))
                for key in victims { entries[key]?.value = nil }
                order.removeAll { victims.contains($0) }
            }
            persist()
        }

        func reconcileAliases(prefix: String, resolve: (String) -> String) {
            // More recently chosen aliases win when no canonical choice exists.
            let pairs = order.reversed().compactMap { key -> (String, String)? in
                guard key.hasPrefix(prefix) else { return nil }
                let session = String(key.dropFirst(prefix.count))
                let canonical = resolve(session)
                return canonical == session ? nil : (session, canonical)
            }
            rekey(prefix: prefix, pairs: pairs)
        }

        func rekey(prefix: String, pairs: [(String, String)]) {
            var changed = false
            for (old, canonical) in pairs where old != canonical {
                let source = prefix + old, target = prefix + canonical
                guard let retired = entries[source], let value = retired.value else { continue }
                let current = entry(target)
                if current.value == nil {
                    current.value = value
                    if let index = order.firstIndex(of: source) { order[index] = target }
                }
                retired.value = nil
                order.removeAll { $0 == source }
                changed = true
            }
            if changed { persist() }
        }

        func discardEmptyEntries() { entries = entries.filter { $0.value.value != nil } }
        func snapshot() -> [String: Value] { entries.compactMapValues(\.value) }

        #if DEBUG
        func restore(_ snapshot: [String: Value]) {
            for key in Set(entries.keys).union(snapshot.keys) {
                let cell = entry(key)
                if cell.value != snapshot[key] { cell.value = snapshot[key] }
            }
            order.removeAll { snapshot[$0] == nil }
            let ordered = Set(order)
            order = snapshot.keys.filter { !ordered.contains($0) }.sorted() + order
        }
        #endif

        private func entry(_ key: String) -> Entry {
            if let cell = entries[key] { return cell }
            let cell = Entry(nil)
            entries[key] = cell
            return cell
        }

        private func persist() {
            guard writes else { return }
            defaults.set(snapshot().mapValues(encode), forKey: key)
            defaults.set(order, forKey: key + "Order")
        }
    }
}

@MainActor @Observable
private final class MacSessionChoiceValue<Value> {
    var value: Value?
    init(_ value: Value?) { self.value = value }
}
