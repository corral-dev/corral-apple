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
    let targetAnchor: String?

    init(
        id: String,
        localURL: URL,
        name: String,
        displayPath: String,
        mime: String,
        size: Int,
        sha256: String,
        targetLine: Int?,
        targetAnchor: String? = nil
    ) {
        self.id = id
        self.localURL = localURL
        self.name = name
        self.displayPath = displayPath
        self.mime = mime
        self.size = size
        self.sha256 = sha256
        self.targetLine = targetLine
        self.targetAnchor = targetAnchor
    }

    var isMarkdown: Bool {
        ChatFileLink.isMarkdown(name: name, mime: mime)
    }
}

/// Downloads message-linked and nested document-linked files via `media.file`,
/// caches them on disk by provenance chain, and drives mobile full-screen preview
/// state (multi-layer Markdown `NavigationStack` + in-viewer Quick Look).
@MainActor
@Observable
final class ChatFileLoader {
    struct MarkdownPresentation: Identifiable, Equatable {
        enum Phase: Equatable {
            case loading(progress: Double?)
            case loaded(LoadedChatFile)
            case failed(String)
        }

        let id: UUID
        let seq: Int
        let via: [String]
        let link: ChatFileLink
        var phase: Phase

        init(
            id: UUID = UUID(),
            seq: Int,
            via: [String] = [],
            link: ChatFileLink,
            phase: Phase
        ) {
            self.id = id
            self.seq = seq
            self.via = via
            self.link = link
            self.phase = phase
        }

        var childVia: [String] {
            via + [link.ref]
        }
    }

    struct NonMarkdownDownload: Identifiable, Equatable {
        let id = UUID()
        let seq: Int
        let via: [String]
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
    var pushedMarkdownLayers: [MarkdownPresentation] = []
    var nonMarkdownDownload: NonMarkdownDownload?
    var quickLookURL: URL?
    var viewerQuickLookURL: URL?

    var pushedMarkdownIDs: [UUID] {
        get { pushedMarkdownLayers.map(\.id) }
        set {
            let remaining = Set(newValue)
            let removedIDs = pushedMarkdownLayers.map(\.id).filter { !remaining.contains($0) }
            if let activeLayerID, removedIDs.contains(activeLayerID) {
                cancelActiveDownload()
            }
            pushedMarkdownLayers = newValue.compactMap { id in
                pushedMarkdownLayers.first(where: { $0.id == id })
            }
        }
    }

    var isMarkdownReaderActive: Bool {
        markdownPresentation != nil
    }

    private var activeTask: Task<Void, Never>?
    private var activeToken: UUID?
    private var activeLayerID: UUID?

    private static let sliceBytes = 1_572_864
    private static let maxNavigationDepth = 16

    init(client: RemoteClient?, hostID: String, sessionKey: String) {
        self.client = client
        self.hostID = hostID
        self.sessionKey = sessionKey
    }

    func presentation(for layerID: UUID) -> MarkdownPresentation? {
        if markdownPresentation?.id == layerID {
            return markdownPresentation
        }
        return pushedMarkdownLayers.first(where: { $0.id == layerID })
    }

