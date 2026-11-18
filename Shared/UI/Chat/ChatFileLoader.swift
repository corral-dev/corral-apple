import CryptoKit
import Foundation
import Observation
import SwiftUI

extension EnvironmentValues {
    /// Per-conversation file loader for clickable host links; nil outside a host conversation.
    @Entry var chatFileLoader: ChatFileLoader? = nil
}

/// Downloaded host file cached on disk under `Caches/chat-files/`.
struct LoadedChatFile: Identifiable, Equatable, Sendable {
    let id: String
    let localURL: URL
    let name: String
    let displayPath: String
    let mime: String
    let size: Int
    let sha256: String
    let targetLine: Int?

    var isMarkdown: Bool {
        ChatFileLink.isMarkdown(name: name, mime: mime)
    }
}

/// Downloads message-linked files via `media.file`, caches them on disk,
/// and drives mobile full-screen preview state (Markdown viewer vs Quick Look).
@MainActor
@Observable
final class ChatFileLoader {
    struct MarkdownPresentation: Identifiable, Equatable {
        enum Phase: Equatable {
            case loading(progress: Double?)
            case loaded(LoadedChatFile)
            case failed(String)
        }

        let id = UUID()
        let seq: Int
        let link: ChatFileLink
        var phase: Phase
    }

    struct NonMarkdownDownload: Identifiable, Equatable {
        let id = UUID()
        let seq: Int
        let link: ChatFileLink
        var progress: Double?
        var error: String?
    }

    private struct DiskMetadata: Codable {
        let name: String
        let displayPath: String
        let mime: String
        let size: Int
        let sha256: String
    }

    let hostID: String
    let sessionKey: String
    private weak var client: RemoteClient?

    var markdownPresentation: MarkdownPresentation?
    var nonMarkdownDownload: NonMarkdownDownload?
    var quickLookURL: URL?

    private var activeTask: Task<Void, Never>?
    private var activeToken: UUID?

    private static let sliceBytes = 1_572_864

    init(client: RemoteClient?, hostID: String, sessionKey: String) {
        self.client = client
        self.hostID = hostID
        self.sessionKey = sessionKey
    }

    func open(seq: Int, link: ChatFileLink) {
        cancelActiveDownload()

        if let cached = cachedFile(seq: seq, link: link) {
            if cached.isMarkdown {
                markdownPresentation = MarkdownPresentation(
                    seq: seq,
                    link: link,
                    phase: .loaded(cached)
                )
            } else {
                quickLookURL = cached.localURL
            }
            return
        }

        let token = UUID()
        activeToken = token

        if link.isMarkdown {
            markdownPresentation = MarkdownPresentation(
                seq: seq,
                link: link,
                phase: .loading(progress: nil)
            )
            activeTask = Task { [weak self] in
                await self?.downloadForMarkdown(token: token, seq: seq, link: link)
            }
        } else {
            nonMarkdownDownload = NonMarkdownDownload(
                seq: seq,
                link: link,
                progress: nil,
                error: nil
            )
            activeTask = Task { [weak self] in
                await self?.downloadForQuickLook(token: token, seq: seq, link: link)
            }
        }
    }

    func retryMarkdown() {
        guard let current = markdownPresentation else { return }
        open(seq: current.seq, link: current.link)
    }

    func retryNonMarkdown() {
        guard let current = nonMarkdownDownload else { return }
        open(seq: current.seq, link: current.link)
    }

    func dismissMarkdown() {
        cancelActiveDownload()
        markdownPresentation = nil
    }

    func dismissNonMarkdown() {
        cancelActiveDownload()
        nonMarkdownDownload = nil
    }

    func cancelActiveDownload() {
        activeTask?.cancel()
        activeTask = nil
        activeToken = nil
    }

    // MARK: - Private

