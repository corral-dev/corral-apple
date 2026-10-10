import Foundation

/// Last successful conversation window for one host + session.
///
/// Holds every official message the phone has already synchronized (including
/// pages loaded via Load earlier), not only the last network page — subject to
/// `ConversationHistoryBudget.maxOfficialMessagesPerSession`.
nonisolated struct ConversationTailSnapshot: Codable, Sendable, Equatable {
    var hostID: String
    var sessionKey: String
    var messages: [RichMessage]
    var oldestSequence: Int
    var newestSequence: Int
    var hasMoreHistory: Bool
    var generation: Int
    var savedAt: Date
    /// Presentation-only history inherited from a fork, never a destination replay cursor.
    var forkMessages: [RichMessage]? = nil
}

/// Per-session bounds for disposable conversation history on the phone.
enum ConversationHistoryBudget {
    /// ~5 remote pages of 80; enough to reopen without re-fetching earlier pages.
    static let maxOfficialMessagesPerSession = 400

    /// Build a snapshot from the in-memory conversation, trimming oldest official
    /// messages when over budget and recomputing cursors from what remains.
    static func snapshot(
        hostID: String,
        sessionKey: String,
        messages: [RichMessage],
        hasMoreHistory: Bool,
        generation: Int,
        savedAt: Date = Date()
    ) -> ConversationTailSnapshot {
        let locals = messages.filter(\.isLocal)
        var official = messages
            .filter { $0.seq > 0 }
            .sorted { $0.seq < $1.seq }
        var retainedHasMore = hasMoreHistory
        if official.count > maxOfficialMessagesPerSession {
            official = Array(official.suffix(maxOfficialMessagesPerSession))
            retainedHasMore = true
        }
        let oldest = official.first?.seq ?? 0
        let newest = official.last?.seq ?? 0
        let ordered = ConversationMessageMerge.displayOrdered(official + locals)
        return ConversationTailSnapshot(
            hostID: hostID,
            sessionKey: sessionKey,
            messages: ordered,
            oldestSequence: oldest,
            newestSequence: newest,
            hasMoreHistory: retainedHasMore,
            generation: generation,
            savedAt: savedAt
        )
    }
}

/// Bounded on-disk conversation windows keyed by host identity + canonical session key.
///
/// Budget: up to 50 recently viewed sessions, ~100 MiB total, LRU eviction.
/// Disposable history only — drafts and unresolved commands live elsewhere.
///
/// Writes are coalesced per session and encoded on a background queue (a 400-message
/// tail costs milliseconds to encode and write); `load` returns the newest pending
/// snapshot before reading disk, so callers observe save-then-load ordering.
enum ConversationTailCache {
    nonisolated static let maxSessions = 50
    nonisolated static let maxTotalBytes = 100 * 1024 * 1024

    /// Tests may redirect the on-disk root; production uses Application Support/Corral/conversation-tails.
    static var directoryOverride: URL?

    static func load(hostID: String, sessionKey: String) -> ConversationTailSnapshot? {
        guard let root = rootDirectory(),
              let url = fileURL(hostID: hostID, sessionKey: sessionKey)
        else { return nil }
        if let pending = ConversationTailWriter.shared.pendingSnapshot(at: url) {
            return pending
        }
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ConversationTailSnapshot.self, from: data)
        else { return nil }
        ConversationTailWriter.shared.touch(root: root, hostID: hostID, sessionKey: sessionKey, byteSize: data.count)
        return snapshot
    }

    static func save(_ snapshot: ConversationTailSnapshot) {
        guard !snapshot.hostID.isEmpty, !snapshot.sessionKey.isEmpty,
              let root = rootDirectory(),
              let url = fileURL(hostID: snapshot.hostID, sessionKey: snapshot.sessionKey)
        else { return }
        ConversationTailWriter.shared.schedule(snapshot, at: url, root: root)
    }

    static func remove(hostID: String, sessionKey: String) {
        guard let root = rootDirectory() else { return }
        ConversationTailWriter.shared.remove(
            root: root,
            alsoDeleting: fileURL(hostID: hostID, sessionKey: sessionKey)
        ) { $0.hostID == hostID && $0.sessionKey == sessionKey }
    }

    /// Clears every cached tail (and index rows) for a paired host.
    static func removeAll(hostID: String) {
        guard let root = rootDirectory() else { return }
        ConversationTailWriter.shared.remove(root: root) { $0.hostID == hostID }
    }

    /// Write every pending snapshot now (tests, and before reading the directory directly).
    static func flushPendingWrites() {
        ConversationTailWriter.shared.flush()
    }

    static func fileURL(hostID: String, sessionKey: String) -> URL? {
        guard let folder = rootDirectory() else { return nil }
        return ConversationTailWriter.fileURL(root: folder, hostID: hostID, sessionKey: sessionKey)
    }

    static func rootDirectory() -> URL? {
        if let directoryOverride { return directoryOverride }
        return AppStorageLocation.appDirectoryIfAvailable?
            .appendingPathComponent("conversation-tails", isDirectory: true)
    }
}

