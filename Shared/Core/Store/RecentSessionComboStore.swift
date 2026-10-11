import Foundation

/// Recently used assistant + project pairs for one-tap new sessions.
struct RecentSessionCombo: Codable, Sendable, Equatable, Identifiable, Hashable {
    var runtimeID: String
    var runtimeName: String?
    var projectPath: String
    var projectName: String?
    var usedAt: Date

    var id: String { "\(runtimeID)\u{1f}\(projectPath)" }

    var title: String {
        let runtime = (runtimeName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? runtimeID
        return "\(runtime) · \(projectLabel)"
    }

    var projectLabel: String {
        if let name = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        // Store stays nonisolated for background I/O; localize at the call site.
        return projectPath.isEmpty ? "—" : (projectPath as NSString).lastPathComponent
    }
}

enum RecentSessionComboStore {
    static let maxCombos = 5
    static var directoryOverride: URL?

    private struct StoreFile: Codable, Equatable {
        var byHost: [String: [RecentSessionCombo]]
    }

    static func load(hostID: String) -> [RecentSessionCombo] {
        guard !hostID.isEmpty else { return [] }
        let combos = loadFile().byHost[hostID] ?? []
        return Array(combos.sorted { $0.usedAt > $1.usedAt }.prefix(maxCombos))
    }

    static func record(
        hostID: String,
        runtimeID: String,
        runtimeName: String?,
        projectPath: String,
        projectName: String?
    ) {
        guard !hostID.isEmpty, !runtimeID.isEmpty else { return }
        var file = loadFile()
        var list = file.byHost[hostID] ?? []
        let combo = RecentSessionCombo(
            runtimeID: runtimeID,
            runtimeName: runtimeName,
            projectPath: projectPath,
            projectName: projectName,
            usedAt: Date()
        )
        list.removeAll { $0.id == combo.id }
        list.insert(combo, at: 0)
        if list.count > maxCombos {
            list = Array(list.prefix(maxCombos))
        }
        file.byHost[hostID] = list
        saveFile(file)
    }

    static func clearAll() {
        saveFile(StoreFile(byHost: [:]))
    }

    /// Deletes one combo (left-swipe in the sheet). No-op for unknown ids.
    static func remove(hostID: String, comboID: String) {
        guard !hostID.isEmpty, !comboID.isEmpty else { return }
        var file = loadFile()
        guard var list = file.byHost[hostID] else { return }
        let before = list.count
        list.removeAll { $0.id == comboID }
        guard list.count != before else { return }
        file.byHost[hostID] = list
        saveFile(file)
    }

    /// Clears one host's combos when it is unpaired (matches SessionListCache).
    static func removeAll(hostID: String) {
        guard !hostID.isEmpty else { return }
        var file = loadFile()
        file.byHost.removeValue(forKey: hostID)
        saveFile(file)
    }

    private static func loadFile() -> StoreFile {
        if let url = fileURL(),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(StoreFile.self, from: data) {
            return file
        }
        return StoreFile(byHost: [:])
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
        return folder?.appendingPathComponent("recent-session-combos.json")
    }
}
