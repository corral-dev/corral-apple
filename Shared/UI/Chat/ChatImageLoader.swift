import CryptoKit
import Foundation
import ImageIO
import Network
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// System network path facts for choosing preview quality (Low Data Mode, cellular).
@MainActor
@Observable
final class ChatNetworkConditions {
    static let shared = ChatNetworkConditions()

    private(set) var isConstrained = false
    private(set) var isExpensive = false
    /// Exponentially weighted bytes/second of recent image transfers.
    private(set) var recentThroughput: Double?

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            Task { @MainActor in
                self?.isConstrained = constrained
                self?.isExpensive = expensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "corral.chat-images.path"))
    }

    func record(bytes: Int, seconds: TimeInterval) {
        // Tiny payloads are dominated by round-trip latency, not bandwidth.
        guard bytes >= 24_000, seconds > 0.01 else { return }
        let sample = Double(bytes) / seconds
        recentThroughput = recentThroughput.map { $0 * 0.6 + sample * 0.4 } ?? sample
    }
}

/// Loads host-made previews of message images with memory + disk caching.
/// One loader per open conversation; the host only resolves references the
/// message actually contains.
@MainActor
@Observable
final class ChatImageLoader {
    enum Outcome: Sendable {
        case image(PlatformImage)
        /// The host has no such file / message: hide bare mentions silently.
        case missing
        /// Transport or encode failure: worth a retry later.
        case failed
    }

    let diagrams: ChatDiagramStore
    private let hostID: String
    private let sessionKey: String
    private weak var client: RemoteClient?
    /// One app-wide bitmap cache. A loader per conversation used to own its own
    /// 48 MiB cost limit, so retained panes plus the open chat multiplied the
    /// real budget far past 48 MiB. Cache keys already carry host, session and
    /// tier, so sharing preserves per-conversation isolation. NSCache limits
    /// remain advisory; `purgeMemory()` releases everything under pressure.
    @MainActor private static let memory: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var missing: Set<String> = []
    /// Bumped when an inline image arrives or definitively fails, so the
    /// bubble can replace its placeholder or drop the attachment.
    private(set) var revision = 0
    /// Quick Look target opened from an inline image attachment.
    var previewURL: URL?
    private var failedRefs: Set<String> = []
    #if DEBUG
    /// Inspection-only local bitmap for the production chat path; Release and
    /// ordinary conversations never set it.
    var localPreview: PlatformImage?
    #endif

    init(client: RemoteClient?, hostID: String, sessionKey: String) {
        self.client = client
        diagrams = ChatDiagramStore(hostID: hostID)
        self.hostID = hostID
        self.sessionKey = sessionKey
    }

    /// Release decoded previews; disk copies stay for a cheap reload.
    static func purgeMemory() {
        memory.removeAllObjects()
    }

    var isAvailable: Bool { client?.supportsMediaImage == true }

    /// Inline tier from the live route and path; never upgrades a user's full view.
    func inlineTier() -> ChatImageTier {
        let conditions = ChatNetworkConditions.shared
        return ChatImageTier.inline(
            isLocalRoute: client?.activeTransport == .local,
            isConstrained: conditions.isConstrained,
            isExpensive: conditions.isExpensive,
            recentThroughput: conditions.recentThroughput
        )
    }

    /// Best cached image at or above `tier`, without touching the network.
    func cachedImage(seq: Int, ref: String, tier: ChatImageTier) -> PlatformImage? {
        for candidate in ChatImageTier.allCases.reversed() where candidate >= tier {
            let key = cacheKey(seq: seq, ref: ref, tier: candidate)
            if let hit = Self.memory.object(forKey: key as NSString) { return hit }
            if let data = try? Data(contentsOf: diskURL(key)), let image = Self.decode(data) {
                Self.memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                return image
            }
        }
        return nil
    }

