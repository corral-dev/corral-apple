#if DEBUG
import AppKit
import Foundation

/// Host-backed presentation/drop-handler evidence without synthesizing pointer input.
/// The launch flag suppresses layout writes; the original local workspace is restored.
@MainActor
enum MacPaneReorderInspection {
    private static var claimed = false

    static func run(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard !claimed else { return }
        claimed = true
        let original = (workspace.paneKeys, workspace.focusedKey, workspace.promptsOpen)
        defer {
            workspace.inspectionRestoreWorkspace(keys: original.0, focus: original.1)
            workspace.promptsOpen = original.2
        }
        var report: [String: Any] = ["physicalDragVerified": false, "hostWrites": false]
        do {
            let grouped = Dictionary(grouping: feed.listStore.windowSessions, by: \.cwd)
            guard let candidates = grouped.values.filter({ $0.count >= 4 })
                .max(by: { $0.count < $1.count }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let keys = Array(candidates.prefix(4).map(\.key))
            workspace.inspectionRestoreWorkspace(keys: keys, focus: keys[2])
            for key in keys {
                workspace.setMode(.chat, for: key)
                workspace.promptsOpen[key] = false
            }
            for _ in 0..<100 {
                if keys.allSatisfy({ workspace.paneSurfaces.existingEntry(for: $0)?.view != nil }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .seconds(2))
            let identities = keys.compactMap { workspace.paneSurfaces.existingEntry(for: $0)?.view }
            guard identities.count == 4, let payload = workspace.paneDrag(for: keys[3]) else {
                throw CocoaError(.coderValueNotFound)
            }
            report["before"] = keys
            report["captureBefore"] = await capture("before")
            let provider = NSItemProvider()
            provider.register(payload)
            let transferred: MacPaneDrag = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: MacPaneDrag.self) { continuation.resume(with: $0) }
            }
            report["accepted"] = workspace.reorderPane(transferred, to: keys[1])
            try await Task.sleep(for: .seconds(1))
            let expected = [keys[0], keys[3], keys[1], keys[2]]
            report["after"] = workspace.paneKeys
            report["orderCorrect"] = workspace.paneKeys == expected
            report["focusPreserved"] = workspace.focusedKey == keys[2]
            report["nativeHostsPreserved"] = zip(keys, identities).allSatisfy {
                workspace.paneSurfaces.existingEntry(for: $0.0)?.view === $0.1
            }
            report["captureAfter"] = await capture("after")
            report["staleRejected"] = !workspace.reorderPane(transferred, to: keys[2])
            report["reverseAccepted"] = workspace.paneDrag(for: keys[3]).map {
                workspace.reorderPane($0, to: keys[2])
            } ?? false
            try await Task.sleep(for: .seconds(1))
            report["reverseCorrect"] = workspace.paneKeys == keys
        } catch {
            report["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-pane-reorder-inspection.json"), options: .atomic)
        }
    }

    /// Invoke the required window-capture skill, never a private view snapshot.
    private static func capture(_ stage: String) async -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let tool = env["CORRAL_INSPECTION_REORDER_CAPTURE_TOOL"],
              let python = env["CORRAL_INSPECTION_REORDER_PYTHON"],
              let window = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [tool, "capture", "--wake", "--window-id", String(window.windowNumber),
                             "--json", "-o", "/tmp/corral-pane-reorder-\(stage).png"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
#endif