    /// Opens a file link tapped directly in chat message `seq` (Layer 1).
    func open(seq: Int, link: ChatFileLink) {
        cancelActiveDownload()
        pushedMarkdownLayers = []
        viewerQuickLookURL = nil

        if let cached = cachedFile(seq: seq, via: [], link: link) {
            if cached.isMarkdown {
                markdownPresentation = MarkdownPresentation(
                    seq: seq,
                    via: [],
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
            let root = MarkdownPresentation(
                seq: seq,
                via: [],
                link: link,
                phase: .loading(progress: nil)
            )
            activeLayerID = root.id
            markdownPresentation = root
            activeTask = Task { [weak self] in
                await self?.downloadForMarkdown(
                    token: token,
                    layerID: root.id,
                    seq: seq,
                    via: [],
                    link: link,
                    inViewer: false
                )
            }
        } else {
            nonMarkdownDownload = NonMarkdownDownload(
                seq: seq,
                via: [],
                link: link,
                progress: nil,
                error: nil
            )
            activeTask = Task { [weak self] in
                await self?.downloadForQuickLook(
                    token: token,
                    seq: seq,
                    via: [],
                    link: link,
                    inViewer: false
                )
            }
        }
    }

    /// Opens a nested file link from inside an already-open Markdown reader layer.
    func openFromViewer(seq: Int, via: [String], link: ChatFileLink) {
        guard via.count < Self.maxNavigationDepth else {
            return
        }
        cancelActiveDownload()
        nonMarkdownDownload = nil

        if let cached = cachedFile(seq: seq, via: via, link: link) {
            if cached.isMarkdown {
                let layer = MarkdownPresentation(
                    seq: seq,
                    via: via,
                    link: link,
                    phase: .loaded(cached)
                )
                pushedMarkdownLayers.append(layer)
            } else {
                viewerQuickLookURL = cached.localURL
            }
            return
        }

        let token = UUID()
        activeToken = token

        if link.isMarkdown {
            let layer = MarkdownPresentation(
                seq: seq,
                via: via,
                link: link,
                phase: .loading(progress: nil)
            )
            activeLayerID = layer.id
            pushedMarkdownLayers.append(layer)
            activeTask = Task { [weak self] in
                await self?.downloadForMarkdown(
                    token: token,
                    layerID: layer.id,
                    seq: seq,
                    via: via,
                    link: link,
                    inViewer: true
                )
            }
        } else {
            nonMarkdownDownload = NonMarkdownDownload(
                seq: seq,
                via: via,
                link: link,
                progress: nil,
                error: nil
            )
            activeTask = Task { [weak self] in
                await self?.downloadForQuickLook(
                    token: token,
                    seq: seq,
                    via: via,
                    link: link,
                    inViewer: true
                )
            }
        }
    }

    func retryMarkdown(layerID: UUID? = nil) {
        if let layerID, let idx = pushedMarkdownLayers.firstIndex(where: { $0.id == layerID }) {
            let existing = pushedMarkdownLayers[idx]
            cancelActiveDownload()
            let token = UUID()
            activeToken = token
            activeLayerID = layerID
            pushedMarkdownLayers[idx].phase = .loading(progress: nil)
            activeTask = Task { [weak self] in
                await self?.downloadForMarkdown(
                    token: token,
                    layerID: layerID,
                    seq: existing.seq,
                    via: existing.via,
                    link: existing.link,
                    inViewer: true
                )
            }
            return
        }
        guard let current = markdownPresentation else { return }
        open(seq: current.seq, link: current.link)
    }

    func retryNonMarkdown() {
        guard let current = nonMarkdownDownload else { return }
        if current.via.isEmpty && !isMarkdownReaderActive {
            open(seq: current.seq, link: current.link)
        } else {
            openFromViewer(seq: current.seq, via: current.via, link: current.link)
        }
    }

    func dismissMarkdown() {
        cancelActiveDownload()
        pushedMarkdownLayers = []
        nonMarkdownDownload = nil
        viewerQuickLookURL = nil
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
        activeLayerID = nil
    }

    // MARK: - Private

    private func updateLayerPhase(_ layerID: UUID, phase: MarkdownPresentation.Phase) {
        if markdownPresentation?.id == layerID {
            markdownPresentation?.phase = phase
        } else if let idx = pushedMarkdownLayers.firstIndex(where: { $0.id == layerID }) {
            pushedMarkdownLayers[idx].phase = phase
        }
    }

    private func removePushedLayer(_ layerID: UUID) {
        pushedMarkdownLayers.removeAll { $0.id == layerID }
    }

    private func downloadForMarkdown(
        token: UUID,
        layerID: UUID,
        seq: Int,
        via: [String],
        link: ChatFileLink,
        inViewer: Bool
    ) async {
        do {
            let loaded = try await fetchAndCache(seq: seq, via: via, link: link) { [weak self] progress in
                guard let self, self.activeToken == token else { return }
                self.updateLayerPhase(layerID, phase: .loading(progress: progress))
            }
            guard !Task.isCancelled, activeToken == token else { return }
            if loaded.isMarkdown {
                updateLayerPhase(layerID, phase: .loaded(loaded))
            } else {
                // Edge case: MIME revealed a non-Markdown file.
                if inViewer {
                    removePushedLayer(layerID)
                    viewerQuickLookURL = loaded.localURL
                } else {
                    markdownPresentation = nil
                    quickLookURL = loaded.localURL
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeToken == token else { return }
            updateLayerPhase(layerID, phase: .failed(errorMessage(for: error)))
        }
    }

    private func downloadForQuickLook(
        token: UUID,
        seq: Int,
        via: [String],
        link: ChatFileLink,
        inViewer: Bool
    ) async {
        do {
            let loaded = try await fetchAndCache(seq: seq, via: via, link: link) { [weak self] progress in
                guard let self, self.activeToken == token else { return }
                if var current = self.nonMarkdownDownload {
                    current.progress = progress
                    self.nonMarkdownDownload = current
                }
            }
            guard !Task.isCancelled, activeToken == token else { return }
            nonMarkdownDownload = nil
            if loaded.isMarkdown {
                let layer = MarkdownPresentation(
                    seq: seq,
                    via: via,
                    link: link,
                    phase: .loaded(loaded)
                )
                if inViewer {
                    pushedMarkdownLayers.append(layer)
                } else {
                    markdownPresentation = layer
                }
            } else if inViewer {
                viewerQuickLookURL = loaded.localURL
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
        via: [String],
        link: ChatFileLink,
        onProgress: @MainActor (Double?) -> Void
    ) async throws -> LoadedChatFile {
        guard let client else { throw RemoteClient.ConnectionError.notConnected }
        guard client.isUsable else { throw RemoteClient.ConnectionError.notConnected }
        guard client.supportsMediaFile else { throw FileFetchError.hostUnsupported }

        var offset = 0
        var writtenBytes = 0
        var name = link.displayName
        var displayPath = link.ref
        var mime = "application/octet-stream"
        var totalSize = 0
        var sha256 = ""
        var hasher = SHA256()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-file-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        var handleClosed = false
        defer {
            if !handleClosed {
                try? handle.close()
            }
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        while true {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "key": sessionKey,
                "seq": seq,
                "ref": link.ref,
                "offset": offset,
                "max_bytes": Self.sliceBytes,
            ]
            if !via.isEmpty {
                params["via"] = via
            }
            let raw = try await client.call(WireProtocol.mMediaFile, params: params)
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
            if responseOffset != writtenBytes {
                throw RemoteClient.ConnectionError.invalidResponse
            }
            if !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                writtenBytes += chunk.count
            }
            offset = writtenBytes

            if totalSize > 0 {
                onProgress(min(1.0, Double(writtenBytes) / Double(totalSize)))
            }

            let eof = (dict["eof"] as? Bool) ?? true
            if eof || chunk.isEmpty {
                break
            }
        }

        try handle.close()
        handleClosed = true

        if !sha256.isEmpty {
            let computed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard computed == sha256 else {
                throw RemoteClient.ConnectionError.invalidResponse
            }
        }

        let directory = cacheDirectory(seq: seq, via: via, ref: link.ref)
        let fileURL = directory.appendingPathComponent(name)
        let metaURL = directory.appendingPathComponent(".meta.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        let meta = DiskMetadata(
            name: name,
            displayPath: displayPath,
            mime: mime,
            size: writtenBytes,
            sha256: sha256
        )
        if let encodedMeta = try? JSONEncoder().encode(meta) {
            try? encodedMeta.write(to: metaURL, options: .atomic)
        }

        return LoadedChatFile(
            id: "\(seq)|\(via.joined(separator: ">"))|\(link.ref)|\(sha256)",
            localURL: fileURL,
            name: name,
            displayPath: displayPath,
            mime: mime,
            size: writtenBytes,
            sha256: sha256,
            targetLine: link.targetLine,
            targetAnchor: link.targetAnchor
        )
    }

    private func cachedFile(seq: Int, via: [String], link: ChatFileLink) -> LoadedChatFile? {
        let directory = cacheDirectory(seq: seq, via: via, ref: link.ref)
        let metaURL = directory.appendingPathComponent(".meta.json")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(DiskMetadata.self, from: metaData) else {
            return nil
        }
        let safeName = ChatFileLink.sanitizedFileName(meta.name, fallback: link.displayName)
        let fileURL = directory.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return LoadedChatFile(
            id: "\(seq)|\(via.joined(separator: ">"))|\(link.ref)|\(meta.sha256)",
            localURL: fileURL,
            name: safeName,
            displayPath: meta.displayPath,
            mime: meta.mime,
            size: meta.size,
            sha256: meta.sha256,
            targetLine: link.targetLine,
            targetAnchor: link.targetAnchor
        )
    }

    private func cacheDirectory(seq: Int, via: [String], ref: String) -> URL {
        let chainKey = via.joined(separator: "\u{1e}")
        let raw = "\(hostID)\u{1f}\(sessionKey)\u{1f}\(seq)\u{1f}\(chainKey)\u{1f}\(ref)"
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