    func load(seq: Int, ref: String, tier: ChatImageTier) async -> Outcome {
        if let image = cachedImage(seq: seq, ref: ref, tier: tier) { return .image(image) }
        let key = cacheKey(seq: seq, ref: ref, tier: tier)
        if missing.contains(key) { return .missing }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.fetch(seq: seq, ref: ref, tier: tier, key: key) }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        if case .missing = outcome { missing.insert(key) }
        return outcome
    }

    /// Full-quality copy written to a temporary file for Quick Look.
    func fullImageFile(seq: Int, ref: String, name: String) async -> URL? {
        guard case .image = await load(seq: seq, ref: ref, tier: .full) else { return nil }
        let key = cacheKey(seq: seq, ref: ref, tier: .full)
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-quicklook", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let safe = base.isEmpty ? "image" : base.replacingOccurrences(of: "/", with: "_")
        let file = folder.appendingPathComponent(safe).appendingPathExtension(Self.fileExtension(of: data))
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// Bubble text with diagrams and inline images at their Markdown positions.
    /// Reading `revision` here registers Observation for image completion.
    func rendered(text: String, dark: Bool, seq: Int) -> AttributedString {
        _ = revision
        return inlineImages(in: diagrams.attributed(text: text, dark: dark), seq: seq)
    }

    /// Start inline previews for every explicit Markdown image in the message.
    func prepareImages(in text: String, seq: Int) async {
        for run in ChatMarkdown.attributed(text).runs {
            guard let url = run.imageURL else { continue }
            _ = await load(seq: seq, ref: url.absoluteString, tier: inlineTier())
        }
    }

    /// Replace each Markdown image run with a block attachment after its alt
    /// text, so the image sits in the message's reading order instead of a
    /// fixed strip at the bottom.
    private func inlineImages(in base: AttributedString, seq: Int) -> AttributedString {
        let images = base.runs.compactMap { run -> (Range<AttributedString.Index>, URL, String)? in
            guard let url = run.imageURL else { return nil }
            return (run.range, url, String(base[run.range].characters))
        }
        guard !images.isEmpty else { return base }
        let output = NSMutableAttributedString(attributedString: NSAttributedString(base))
        for (range, url, alt) in images.reversed() {
            let ref = url.absoluteString
            guard !failedRefs.contains("\(seq)|\(ref)") else { continue }
            let nsRange = NSRange(range, in: base)
            let hit = cachedImage(seq: seq, ref: ref, tier: inlineTier())
            let attachment = ChatImageAttachment(
                ref: ref, alt: alt,
                image: hit,
                displayScale: Self.displayScale
            ) { [weak self] in
                self?.openFullImage(seq: seq, ref: ref, name: alt.isEmpty ? (ref as NSString).lastPathComponent : alt)
            }
            let insertion = NSMutableAttributedString()
            let string = output.string as NSString
            let at = NSMaxRange(nsRange)
            if at > 0, string.substring(with: NSRange(location: at - 1, length: 1)) != "\n" {
                insertion.append(NSAttributedString(string: "\n"))
            }
            insertion.append(NSAttributedString(attachment: attachment))
            if at < string.length, string.substring(with: NSRange(location: at, length: 1)) != "\n" {
                insertion.append(NSAttributedString(string: "\n"))
            }
            output.insert(insertion, at: at)
        }
        return AttributedString(output)
    }

    func openFullImage(seq: Int, ref: String, name: String) {
        Task { [weak self] in
            guard let self else { return }
            self.previewURL = await self.fullImageFile(seq: seq, ref: ref, name: name)
        }
    }

    private static var displayScale: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.scale
        #else
        NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }

    // MARK: - Private

    private func fetch(seq: Int, ref: String, tier: ChatImageTier, key: String) async -> Outcome {
        #if DEBUG
        if ref.hasPrefix("corral-preview://"), let localPreview {
            Self.memory.setObject(localPreview, forKey: key as NSString, cost: Self.cost(of: localPreview))
            revision &+= 1
            return .image(localPreview)
        }
        #endif
        guard let client, client.supportsMediaImage else { return .failed }
        let started = Date()
        let payload: Any
        do {
            payload = try await client.call(WireProtocol.mMediaImage, params: [
                "key": sessionKey,
                "seq": seq,
                "ref": ref,
                "max_px": tier.maxPixels,
                "quality": tier.quality,
            ])
        } catch let error as RemoteCallError where error.code == WireProtocol.eNotFound {
            failedRefs.insert("\(seq)|\(ref)")
            revision &+= 1
            return .missing
        } catch {
            failedRefs.insert("\(seq)|\(ref)")
            revision &+= 1
            return .failed
        }
        guard let dict = payload as? [String: Any],
              let encoded = dict["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let image = Self.decode(data) else {
            failedRefs.insert("\(seq)|\(ref)")
            revision &+= 1
            return .failed
        }
        ChatNetworkConditions.shared.record(bytes: data.count, seconds: Date().timeIntervalSince(started))
        Self.memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        revision &+= 1
        let url = diskURL(key)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        return .image(image)
    }

    private func cacheKey(seq: Int, ref: String, tier: ChatImageTier) -> String {
        let raw = "\(hostID)\u{1f}\(sessionKey)\u{1f}\(seq)\u{1f}\(ref)\u{1f}\(tier.rawValue)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(_ key: String) -> URL {
        let caches = AppStorageLocation.cachesDirectory
        return caches.appendingPathComponent("chat-images", isDirectory: true)
            .appendingPathComponent(key)
    }

    /// Decode through ImageIO so large previews never inflate past screen needs.
    private static func decode(_ data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ChatImageTier.full.maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return PlatformImage(corralCGImage: cgImage)
    }

    private static func cost(of image: PlatformImage) -> Int {
        guard let cgImage = image.corralCGImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private static func fileExtension(of data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "jpg"
    }
}
