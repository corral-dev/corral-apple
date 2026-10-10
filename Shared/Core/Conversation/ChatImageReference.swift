import Foundation

/// An image a chat message cites: Markdown/HTML image syntax, a bare file path,
/// a `file://` link, or an `http(s)` image URL. `ref` is the exact substring of
/// the message text — the host only previews references it can find verbatim.
nonisolated struct ChatImageReference: Hashable, Sendable {
    enum Kind: Sendable {
        /// `![alt](src)` / `<img src>`: the author meant to show an image.
        case explicit
        /// A path or link mentioned in prose; hide it quietly if it does not resolve.
        case mention
    }

    let ref: String
    let kind: Kind
    let alt: String?

    /// Short label for placeholders and accessibility: alt text, else the file name.
    var displayName: String {
        if let alt, !alt.isEmpty { return alt }
        let trimmed = ref.split(separator: "?").first.map(String.init) ?? ref
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static let maxPerMessage = 6

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
    ]

    /// Parse references in reading order, de-duplicated, capped per message.
    static func references(in text: String?) -> [ChatImageReference] {
        guard let text, !text.isEmpty, mightContainImage(text) else { return [] }
        var found: [(offset: Int, reference: ChatImageReference)] = []
        var claimed: [Range<String.Index>] = []

        func add(_ ref: String, kind: Kind, alt: String?, at range: Range<String.Index>) {
            let cleaned = normalize(ref)
            guard !cleaned.isEmpty, hasImageExtension(cleaned) else { return }
            guard text.range(of: cleaned) != nil else { return }
            claimed.append(range)
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            found.append((offset, ChatImageReference(ref: cleaned, kind: kind, alt: alt)))
        }

        for match in text.matches(of: markdownImage) {
            let alt = String(match.output.1).trimmingCharacters(in: .whitespaces)
            add(String(match.output.2), kind: .explicit, alt: alt.isEmpty ? nil : alt, at: match.range)
        }
        for match in text.matches(of: htmlImage) {
            add(String(match.output.1), kind: .explicit, alt: nil, at: match.range)
        }

        let prose = maskFencedCode(text)
        for match in prose.matches(of: bareReference) {
            let range = match.range
            guard !claimed.contains(where: { $0.overlaps(range) }) else { continue }
            add(String(text[range]), kind: .mention, alt: nil, at: range)
        }

        var seen = Set<String>()
        return found
            .sorted { $0.offset < $1.offset }
            .map(\.reference)
            .filter { seen.insert($0.ref).inserted }
            .prefix(maxPerMessage)
            .map { $0 }
    }

    // MARK: - Parsing helpers

    private static func mightContainImage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return imageExtensions.contains { lower.contains(".\($0)") }
    }

    private static func hasImageExtension(_ ref: String) -> Bool {
        var path = ref
        if let url = URL(string: ref), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            path = url.path
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// Strip wrappers and trailing prose punctuation without touching the path body.
    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), text.hasSuffix(">") {
            text = String(text.dropFirst().dropLast())
        }
        while let last = text.last, ".,;:!?)]}'\"`。，；：！？）】".contains(last) {
            text.removeLast()
        }
        return text
    }

    /// Replace fenced code with spaces (same length) so bare mentions inside code
    /// are ignored while ranges still index into the original text.
    private static func maskFencedCode(_ text: String) -> String {
        guard text.contains("```") else { return text }
        var output = ""
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if isFence || inFence {
                output += String(repeating: " ", count: line.count)
            } else {
                output += line
            }
            output += "\n"
            if isFence { inFence.toggle() }
        }
        output.removeLast()
        return output
    }

    private nonisolated(unsafe) static let markdownImage =
        /!\[([^\]\n]*)\]\(\s*(<[^>\n]+>|[^)\s]+)(?:\s+"[^"\n]*")?\s*\)/

    private nonisolated(unsafe) static let htmlImage =
        /<img\b[^>]*?\bsrc\s*=\s*["']([^"'\n]+)["'][^>]*>/.ignoresCase()

    /// URLs, `file://`, absolute, home-relative, and relative paths ending in an
    /// image extension. Paths with spaces need Markdown's `<…>` form.
    private nonisolated(unsafe) static let bareReference =
        /(?:https?:\/\/|file:\/\/)[^\s<>()"'`]+|(?:~\/|\.{1,2}\/|\/)?(?:[\w@.+-]+\/)*[\w@+-][\w@.+-]*\.(?:png|jpe?g|gif|webp|heic|heif|bmp|tiff?)\b/.ignoresCase()
}

/// Preview size the phone requests, chosen from its network path.
nonisolated enum ChatImageTier: Int, Comparable, Sendable, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2
    /// User-initiated full view: always the best quality offered.
    case full = 3

    var maxPixels: Int {
        switch self {
        case .low: 640
        case .medium: 1080
        case .high: 1600
        case .full: 2560
        }
    }

    var quality: Int {
        switch self {
        case .low: 55
        case .medium: 68
        case .high: 78
        case .full: 85
        }
    }

    static func < (lhs: ChatImageTier, rhs: ChatImageTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Below this measured throughput (bytes per second) previews drop to low.
    static let slowThroughput: Double = 120_000

    /// Apple: reduce image quality on Low Data Mode; cellular and the relay are
    /// the expensive/slow paths; the LAN gets the sharpest inline preview.
    static func inline(
        isLocalRoute: Bool,
        isConstrained: Bool,
        isExpensive: Bool,
        recentThroughput: Double?
    ) -> ChatImageTier {
        if isConstrained { return .low }
        if let recentThroughput, recentThroughput < slowThroughput { return .low }
        if isLocalRoute, !isExpensive { return .high }
        return .medium
    }
}
