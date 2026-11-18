import Foundation

/// Classifies clickable links in chat messages so host-local paths download
/// via `media.file` while external URLs stay on the system handler.
nonisolated struct ChatFileLink: Equatable, Sendable {
    let ref: String
    let displayName: String
    let targetLine: Int?
    let isMarkdown: Bool

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]

    /// Returns a host-file link descriptor when `url` points to a file on the
    /// paired host (`file://` or a scheme-less path), or `nil` for external URLs
    /// (`http`, `https`, `mailto`, `corral`, pure `#anchor`).
    static func classify(_ url: URL) -> ChatFileLink? {
        let raw = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if url.isFileURL {
            let path = url.path
            guard !path.isEmpty else { return nil }
            let name = sanitizedFileName((path as NSString).lastPathComponent)
            return ChatFileLink(
                ref: raw,
                displayName: name,
                targetLine: parseTargetLine(from: raw),
                isMarkdown: isMarkdown(name: name)
            )
        }

        if let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines), !scheme.isEmpty {
            return nil
        }

        // Pure in-document fragment (`#heading`) has no file path.
        guard !raw.hasPrefix("#"), !url.path.isEmpty else { return nil }
        let cleanPath = stripLocationSuffix(from: url.path)
        let last = (cleanPath as NSString).lastPathComponent
        let name = sanitizedFileName(last)
        return ChatFileLink(
            ref: raw,
            displayName: name,
            targetLine: parseTargetLine(from: raw),
            isMarkdown: isMarkdown(name: name)
        )
    }

    static func isMarkdown(name: String, mime: String? = nil) -> Bool {
        if let mime = mime?.lowercased(), mime == "text/markdown" || mime == "text/x-markdown" {
            return true
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    static func sanitizedFileName(_ raw: String, fallback: String = "file") -> String {
        let base = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." {
            return fallback
        }
        return base
    }

    static func parseTargetLine(from ref: String) -> Int? {
        if let range = ref.range(of: #"#L(\d+)(?:-L?\d+)?$"#, options: .regularExpression) {
            let digits = ref[range].dropFirst(2).prefix(while: \.isNumber)
            if let line = Int(digits), line > 0 { return line }
        }
        let withoutFragment = ref.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ref
        if let range = withoutFragment.range(of: #":(\d+)(?::\d+)?$"#, options: .regularExpression) {
            let digits = withoutFragment[range].dropFirst().prefix(while: \.isNumber)
            if let line = Int(digits), line > 0 { return line }
        }
        return nil
    }

    private static func stripLocationSuffix(from path: String) -> String {
        var text = path
        if let hash = text.firstIndex(of: "#") {
            text = String(text[..<hash])
        }
        if let range = text.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }
}
