import Foundation

/// Images the Corral host attaches to a user turn by pasting a file path.
///
/// `input.image` writes the bytes to `<cwd>/.corral-pastes/paste-<random>.<ext>`
/// (or the temp fallback `<tmp>/corral-pastes/…`) and pastes that absolute path
/// into the agent composer, because every supported runtime reads images from a
/// path. The agent transcript therefore carries the path inside the user text:
///
///     ~/.corral-pastes/paste-moofu3ap.jpg这不对 最新消息…
///
/// The chat must show the image, not the temp path, and one send must stay one
/// bubble. So both the optimistic echo and the confirmed transcript derive the
/// same body from that text:
///
/// - `body(_:)` is what the bubble displays and what echo de-duplication and
///   the timeline's "human turn" test compare;
/// - `paths(in:)` are the references the image tiles preview.
nonisolated enum HostPasteAttachment {
    /// `<dir>/.corral-pastes/paste-…` and the temp fallback
    /// `<dir>/corral-pastes/paste-…`; `mkstemp` adds eight `[a-z0-9_]` characters.
    /// The directory keeps its dot optional so both places match one pattern.
    /// The leading run is path characters only, so prose glued to the path
    /// (`看这个/var/…/paste-a.jpg然后继续`) keeps its own words while the whole
    /// absolute path still comes out in one match.
    private nonisolated(unsafe) static let pastedPath =
        /[~.]?\/[A-Za-z0-9@.+_~\/\-]*?corral-pastes\/paste-[A-Za-z0-9_]+\.(?:png|jpe?g|gif|webp|heic|heif|bmp|tiff?)/
            .ignoresCase()

    private nonisolated(unsafe) static let pastedFilePath =
        /[~.]?\/[A-Za-z0-9@.+_~\/\-]*?corral-pastes\/paste-[A-Za-z0-9_]+-(?:[^\s\/]+?(?:\.[A-Za-z0-9]{1,12})+|[A-Za-z0-9._\-]+)/

    static func paths(in text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.matches(of: pastedPath).map { String(text[$0.range]) }
    }

    static func filePaths(in text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let imageRanges = text.matches(of: pastedPath).map(\.range)
        return text.matches(of: pastedFilePath).compactMap { match in
            let range = match.range
            if imageRanges.contains(where: { $0.overlaps(range) }) {
                return nil
            }
            return String(text[range])
        }
    }

    static func displayName(forPastedFilePath path: String) -> String {
        let base = (path as NSString).lastPathComponent
        if let range = base.range(of: #"^paste-[A-Za-z0-9_]+-"#, options: .regularExpression) {
            let trimmed = String(base[range.upperBound...])
            if !trimmed.isEmpty { return trimmed }
        }
        return base.isEmpty ? "file" : base
    }

    /// `text` without the host's pasted attachment paths.
    ///
    /// A paste lands at the composer caret, so the path often sits flush
    /// against typed text (`…jpg这不对`) or leaves a doubled space behind.
    /// The seams are tidied only when a path was actually removed.
    static func body(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let ranges = (text.matches(of: pastedPath).map(\.range) + text.matches(of: pastedFilePath).map(\.range))
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !ranges.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

        var output = ""
        var cursor = text.startIndex
        for range in ranges {
            if range.lowerBound < cursor { continue }
            output += text[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        output += text[cursor...]

        var tidied = ""
        var pendingSpace = false
        for character in output {
            if character.isWhitespace {
                // A newline in the user's own text is meaningful; collapse only
                // the horizontal seam a path removal can leave.
                if character.isNewline {
                    tidied.append(character)
                    pendingSpace = false
                } else {
                    pendingSpace = !tidied.isEmpty
                }
                continue
            }
            if pendingSpace {
                tidied.append(" ")
                pendingSpace = false
            }
            tidied.append(character)
        }
        return tidied.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a user turn is nothing but attached images or files (no typed body).
    static func isAttachmentOnly(_ text: String?) -> Bool {
        let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !raw.isEmpty && body(raw).isEmpty
    }
}
