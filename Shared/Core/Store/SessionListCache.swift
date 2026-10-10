import Foundation

/// 某一台开发机上次成功拉到的列表窗口，供下次进页先画出来。
nonisolated struct SessionListSnapshot: Codable, Sendable, Equatable {
    var version: String
    var sessions: [SessionSummary]
}

enum SessionListCache {
    /// 测试可改写落盘目录；生产为 Application Support/Corral/session-lists。
    static var directoryOverride: URL?

    static func load(hostID: String) -> SessionListSnapshot? {
        guard let url = fileURL(hostID: hostID) else { return nil }
        return SessionListWriter.shared.load(at: url)
    }

    static func save(hostID: String, snapshot: SessionListSnapshot) {
        guard let url = fileURL(hostID: hostID) else { return }
        SessionListWriter.shared.schedule(snapshot, at: url)
    }

    /// Clears the list window snapshot when a host is unpaired.
    static func removeAll(hostID: String) {
        guard let url = fileURL(hostID: hostID) else { return }
        SessionListWriter.shared.remove(at: url)
    }

    /// Await actual writes before inspecting files or completing test cleanup.
    static func flushPendingWrites() {
        SessionListWriter.shared.flush()
    }

    static func fileURL(hostID: String) -> URL? {
        let safe = String(hostID.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        })
        guard !safe.isEmpty else { return nil }
        let folder = directoryOverride ?? AppStorageLocation.appDirectoryIfAvailable?
            .appendingPathComponent("session-lists", isDirectory: true)
        return folder?.appendingPathComponent("\(safe).json")
    }
}

/// Serial background ownership; each host keeps only its newest queued snapshot.
nonisolated final class SessionListWriter: @unchecked Sendable {
    static let shared = SessionListWriter()
    private struct Pending {
        let snapshot: SessionListSnapshot
        let revision: UInt64
    }
    private let queue = DispatchQueue(label: "com.x0c.corral.session-lists", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: Pending] = [:]
    private var revision: UInt64 = 0
    private var drainScheduled = false

    func schedule(_ snapshot: SessionListSnapshot, at url: URL) {
        lock.lock()
        revision &+= 1
        pending[url] = Pending(snapshot: snapshot, revision: revision)
        let needsDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if needsDrain {
            queue.asyncAfter(deadline: .now() + 0.25) { [self] in drain() }
        }
    }

    func load(at url: URL) -> SessionListSnapshot? {
        lock.lock()
        let snapshot = pending[url]?.snapshot
        lock.unlock()
        if let snapshot { return snapshot }
        return queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SessionListSnapshot.self, from: data)
        }
    }

    func remove(at url: URL) {
        lock.lock()
        pending[url] = nil
        lock.unlock()
        // An older in-flight write must finish before unpairing deletes the file.
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    func flush() {
        queue.sync { drain() }
    }

    private func drain() {
        lock.lock()
        let jobs = pending
        drainScheduled = false
        lock.unlock()
        for (url, job) in jobs {
            autoreleasepool {
                if let data = try? JSONEncoder().encode(job.snapshot) {
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try? data.write(to: url, options: .atomic)
                }
            }
            lock.lock()
            // Keep the newest snapshot readable throughout encoding and writing.
            if pending[url]?.revision == job.revision { pending[url] = nil }
            lock.unlock()
        }
    }
}
