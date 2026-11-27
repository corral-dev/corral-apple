import Foundation
import SubswapQuotaCore

enum HostQuotaCache {
    /// Test-only directory override; production uses `<appDirectory>/host-quotas`.
    static var directoryOverride: URL?

    private static let io = DispatchQueue(label: "com.x0c.corral.host-quotas", qos: .utility)

    static func load(hostID: String) -> CachedHostQuotas? {
        guard let url = fileURL(hostID: hostID),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? SnapshotCodec.decode(CachedHostQuotas.self, from: data)
    }

    static func save(hostID: String, snapshot: SubswapSnapshot) {
        guard let url = fileURL(hostID: hostID) else { return }
        let record = CachedHostQuotas(hostID: hostID, snapshot: snapshot, savedAt: .now)
        guard let data = try? SnapshotCodec.encode(record) else { return }
        if directoryOverride != nil {
            writeData(data, to: url)
        } else {
            io.async {
                writeData(data, to: url)
            }
        }
    }

    static func removeAll(hostID: String) {
        guard let url = fileURL(hostID: hostID) else { return }
        if directoryOverride != nil {
            try? FileManager.default.removeItem(at: url)
        } else {
            io.async {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func flushPendingWrites() {
        io.sync {}
    }

    static func fileURL(hostID: String) -> URL? {
        let safe = String(hostID.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        })
        guard !safe.isEmpty else { return nil }
        let folder = directoryOverride ?? AppStorageLocation.appDirectoryIfAvailable?
            .appendingPathComponent("host-quotas", isDirectory: true)
        return folder?.appendingPathComponent("\(safe).json")
    }

    private nonisolated static func writeData(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
