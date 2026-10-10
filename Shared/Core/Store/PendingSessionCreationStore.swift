import Foundation

struct PendingSessionCreation: Codable, Equatable, Sendable {
    let commandID: String
    let hostID: String
    let runtimeID: String
    let cwd: String
    let createdAt: Date
}

/// Creation identities survive sheet dismissal, process death and lost RPC replies.
enum PendingSessionCreationStore {
    static var directoryOverride: URL?

    static func begin(hostID: String, runtimeID: String, cwd: String) throws -> PendingSessionCreation {
        var records = try load()
        if let existing = records.first(where: {
            $0.hostID == hostID && $0.runtimeID == runtimeID && $0.cwd == cwd
        }) { return existing }
        let record = PendingSessionCreation(
            commandID: UUID().uuidString, hostID: hostID, runtimeID: runtimeID, cwd: cwd, createdAt: Date()
        )
        records.append(record)
        try save(records)
        return record
    }

    static func remove(_ record: PendingSessionCreation) throws {
        try save(load().filter { $0 != record })
    }

    static func removeAll(hostID: String) throws {
        try save(load().filter { $0.hostID != hostID })
    }

    private static func fileURL() throws -> URL {
        guard let directory = directoryOverride ?? AppStorageLocation.appDirectoryIfAvailable?
            .appendingPathComponent("pending-commands", isDirectory: true)
        else { throw CocoaError(.fileNoSuchFile) }
        return directory.appendingPathComponent("creations.json")
    }

    private static func load() throws -> [PendingSessionCreation] {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PendingSessionCreation].self, from: Data(contentsOf: url))
    }

    private static func save(_ records: [PendingSessionCreation]) throws {
        let url = try fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = url.deletingLastPathComponent()
        try? folder.setResourceValues(values)
    }
}
