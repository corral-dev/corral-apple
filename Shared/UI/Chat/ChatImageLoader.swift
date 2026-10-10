import CryptoKit
import Foundation
import ImageIO
import Network
import Observation
#if canImport(UIKit)
import UIKit
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
final class ChatImageLoader {
    enum Outcome: Sendable {
        case image(PlatformImage)
        /// The host has no such file / message: hide bare mentions silently.
        case missing
        /// Transport or encode failure: worth a retry later.
        case failed
    }

    private let hostID: String
    private let sessionKey: String
    private weak var client: RemoteClient?
    private let memory = NSCache<NSString, PlatformImage>()
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var missing: Set<String> = []

    init(client: RemoteClient?, hostID: String, sessionKey: String) {
        self.client = client
        self.hostID = hostID
        self.sessionKey = sessionKey
        memory.totalCostLimit = 48 * 1024 * 1024
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
            if let hit = memory.object(forKey: key as NSString) { return hit }
            if let data = try? Data(contentsOf: diskURL(key)), let image = Self.decode(data) {
                memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
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

    // MARK: - Private

    private func fetch(seq: Int, ref: String, tier: ChatImageTier, key: String) async -> Outcome {
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
            return .missing
        } catch {
            return .failed
        }
        guard let dict = payload as? [String: Any],
              let encoded = dict["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let image = Self.decode(data) else {
            return .failed
        }
        ChatNetworkConditions.shared.record(bytes: data.count, seconds: Date().timeIntervalSince(started))
        memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
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
