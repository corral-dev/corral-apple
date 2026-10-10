import Foundation

/// A disposable local copy of the outbound JPEG; previews never re-encode it.
enum DraftImagePreview {
    nonisolated static func prepare(base64: String) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64) else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("corral-draft-\(UUID().uuidString).jpg")
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }

    nonisolated static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
