import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Chat-bubble markdown. Parsing runs on the caller's thread (often main during
/// SwiftUI body), so keep it bounded and cached.
///
/// Foundation's `.inlineOnly*` modes leave headings / lists / tables as literal
/// markers. `.full` strips markers but does not insert newlines or bullets, so
/// we turn presentation intents into visible structure and fonts here.
nonisolated enum ChatMarkdown: Sendable {
    /// Above this size, skip Foundation markdown and show plain text.
    /// Long agent replies must not block scene updates long enough for watchdog kill.
    static let maxInlineMarkdownUTF8Count = 16_384

    /// Reference body size baked into cached fonts. Display layer rescales to the
    /// session text size from this baseline.
    static let referenceBodyPointSize: CGFloat = 17

    private final class CacheBox: NSObject {
        let value: AttributedString
        let diagrams: [ChatDiagramBlock]
        init(_ value: AttributedString, diagrams: [ChatDiagramBlock] = []) {
            self.value = value
            self.diagrams = diagrams
        }
    }

    // NSCache is thread-safe; mark unsafe for Swift 6 static isolation checks.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CacheBox> = {
        let cache = NSCache<NSString, CacheBox>()
        cache.countLimit = 256
        // Attributed strings retain runs, fonts and colors well beyond the
        // source bytes; a byte budget bounds many short bodies as well as the
        // count limit bounds body count.
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Drop parsed bodies under system memory pressure; text re-parses cheaply.
    static func purgeCache() {
        cache.removeAllObjects()
    }

    /// Bubble text without leading or trailing blanks (spaces, blank lines,
    /// and newlines the structure pass inserts); inner blank lines stay.
    static func attributed(_ source: String) -> AttributedString {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.utf8.count > maxInlineMarkdownUTF8Count {
            return AttributedString(source)
        }

        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        let parsed = parse(source)
        let result = trimmed(style(parsed))
        let diagrams = ChatDiagramBlock.candidates(source: source, parsed: parsed)
        // Four bytes per source byte is a conservative rendered-size estimate.
        cache.setObject(CacheBox(result, diagrams: diagrams), forKey: key, cost: max(64, source.utf8.count * 4))
        return result
    }

    static func diagrams(in source: String) -> [ChatDiagramBlock] {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = attributed(source)
        return cache.object(forKey: source as NSString)?.diagrams ?? []
    }

    private static func trimmed(_ text: AttributedString) -> AttributedString {
        let characters = text.characters
        guard let first = characters.firstIndex(where: { !$0.isWhitespace }),
              let last = characters.lastIndex(where: { !$0.isWhitespace }) else {
            return AttributedString()
        }
        return AttributedString(text[first...last])
    }

    /// The first parse in a process pays the markdown parser and font setup (~15 ms on
    /// Apple silicon) and the first block quote another ~15 ms. Pay it at launch on a
    /// background thread instead of during the first conversation's body.
    static func prewarm() {
        Task.detached(priority: .utility) {
            _ = style(parse(prewarmSample))
        }
    }

    private static let prewarmSample = """
        # 标题 Heading
        **加粗 bold** *italic* `code` ~~strike~~ [link](/a/b.md:1) “引号”

        > quote 引用

        - item
        1. ordered

        | a | b |
        |---|---|
        | 1 | 2 |

        ```
        code block
        ```
        """

    /// Test hook: drop cached parses between cases.
    static func clearCacheForTests() {
        cache.removeAllObjects()
    }

    private static func parse(_ source: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.appliesSourcePositionAttributes = true
        if let parsed = try? AttributedString(markdown: source, options: options) {
            return parsed
        }
        return AttributedString(source)
    }

    private static func style(_ parsed: AttributedString) -> AttributedString {
        var text = parsed
        let bodySize = referenceBodyPointSize
        let bodyFont = PlatformFont.systemFont(ofSize: bodySize)
        text.font = bodyFont

        applyInlineStyles(&text, bodySize: bodySize)
        applyBlockStyles(&text, bodySize: bodySize)
        return text
    }

    private static func applyInlineStyles(_ text: inout AttributedString, bodySize: CGFloat) {
        for (intent, range) in text.runs[\.inlinePresentationIntent].reversed() {
            guard let intent else { continue }
            if intent.contains(.stronglyEmphasized) {
                text[range].font = PlatformFont.systemFont(ofSize: bodySize, weight: .semibold)
            } else if intent.contains(.emphasized) {
                if let italic = italicFont(size: bodySize) {
                    text[range].font = italic
                }
            }
            if intent.contains(.code) {
                text[range].font = PlatformFont.monospacedSystemFont(ofSize: bodySize * 0.92, weight: .regular)
            }
            if intent.contains(.strikethrough) {
                text[range].inlinePresentationIntent = intent
                var attrs = AttributeContainer()
                #if canImport(UIKit)
                attrs.uiKit.strikethroughStyle = .single
                #else
                attrs.appKit.strikethroughStyle = .single
                #endif
                text[range].mergeAttributes(attrs)
            }
        }
    }

    private static func applyBlockStyles(_ text: inout AttributedString, bodySize: CGFloat) {
        var previousListID = 0

        for (intentBlock, intentRange) in text.runs[\.presentationIntent].reversed() {
            guard let intentBlock else { continue }

            var headerLevel: Int?
            var isUnordered = false
            var isOrdered = false
            var listOrdinal = 0
            var listID = 0
            var isCodeBlock = false
            var isBlockQuote = false
            var tableColumn: Int?
            var isTableHeader = false

            for intent in intentBlock.components {
                switch intent.kind {
                case .header(let level):
                    headerLevel = level
                case .unorderedList:
                    isUnordered = true
                    listID = intent.identity
                case .orderedList:
                    isOrdered = true
                    listID = intent.identity
                case .listItem(let ordinal):
                    listOrdinal = ordinal
                case .codeBlock:
                    isCodeBlock = true
                case .blockQuote:
                    isBlockQuote = true
                case .tableHeaderRow:
                    isTableHeader = true
                case .tableCell(let columnIndex):
                    tableColumn = columnIndex
                case .paragraph, .table, .tableRow, .thematicBreak:
                    break
                @unknown default:
                    break
                }
            }

            if let column = tableColumn {
                if isTableHeader {
                    text[intentRange].font = PlatformFont.systemFont(ofSize: bodySize, weight: .semibold)
                }
                #if os(macOS)
                // One paragraph per cell; the Mac bubble lays them out as a
                // native text table (MacMarkdownTable).
                if intentRange.lowerBound != text.startIndex {
                    text.characters.insert(contentsOf: "\n", at: intentRange.lowerBound)
                }
                #else
                // The phone is too narrow for a grid: flat `cell | cell` rows.
                if column > 0 {
                    text.characters.insert(contentsOf: " | ", at: intentRange.lowerBound)
                } else if intentRange.lowerBound != text.startIndex {
                    text.characters.insert(contentsOf: "\n", at: intentRange.lowerBound)
                }
                #endif
                previousListID = 0
                continue
            }

            if let level = headerLevel {
                let size: CGFloat
                switch level {
                case 1: size = bodySize * 1.35
                case 2: size = bodySize * 1.22
                default: size = bodySize * 1.1
                }
                text[intentRange].font = PlatformFont.systemFont(ofSize: size, weight: .semibold)
                #if os(macOS)
                text[intentRange].paragraphStyle = MacRhythm.heading(level: level)
                #endif
            } else if isUnordered {
                text.characters.insert(contentsOf: "•\t", at: intentRange.lowerBound)
                text[intentRange].paragraphStyle = listParagraphStyle(
                    continuing: previousListID == listID
                )
            } else if isOrdered {
                text.characters.insert(contentsOf: "\(listOrdinal).\t", at: intentRange.lowerBound)
                text[intentRange].paragraphStyle = listParagraphStyle(
                    continuing: previousListID == listID
                )
            } else if isCodeBlock {
                text[intentRange].font = PlatformFont.monospacedSystemFont(
                    ofSize: bodySize * 0.92,
                    weight: .regular
                )
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = 8
                style.headIndent = 8
                style.paragraphSpacing = 6
                text[intentRange].paragraphStyle = style
            } else if isBlockQuote {
                var attrs = AttributeContainer()
                #if canImport(UIKit)
                attrs.uiKit.foregroundColor = .secondaryLabel
                #else
                attrs.appKit.foregroundColor = .secondaryLabelColor
                #endif
                text[intentRange].mergeAttributes(attrs)
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = 12
                style.headIndent = 12
                #if os(macOS)
                style.lineSpacing = MacRhythm.lineSpacing
                style.paragraphSpacing = MacRhythm.paragraphSpacing
                #endif
                text[intentRange].paragraphStyle = style
            } else {
                #if os(macOS)
                text[intentRange].paragraphStyle = MacRhythm.paragraph(
                    String(text[intentRange].characters),
                    boldLead: isBoldOnly(text[intentRange])
                )
                #endif
            }

            if intentRange.lowerBound != text.startIndex {
                text.characters.insert(contentsOf: "\n", at: intentRange.lowerBound)
            }
            previousListID = listID
        }
    }

    private static func listParagraphStyle(continuing: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
        style.headIndent = 18
        #if os(macOS)
        style.lineSpacing = MacRhythm.lineSpacing
        style.paragraphSpacing = continuing ? 2 : MacRhythm.paragraphSpacing
        #else
        style.paragraphSpacing = continuing ? 2 : 6
        #endif
        return style
    }

    /// A paragraph written entirely in bold, used by agents as a heading.
    private static func isBoldOnly(_ block: AttributedSubstring) -> Bool {
        var sawBold = false
        for (intent, range) in block.runs[\.inlinePresentationIntent] {
            if intent?.contains(.stronglyEmphasized) == true {
                sawBold = true
            } else if !block[range].characters.allSatisfy(\.isWhitespace) {
                return false
            }
        }
        return sawBold
    }

    #if os(macOS)
    /// Mac reading rhythm (design: Visual guidance pass). Blocks separate
    /// visibly; a heading, a bold lead-in or a line ending in a colon stays
    /// close to what it introduces; list items stay tight inside a list.
    enum MacRhythm {
        static let lineSpacing: CGFloat = 4
        static let paragraphSpacing: CGFloat = 10
        static let introSpacing: CGFloat = 5

        static func heading(level: Int) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacingBefore = level <= 2 ? 10 : 8
            style.paragraphSpacing = introSpacing
            return style
        }

        static func paragraph(_ text: String, boldLead: Bool) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            if boldLead {
                style.paragraphSpacingBefore = 8
                style.paragraphSpacing = introSpacing
            } else {
                let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last
                style.paragraphSpacing = last == ":" || last == "：" ? introSpacing : paragraphSpacing
            }
            return style
        }
    }
    #endif

    private static func italicFont(size: CGFloat) -> PlatformFont? {
        let base = PlatformFont.systemFont(ofSize: size)
        var traits = base.fontDescriptor.symbolicTraits
        #if canImport(UIKit)
        traits.insert(.traitItalic)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return nil
        }
        return PlatformFont(descriptor: descriptor, size: size)
        #else
        traits.insert(.italic)
        return PlatformFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size)
        #endif
    }
}
