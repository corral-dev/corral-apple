import Foundation

/// Plain-text projection for system notifications; never changes the transcript.
nonisolated enum NotificationPreview {
    static let characterLimit = 160
    private static let parserByteLimit = 16_384

    static func body(_ source: String, fallback: String) -> String {
        var input = ""
        var bytes = 0
        for character in source {
            let size = String(character).utf8.count
            guard bytes + size <= parserByteLimit else { break }
            input.append(character)
            bytes += size
        }
        let wasBounded = input.count < source.count
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        var plain = ""
        if let parsed = try? AttributedString(markdown: input, options: options) {
            var previousBlock: Int?
            for run in parsed.runs {
                if run.presentationIntent?.components.contains(where: {
                    if case .thematicBreak = $0.kind { return true }
                    return false
                }) == true { continue }
                let block = run.presentationIntent?.components.first?.identity
                if let previousBlock, let block, block != previousBlock, !plain.hasSuffix("\n") {
                    plain.append("\n")
                }
                var text = String(parsed[run.range].characters)
                let isCode = run.inlinePresentationIntent?.contains(.code) == true
                    || run.presentationIntent?.components.contains(where: {
                        if case .codeBlock = $0.kind { return true }
                        return false
                    }) == true
                if !isCode {
                    // CommonMark can leave emphasis literal beside CJK punctuation.
                    text = text.replacingOccurrences(
                        of: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#,
                        with: "$1", options: .regularExpression
                    )
                }
                plain.append(text)
                previousBlock = block
            }
        } else {
            plain = input
        }
        plain = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !plain.isEmpty else { return fallback }
        guard plain.count > characterLimit || wasBounded else { return plain }
        return String(plain.prefix(characterLimit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
