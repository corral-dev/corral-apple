import Foundation

/// Text draft for one host + session. Staged images stay in memory only.
struct ComposerDraft: Codable, Sendable, Equatable {
    var text: String
    var updatedAt: Date
}

/// Persists composer text so reopen / kill / reconnect still show the draft.
enum ComposerDraftStore {
    static var directoryOverride: URL?

    private struct StoreFile: Codable, Equatable {
        var drafts: [String: ComposerDraft]
    }

    static func load(hostID: String, sessionKey: String) -> String? {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return nil }
        let text = loadFile().drafts[key(hostID: hostID, sessionKey: sessionKey)]?.text
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    static func save(hostID: String, sessionKey: String, text: String) {
        guard !hostID.isEmpty, !sessionKey.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var file = loadFile()
        let draftKey = key(hostID: hostID, sessionKey: sessionKey)
        if trimmed.isEmpty {
            file.drafts.removeValue(forKey: draftKey)
        } else {
            file.drafts[draftKey] = ComposerDraft(text: text, updatedAt: Date())
        }
        saveFile(file)
    }

    static func remove(hostID: String, sessionKey: String) {
        var file = loadFile()
        file.drafts.removeValue(forKey: key(hostID: hostID, sessionKey: sessionKey))
        saveFile(file)
    }

    static func removeAll(hostID: String) {
        var file = loadFile()
        let prefix = "\(hostID)\u{1f}"
        file.drafts = file.drafts.filter { !$0.key.hasPrefix(prefix) }
        saveFile(file)
    }

    private static func key(hostID: String, sessionKey: String) -> String {
        "\(hostID)\u{1f}\(sessionKey)"
    }

    private static func loadFile() -> StoreFile {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(StoreFile.self, from: data)
        else { return StoreFile(drafts: [:]) }
        return file
    }

    private static func saveFile(_ file: StoreFile) {
        guard let url = fileURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func fileURL() -> URL? {
        let folder = directoryOverride ?? AppStorageLocation.appDirectoryIfAvailable
        return folder?.appendingPathComponent("composer-drafts.json")
    }
}