/// Serial background owner of the tail directory: snapshot files and the LRU index.
nonisolated final class ConversationTailWriter: @unchecked Sendable {
    static let shared = ConversationTailWriter()
    /// Live event batches arrive in bursts; one write per burst is enough for a disposable cache.
    static let coalesceDelay: TimeInterval = 0.25

    struct Identity: Sendable {
        let hostID: String
        let sessionKey: String
    }

    private struct Pending {
        let snapshot: ConversationTailSnapshot
        let root: URL
        /// LRU recency is the save time, not the background write time.
        let savedAt: Date
        let order: Int
    }

    private struct IndexEntry: Codable, Equatable {
        var hostID: String
        var sessionKey: String
        var byteSize: Int
        var accessedAt: Date
    }

    private struct IndexFile: Codable, Equatable {
        var entries: [IndexEntry]
    }

    private let queue = DispatchQueue(label: "com.x0c.corral.conversation-tails", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: Pending] = [:]
    private var drainScheduled = false
    private var nextOrder = 0

    func pendingSnapshot(at url: URL) -> ConversationTailSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return pending[url]?.snapshot
    }

    func schedule(_ snapshot: ConversationTailSnapshot, at url: URL, root: URL) {
        lock.lock()
        nextOrder += 1
        pending[url] = Pending(snapshot: snapshot, root: root, savedAt: Date(), order: nextOrder)
        let needsDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()
        guard needsDrain else { return }
        queue.asyncAfter(deadline: .now() + Self.coalesceDelay) { [self] in drain() }
    }

    func touch(root: URL, hostID: String, sessionKey: String, byteSize: Int) {
        queue.async { [self] in
            var index = loadIndex(root: root)
            record(&index, hostID: hostID, sessionKey: sessionKey, byteSize: byteSize, at: Date())
            saveIndex(index, root: root)
        }
    }

    /// Drops matching pending writes, then deletes files after any in-flight write.
    /// Synchronous: a following `load` must not resurrect the removed tail.
    func remove(root: URL, alsoDeleting file: URL? = nil, where matches: @escaping @Sendable (Identity) -> Bool) {
        lock.lock()
        pending = pending.filter { !matches(Identity(hostID: $0.value.snapshot.hostID, sessionKey: $0.value.snapshot.sessionKey)) }
        lock.unlock()
        queue.sync {
            if let file { try? FileManager.default.removeItem(at: file) }
            var index = loadIndex(root: root)
            for entry in index.entries where matches(Identity(hostID: entry.hostID, sessionKey: entry.sessionKey)) {
                if let url = Self.fileURL(root: root, hostID: entry.hostID, sessionKey: entry.sessionKey) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            index.entries.removeAll { matches(Identity(hostID: $0.hostID, sessionKey: $0.sessionKey)) }
            saveIndex(index, root: root)
        }
    }

    func flush() {
        queue.sync { drain() }
    }

    static func fileURL(root: URL, hostID: String, sessionKey: String) -> URL? {
        let name = "\(sanitize(hostID))__\(sanitize(sessionKey)).json"
        guard name != "__.json" else { return nil }
        return root.appendingPathComponent(name)
    }

    private static func sanitize(_ value: String) -> String {
        String(value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == ":" || character == "."
                ? character
                : "_"
        })
    }

    // MARK: - Queue-confined

    private func drain() {
        lock.lock()
        let jobs = pending
        pending.removeAll()
        drainScheduled = false
        lock.unlock()
        var indexes: [URL: IndexFile] = [:]
        for (url, job) in jobs.sorted(by: { $0.value.order < $1.value.order }) {
            guard let data = try? JSONEncoder().encode(job.snapshot) else { continue }
            ensureDirectory(job.root)
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                excludeFromBackup(url)
            } catch {
                continue
            }
            var index = indexes[job.root] ?? loadIndex(root: job.root)
            record(
                &index,
                hostID: job.snapshot.hostID,
                sessionKey: job.snapshot.sessionKey,
                byteSize: data.count,
                at: job.savedAt
            )
            indexes[job.root] = index
        }
        for (root, var index) in indexes {
            evict(&index, root: root)
            saveIndex(index, root: root)
        }
    }

    private func record(_ index: inout IndexFile, hostID: String, sessionKey: String, byteSize: Int, at time: Date) {
        index.entries.removeAll { $0.hostID == hostID && $0.sessionKey == sessionKey }
        index.entries.append(
            IndexEntry(hostID: hostID, sessionKey: sessionKey, byteSize: max(0, byteSize), accessedAt: time)
        )
    }

    private func evict(_ index: inout IndexFile, root: URL) {
        index.entries.sort { $0.accessedAt < $1.accessedAt }
        var total = index.entries.reduce(0) { $0 + $1.byteSize }
        while index.entries.count > ConversationTailCache.maxSessions
            || total > ConversationTailCache.maxTotalBytes
        {
            guard let victim = index.entries.first else { break }
            if let url = Self.fileURL(root: root, hostID: victim.hostID, sessionKey: victim.sessionKey) {
                try? FileManager.default.removeItem(at: url)
            }
            total -= victim.byteSize
            index.entries.removeFirst()
        }
    }

    private func ensureDirectory(_ root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup(root)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutable.setResourceValues(resourceValues)
    }

    private func loadIndex(root: URL) -> IndexFile {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
              let decoded = try? JSONDecoder().decode(IndexFile.self, from: data)
        else {
            return IndexFile(entries: [])
        }
        return decoded
    }

    private func saveIndex(_ index: IndexFile, root: URL) {
        ensureDirectory(root)
        let url = root.appendingPathComponent("index.json")
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        excludeFromBackup(url)
    }
}