    private func downloadForMarkdown(token: UUID, seq: Int, link: ChatFileLink) async {
        do {
            let loaded = try await fetchAndCache(seq: seq, link: link) { [weak self] progress in
                guard let self, self.activeToken == token else { return }
                if var current = self.markdownPresentation {
                    current.phase = .loading(progress: progress)
                    self.markdownPresentation = current
                }
            }
            guard !Task.isCancelled, activeToken == token else { return }
            if loaded.isMarkdown {
                if var current = markdownPresentation {
                    current.phase = .loaded(loaded)
                    markdownPresentation = current
                }
            } else {
                // Edge case: link lacked `.md` extension or MIME revealed another type.
                markdownPresentation = nil
                quickLookURL = loaded.localURL
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeToken == token else { return }
            if var current = markdownPresentation {
                current.phase = .failed(errorMessage(for: error))
                markdownPresentation = current
            }
        }
    }

    private func downloadForQuickLook(token: UUID, seq: Int, link: ChatFileLink) async {
        do {
            let loaded = try await fetchAndCache(seq: seq, link: link) { [weak self] progress in
                guard let self, self.activeToken == token else { return }
                if var current = self.nonMarkdownDownload {
                    current.progress = progress
                    self.nonMarkdownDownload = current
                }
            }
            guard !Task.isCancelled, activeToken == token else { return }
            nonMarkdownDownload = nil
            if loaded.isMarkdown {
                markdownPresentation = MarkdownPresentation(
                    seq: seq,
                    link: link,
                    phase: .loaded(loaded)
                )
            } else {
                quickLookURL = loaded.localURL
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeToken == token else { return }
            if var current = nonMarkdownDownload {
                current.error = errorMessage(for: error)
                nonMarkdownDownload = current
            }
        }
    }

    private func fetchAndCache(
        seq: Int,
        link: ChatFileLink,
        onProgress: @MainActor (Double?) -> Void
    ) async throws -> LoadedChatFile {
        guard let client else { throw RemoteClient.ConnectionError.notConnected }
        guard client.isUsable else { throw RemoteClient.ConnectionError.notConnected }
        guard client.supportsMediaFile else { throw FileFetchError.hostUnsupported }

        var offset = 0
        var buffer = Data()
        var name = link.displayName
        var displayPath = link.ref
        var mime = "application/octet-stream"
        var totalSize = 0
        var sha256 = ""

        while true {
            try Task.checkCancellation()
            let raw = try await client.call(WireProtocol.mMediaFile, params: [
                "key": sessionKey,
                "seq": seq,
                "ref": link.ref,
                "offset": offset,
                "max_bytes": Self.sliceBytes,
            ])
            guard let dict = raw as? [String: Any],
                  let encoded = dict["data"] as? String,
                  let chunk = Data(base64Encoded: encoded) else {
                throw RemoteClient.ConnectionError.invalidResponse
            }
            if let sliceName = dict["name"] as? String, !sliceName.isEmpty {
                name = ChatFileLink.sanitizedFileName(sliceName, fallback: link.displayName)
            }
            if let path = dict["display_path"] as? String, !path.isEmpty {
                displayPath = path
            }
            if let sliceMime = dict["mime"] as? String, !sliceMime.isEmpty {
                mime = sliceMime
            }
            if let size = dict["size"] as? Int {
                totalSize = max(0, size)
            }
            if let hash = dict["sha256"] as? String, !hash.isEmpty {
                sha256 = hash
            }

            let responseOffset = (dict["offset"] as? Int) ?? offset
            if responseOffset != buffer.count {
                throw RemoteClient.ConnectionError.invalidResponse
            }
            buffer.append(chunk)
            offset = buffer.count

            if totalSize > 0 {
                onProgress(min(1.0, Double(buffer.count) / Double(totalSize)))
            }

            let eof = (dict["eof"] as? Bool) ?? true
            if eof || chunk.isEmpty {
                break
            }
        }

        if !sha256.isEmpty {
            let computed = SHA256.hash(data: buffer).map { String(format: "%02x", $0) }.joined()
            guard computed == sha256 else {
                throw RemoteClient.ConnectionError.invalidResponse
            }
        }

        let directory = cacheDirectory(seq: seq, ref: link.ref)
        let fileURL = directory.appendingPathComponent(name)
        let metaURL = directory.appendingPathComponent(".meta.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try buffer.write(to: fileURL, options: .atomic)
        let meta = DiskMetadata(
            name: name,
            displayPath: displayPath,
            mime: mime,
            size: buffer.count,
            sha256: sha256
        )
        if let encodedMeta = try? JSONEncoder().encode(meta) {
            try? encodedMeta.write(to: metaURL, options: .atomic)
        }

        return LoadedChatFile(
            id: "\(seq)|\(link.ref)|\(sha256)",
            localURL: fileURL,
            name: name,
            displayPath: displayPath,
            mime: mime,
            size: buffer.count,
            sha256: sha256,
            targetLine: link.targetLine
        )
    }

    private func cachedFile(seq: Int, link: ChatFileLink) -> LoadedChatFile? {
        let directory = cacheDirectory(seq: seq, ref: link.ref)
        let metaURL = directory.appendingPathComponent(".meta.json")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(DiskMetadata.self, from: metaData) else {
            return nil
        }
        let safeName = ChatFileLink.sanitizedFileName(meta.name, fallback: link.displayName)
        let fileURL = directory.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return LoadedChatFile(
            id: "\(seq)|\(link.ref)|\(meta.sha256)",
            localURL: fileURL,
            name: safeName,
            displayPath: meta.displayPath,
            mime: meta.mime,
            size: meta.size,
            sha256: meta.sha256,
            targetLine: link.targetLine
        )
    }

    private func cacheDirectory(seq: Int, ref: String) -> URL {
        let raw = "\(hostID)\u{1f}\(sessionKey)\u{1f}\(seq)\u{1f}\(ref)"
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return AppStorageLocation.cachesDirectory
            .appendingPathComponent("chat-files", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private func errorMessage(for error: Error) -> String {
        if let fetchError = error as? FileFetchError {
            return fetchError.localizedDescription
        }
        if let remoteError = error as? RemoteCallError {
            let trimmed = remoteError.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "error.unknown") : trimmed
        }
        if let connError = error as? RemoteClient.ConnectionError {
            return connError.localizedDescription
        }
        return error.localizedDescription
    }

    private enum FileFetchError: LocalizedError {
        case hostUnsupported

        var errorDescription: String? {
            switch self {
            case .hostUnsupported:
                String(localized: "chat.file.host_unsupported")
            }
        }
    }
}
