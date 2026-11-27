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
        cache.countLimit = 96
        return cache
    }()
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var inFlightRaw: [String: Task<Data?, Never>] = [:]
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

    /// Pre-populate cached previews in unit/layout tests for real URL refs without host IPC.
    func seedDebugPreview(_ image: PlatformImage, seq: Int, ref: String) {
        let cost = Self.cost(of: image)
        for tier in ChatImageTier.allCases {
            Self.memory.setObject(image, forKey: cacheKey(seq: seq, ref: ref, tier: tier) as NSString, cost: cost)
        }
        revision &+= 1
    }
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

    /// Full-quality copy written to a temporary file for Quick Look without
    /// decoding a full-resolution bitmap into `Self.memory`.
    func fullImageFile(seq: Int, ref: String, name: String) async -> URL? {
        let key = cacheKey(seq: seq, ref: ref, tier: .full)
        let data: Data?
        #if DEBUG
        if ref.hasPrefix("corral-preview://") {
            guard case .image = await load(seq: seq, ref: ref, tier: .full) else { return nil }
            data = try? Data(contentsOf: diskURL(key))
        } else {
            data = await fetchRawBytes(seq: seq, ref: ref, tier: .full, key: key)
        }
        #else
        data = await fetchRawBytes(seq: seq, ref: ref, tier: .full, key: key)
        #endif
        guard let data else { return nil }
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
        return inlineImages(in: diagrams.attributed(text: text, dark: dark), source: text, seq: seq)
    }

    /// Start inline previews for every explicit Markdown image or image link in the message.
    func prepareImages(in text: String, seq: Int) async {
        var requested = Set<String>()
        for candidate in inlineCandidates(in: ChatMarkdown.attributed(text), source: text) {
            guard requested.insert(candidate.ref).inserted else { continue }
            _ = await load(seq: seq, ref: candidate.ref, tier: inlineTier())
            if requested.count >= ChatImageReference.maxPerMessage { break }
        }
    }

    private struct InlineImageCandidate {
        enum SourceKind {
            case image
            case link
        }

        let ref: String
        let alt: String
        let insertionAt: Int
        let kind: SourceKind
    }

    /// Collect inline image declarations (`![alt](url)`) and non-code Markdown image
    /// links (`[label](image-url)`), resolving link insertion points to the end of the
    /// enclosing paragraph, heading, list item, or Markdown table so mid-sentence prose
    /// never splits across an attachment.
    private func inlineCandidates(in base: AttributedString, source: String) -> [InlineImageCandidate] {
        let runs = Array(base.runs)
        let tableLayouts = MarkdownTableProjection.layouts(in: base)
        var candidates: [InlineImageCandidate] = []
        var seenAtRef = Set<String>()

        for (idx, run) in runs.enumerated() {
            if let url = run.imageURL {
                let nsRange = NSRange(run.range, in: base)
                let alt = String(base[run.range].characters)
                let ref = resolveRef(url, in: source)
                let at = NSMaxRange(nsRange)
                if seenAtRef.insert("\(at)|\(ref)").inserted {
                    candidates.append(InlineImageCandidate(ref: ref, alt: alt, insertionAt: at, kind: .image))
                }
                continue
            }
            guard let url = run.link, ChatImageReference.isImageURL(url) else { continue }
            guard !Self.isCodeRun(run) else { continue }
            let nsRange = NSRange(run.range, in: base)
            let ref = resolveRef(url, in: source)
            let at = Self.linkInsertionOffset(
                forRunAt: idx,
                nsRange: nsRange,
                in: base,
                runs: runs,
                tableLayouts: tableLayouts
            )
            guard seenAtRef.insert("\(at)|\(ref)").inserted else { continue }
            let alt = String(base[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(InlineImageCandidate(ref: ref, alt: alt, insertionAt: at, kind: .link))
        }
        return Array(candidates.prefix(ChatImageReference.maxPerMessage))
    }

    private static func isCodeRun(_ run: AttributedString.Runs.Run) -> Bool {
        if run.inlinePresentationIntent?.contains(.code) == true { return true }
        return run.presentationIntent?.components.contains {
            if case .codeBlock = $0.kind { return true }
            return false
        } ?? false
    }

    private static func linkInsertionOffset(
        forRunAt index: Int,
        nsRange: NSRange,
        in base: AttributedString,
        runs: [AttributedString.Runs.Run],
        tableLayouts: [MarkdownTableProjection.Layout]
    ) -> Int {
        if let table = tableLayouts.first(where: { NSLocationInRange(nsRange.location, $0.range) }) {
            return NSMaxRange(table.range)
        }
        if let blockID = enclosingBlockIdentity(in: runs[index].presentationIntent) {
            var endUpper = runs[index].range.upperBound
            if index + 1 < runs.count {
                for nextRun in runs[(index + 1)...] {
                    guard nextRun.presentationIntent?.components.contains(where: { $0.identity == blockID }) == true else {
                        break
                    }
                    endUpper = nextRun.range.upperBound
                }
            }
            return NSMaxRange(NSRange(runs[index].range.lowerBound..<endUpper, in: base))
        }
        return NSMaxRange(nsRange)
    }

    private static func enclosingBlockIdentity(in intent: PresentationIntent?) -> Int? {
        guard let components = intent?.components else { return nil }
        for component in components {
            switch component.kind {
            case .paragraph, .header, .listItem:
                return component.identity
            default:
                continue
            }
        }
        return nil
    }

    /// Map a Foundation Markdown URL back to the exact verbatim substring expected by the host preview RPC.
    private func resolveRef(_ url: URL, in source: String) -> String {
        let raw = url.absoluteString
        if source.contains(raw) { return raw }
        let parsed = ChatImageReferenceCache.references(in: source)
        let standardized = url.standardized
        let decodedRaw = raw.removingPercentEncoding
        if let match = parsed.first(where: { item in
            if item.ref == raw { return true }
            if let decodedRaw, item.ref.removingPercentEncoding == decodedRaw { return true }
            if let itemURL = URL(string: item.ref), itemURL.standardized == standardized { return true }
            return item.ref == url.path
        }) {
            return match.ref
        }
        return raw
    }

    /// Replace each Markdown image run or inline image link with a block attachment
    /// in reading order, keeping surrounding paragraphs and tables intact.
    private func inlineImages(in base: AttributedString, source: String, seq: Int) -> AttributedString {
        let candidates = inlineCandidates(in: base, source: source)
        guard !candidates.isEmpty else { return base }
        let tier = inlineTier()
        let available = isAvailable

        var grouped: [Int: [ChatImageAttachment]] = [:]
        var insertionOffsets: [Int] = []
        for candidate in candidates {
            guard !failedRefs.contains("\(seq)|\(candidate.ref)") else { continue }
            let hit = cachedImage(seq: seq, ref: candidate.ref, tier: tier)
            if candidate.kind == .link, hit == nil, !available {
                continue
            }
            let attachment = ChatImageAttachment(
                ref: candidate.ref,
                alt: candidate.alt,
                image: hit,
                displayScale: Self.displayScale
            ) { [weak self] in
                let fallback = (candidate.ref as NSString).lastPathComponent
                let name = candidate.alt.isEmpty ? fallback : candidate.alt
                self?.openFullImage(seq: seq, ref: candidate.ref, name: name)
            }
            if grouped[candidate.insertionAt] == nil {
                insertionOffsets.append(candidate.insertionAt)
            }
            grouped[candidate.insertionAt, default: []].append(attachment)
        }
        guard !insertionOffsets.isEmpty else { return base }

        let output = NSMutableAttributedString(attributedString: NSAttributedString(base))
        let blockStyle = NSMutableParagraphStyle()
        blockStyle.firstLineHeadIndent = 0
        blockStyle.headIndent = 0
        blockStyle.paragraphSpacingBefore = 6
        blockStyle.paragraphSpacing = 6

        for at in insertionOffsets.sorted(by: >) {
            guard let attachments = grouped[at], !attachments.isEmpty else { continue }
            let insertion = NSMutableAttributedString()
            let string = output.string as NSString
            let safeAt = min(at, string.length)
            if safeAt > 0, string.substring(with: NSRange(location: safeAt - 1, length: 1)) != "\n" {
                insertion.append(NSAttributedString(string: "\n"))
            }
            for (offset, attachment) in attachments.enumerated() {
                if offset > 0 {
                    insertion.append(NSAttributedString(string: "\n"))
                }
                let item = NSMutableAttributedString(attachment: attachment)
                item.addAttribute(.paragraphStyle, value: blockStyle, range: NSRange(location: 0, length: item.length))
                insertion.append(item)
            }
            if safeAt < string.length, string.substring(with: NSRange(location: safeAt, length: 1)) != "\n" {
                insertion.append(NSAttributedString(string: "\n"))
            }
            output.insert(insertion, at: safeAt)
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
        // The live scene's scale, not `UIScreen.main`: a folding iPhone or a
        // mirrored window may show this app on a different display.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.traitCollection.displayScale ?? 3
        #else
        NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }

    // MARK: - Private

    private enum RawOutcome {
        case data(Data)
        case missing
        case failed
    }

    private func fetch(seq: Int, ref: String, tier: ChatImageTier, key: String) async -> Outcome {
        #if DEBUG
        if ref.hasPrefix("corral-preview://"), let localPreview {
            Self.memory.setObject(localPreview, forKey: key as NSString, cost: Self.cost(of: localPreview))
            revision &+= 1
            return .image(localPreview)
        }
        #endif
        switch await requestImageData(seq: seq, ref: ref, tier: tier) {
        case .missing:
            return .missing
        case .failed:
            return .failed
        case let .data(data):
            guard let image = Self.decode(data) else {
                failedRefs.insert("\(seq)|\(ref)")
                revision &+= 1
                return .failed
            }
            Self.memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            revision &+= 1
            writeDisk(data, forKey: key)
            return .image(image)
        }
    }

    private func fetchRawBytes(seq: Int, ref: String, tier: ChatImageTier, key: String) async -> Data? {
        if let diskData = try? Data(contentsOf: diskURL(key)), Self.hasValidImageHeader(diskData) {
            return diskData
        }
        if missing.contains(key) { return nil }
        if let running = inFlightRaw[key] { return await running.value }
        let task = Task { () -> Data? in
            switch await self.requestImageData(seq: seq, ref: ref, tier: tier) {
            case .missing:
                self.missing.insert(key)
                return nil
            case .failed:
                return nil
            case let .data(data):
                guard Self.hasValidImageHeader(data) else {
                    self.failedRefs.insert("\(seq)|\(ref)")
                    self.revision &+= 1
                    return nil
                }
                self.writeDisk(data, forKey: key)
                return data
            }
        }
        inFlightRaw[key] = task
        let data = await task.value
        inFlightRaw[key] = nil
        return data
    }

    private func requestImageData(seq: Int, ref: String, tier: ChatImageTier) async -> RawOutcome {
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
              let data = Data(base64Encoded: encoded) else {
            failedRefs.insert("\(seq)|\(ref)")
            revision &+= 1
            return .failed
        }
        ChatNetworkConditions.shared.record(bytes: data.count, seconds: Date().timeIntervalSince(started))
        return .data(data)
    }

    private func writeDisk(_ data: Data, forKey key: String) {
        let url = diskURL(key)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func hasValidImageHeader(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
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
