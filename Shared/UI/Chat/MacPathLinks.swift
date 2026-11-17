import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Path mentions in message text become Finder links (owner request
/// 2026-11-08: clicking a path opens the folder it is in). Covers absolute,
/// `~/` and project-relative paths (resolved against the session directory),
/// with `:line[:column]` or `#Lline` suffixes. A path is linked only when it
/// exists on this Mac, or when its parent folder does (a deleted file still
/// opens its folder); explicit Markdown links win. The click is handled by
/// `MacPathLinks.open`: a folder opens, a file is revealed selected in Finder.
/// iOS never gets these links (paths belong to the dev machine).
enum MacPathLinks {
    private static let pathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?<![\\w/.~:@-])(?:~?/[\\w\\-.+@=%,]+(?:/[\\w\\-.+@=%,]*)*|(?:\\.{1,2}/)?[\\w\\-.+@]+(?:/[\\w\\-.+@]+)+/?|[\\w\\-+@]+\\.[A-Za-z][A-Za-z0-9]{0,7})(?:(?::\\d+){1,2}|#L\\d+(?:-L?\\d+)?)?",
        options: []
    )
    private static let locationSuffix: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?:(?::\\d+){1,2}|#L\\d+(?:-L?\\d+)?)$", options: []
    )
    private static let spaceTokenCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.+@=%,/"
    )

    static func apply(to mutable: NSMutableAttributedString, workingDirectory: String?) {
        guard let regex = pathRegex else { return }
        let string = mutable.string as NSString
        let full = NSRange(location: 0, length: string.length)
        guard full.length > 0, full.length < 32_768 else { return }
        let matches = regex.matches(in: mutable.string, options: [], range: full)
        guard !matches.isEmpty else { return }
        let base = workingDirectory.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        // Walk backwards so earlier ranges stay valid as we add attributes.
        for match in matches.reversed() {
            var range = trimmed(match.range, in: string)
            guard range.length > 2 else { continue }
            var hasLink = false
            mutable.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
                if value != nil { hasLink = true; stop.pointee = true }
            }
            if hasLink { continue }
            range = extendOverSpaces(range, in: string, base: base)
            guard let url = target(for: string.substring(with: range), base: base) else { continue }
            mutable.addAttribute(.link, value: url, range: range)
        }
    }

    /// Opens a path link in Finder; false for any other link. macOS-only by
    /// nature (iOS has no path links), and the class is shared with the iOS
    /// target, so the Finder side is compiled out rather than left unguarded.
    @discardableResult
    static func open(_ link: Any) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), url.isFileURL else {
            return false
        }
        #if os(macOS)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
        #endif
        return true
    }

    /// The file URL a mention points to: the path itself when it exists,
    /// otherwise its existing parent folder.
    static func target(for raw: String, base: String?) -> URL? {
        var path = raw
        if let suffix = locationSuffix?.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) {
            path = (path as NSString).substring(to: suffix.range.location)
        }
        guard let resolved = resolve(path, base: base) else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: resolved, isDirectory: &isDirectory) {
            return URL(fileURLWithPath: resolved, isDirectory: isDirectory.boolValue)
        }
        // Only an explicit path (with a folder part) falls back to its folder.
        guard path.contains("/") else { return nil }
        let parent = (resolved as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/", fm.fileExists(atPath: parent, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: parent, isDirectory: true)
    }

    private static func resolve(_ path: String, base: String?) -> String? {
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        if path.hasPrefix("/") { return path }
        guard let base else { return nil }
        return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// Drop sentence punctuation the chat text leaves after a path.
    private static func trimmed(_ range: NSRange, in string: NSString) -> NSRange {
        var range = range
        while range.length > 1 {
            let last = string.character(at: NSMaxRange(range) - 1)
            guard let scalar = UnicodeScalar(last), ".,;!?)]}'\"".unicodeScalars.contains(scalar) else { break }
            range.length -= 1
        }
        return range
    }

    /// Paths with spaces ("My Documents"): the regex stops at the first space,
    /// so extend over ` + token` while the extended path exists on disk.
    private static func extendOverSpaces(_ range: NSRange, in string: NSString, base: String?) -> NSRange {
        var range = range
        let total = string.length
        while NSMaxRange(range) < total {
            let cursor = NSMaxRange(range)
            guard string.character(at: cursor) == 32 /* space */ else { break }
            var next = cursor + 1
            while next < total && string.character(at: next) == 32 { next += 1 }
            var end = next
            while end < total, let scalar = UnicodeScalar(string.character(at: end)),
                  spaceTokenCharacters.contains(scalar) { end += 1 }
            guard end > next else { break }
            let candidate = string.substring(with: NSRange(location: range.location, length: end - range.location))
            guard let resolved = resolve(candidate, base: base),
                  FileManager.default.fileExists(atPath: resolved) else { break }
            range.length = end - range.location
        }
        return range
    }
}
