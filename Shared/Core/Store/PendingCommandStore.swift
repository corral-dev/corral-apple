import Foundation

/// Local unresolved outgoing command identity (separate from disposable conversation tails).
struct PendingCommandRecord: Codable, Sendable, Equatable, Identifiable {
    var commandID: String
    var hostID: String
    var sessionKey: String
    var text: String
    var localSeq: Int
    var delivery: MessageDelivery
    /// Host-provided human failure text from the latest receipt (`detail`).
    /// Shown under the failed bubble so "red !" is never the whole story.
    /// Nil for in-flight commands and legacy receipts without detail.
    var failureDetail: String?
    var createdAt: Date

    var id: String { commandID }

    enum CodingKeys: String, CodingKey {
        case commandID
        case hostID
        case sessionKey
        case text
        case localSeq
        case delivery
        case failureDetail
        case createdAt
    }

    init(
        commandID: String,
        hostID: String,
        sessionKey: String,
        text: String,
        localSeq: Int,
        delivery: MessageDelivery,
        failureDetail: String? = nil,
        createdAt: Date
    ) {
        self.commandID = commandID
        self.hostID = hostID
        self.sessionKey = sessionKey
        self.text = text
        self.localSeq = localSeq
        self.delivery = delivery
        self.failureDetail = failureDetail
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandID = try container.decode(String.self, forKey: .commandID)
        hostID = try container.decode(String.self, forKey: .hostID)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        text = try container.decode(String.self, forKey: .text)
        localSeq = try container.decode(Int.self, forKey: .localSeq)
        delivery = try container.decode(MessageDelivery.self, forKey: .delivery)
        failureDetail = try container.decodeIfPresent(String.self, forKey: .failureDetail)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// Persists unresolved `command_id` metadata until receipt reconcile resolves them.
enum PendingCommandStore {
    static var directoryOverride: URL?
    /// Serializes file access off the caller (often MainActor) thread.
    /// Writes are async; reads are sync on the same queue so a read observes
    /// all previously queued writes.
    private static let io = DispatchQueue(label: "com.x0c.corral.pending-commands", qos: .utility)

    private struct StoreFile: Codable, Equatable {
        var commands: [PendingCommandRecord]
    }

    static func load(hostID: String, sessionKey: String? = nil) -> [PendingCommandRecord] {
        let all = loadFile().commands.filter { $0.hostID == hostID }
        guard let sessionKey else { return all }
        return all.filter { $0.sessionKey == sessionKey }
    }

    static func unresolved(hostID: String, sessionKey: String) -> [PendingCommandRecord] {
        load(hostID: hostID, sessionKey: sessionKey).filter { record in
            switch record.delivery {
            case .pending, .accepted, .needsReview:
                true
            case .sent, .failed:
                false
            }
        }
    }

    static func upsert(_ record: PendingCommandRecord) {
        mutate {
            $0.commands.removeAll { $0.commandID == record.commandID && $0.hostID == record.hostID }
            $0.commands.append(record)
        }
    }

    static func updateDelivery(hostID: String, commandID: String, delivery: MessageDelivery, failureDetail: String? = nil) {
        mutate {
            guard let index = $0.commands.firstIndex(where: {
                $0.hostID == hostID && $0.commandID == commandID
            }) else { return }
            $0.commands[index].delivery = delivery
            if let failureDetail { $0.commands[index].failureDetail = failureDetail }
            if delivery == .sent || delivery == .failed {
                $0.commands.remove(at: index)
            }
        }
    }

    static func remove(hostID: String, commandID: String) {
        mutate { $0.commands.removeAll { $0.hostID == hostID && $0.commandID == commandID } }
    }

    static func removeAll(hostID: String) {
        mutate { $0.commands.removeAll { $0.hostID == hostID } }
    }

    /// Maps a host `command.status` string onto local bubble delivery.
    /// Does not auto-resend; `unknown` becomes reviewable.
    static func delivery(fromHostStatus status: String) -> MessageDelivery {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accepted", "dispatching":
            .accepted
        case "delivered":
            .sent
        case "rejected":
            .failed
        case "unknown":
            .needsReview
        case "unseen":
            .pending
        default:
            .needsReview
        }
    }

    /// Host `RemoteCallError` responses are authoritative; transport/timeouts stay queryable.
    static func isAuthoritativeHostRejection(_ error: Error) -> Bool {
        if case CommandDeliveryError.rejected = error { return true }
        return error is RemoteCallError
    }

    /// Status string for `applyCommandStatus` after a send throw.
    /// Transport ambiguity → `unknown` (needsReview, keep durable id); host reject → `rejected`.
    static func hostStatusAfterSendFailure(_ error: Error) -> String {
        isAuthoritativeHostRejection(error) ? "rejected" : "unknown"
    }

    private static func fileURL() -> URL? {
        let folder = directoryOverride ?? AppStorageLocation.appDirectoryIfAvailable?
            .appendingPathComponent("pending-commands", isDirectory: true)
        return folder?.appendingPathComponent("commands.json")
    }

    private static func loadFile() -> StoreFile {
        guard fileURL() != nil else { return StoreFile(commands: []) }
        return io.sync { readUnqueued() }
    }

    private static func saveFile(_ file: StoreFile) {
        guard let url = fileURL() else { return }
        // Queued async to keep the caller off disk; reads use io.sync so they
        // observe previously queued writes. Mutations below use mutate() for
        // atomic read-modify-write instead of this path.
        let data = try? JSONEncoder().encode(file)
        guard let data else { return }
        io.async { write(data, to: url) }
    }

    /// Atomic read-modify-write on the serial queue (no lost updates).
    private static func mutate(_ transform: (inout StoreFile) -> Void) {
        io.sync {
            var file = readUnqueued()
            transform(&file)
            if let data = try? JSONEncoder().encode(file) { writeUnqueued(data) }
        }
    }

    private static func readUnqueued() -> StoreFile {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StoreFile.self, from: data)
        else {
            return StoreFile(commands: [])
        }
        return decoded
    }

    private static func writeUnqueued(_ data: Data) {
        guard let url = fileURL() else { return }
        write(data, to: url)
    }

    private nonisolated static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var folder = url.deletingLastPathComponent()
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? folder.setResourceValues(resourceValues)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutable = url
        try? mutable.setResourceValues(resourceValues)
    }
}
