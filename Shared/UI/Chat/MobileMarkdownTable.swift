#if os(iOS)
import UIKit

/// Mobile Markdown table fallback: each data row becomes a list item instead of
/// a grid. The first cell is the item title; every other non-empty cell becomes
/// a `Header: value` line using the table's own header row. No grid, no
/// horizontal scrolling, and the surrounding prose keeps its normal flow.
@MainActor
enum MobileMarkdownTable {
    static func apply(to text: NSMutableAttributedString, source: AttributedString,
                      bodyFont: UIFont, foreground: UIColor) {
        let tables = MarkdownTableProjection.layouts(in: source)
        for table in tables.reversed() where NSMaxRange(table.range) <= text.length {
            let columns = table.alignments.count
            guard columns > 0 else { continue }
            var cells: [Int: NSAttributedString] = [:]
            for cell in table.cells where cell.column < columns {
                cells[cell.row * columns + cell.column] = trimmed(text.attributedSubstring(from: cell.range))
            }
            let rows = (table.cells.map(\.row).max() ?? 0) + 1
            let headers = (0..<columns).map { column -> NSAttributedString in
                cells[column] ?? NSAttributedString(string: "", attributes: [.font: bodyFont])
            }
            let list = NSMutableAttributedString(string: "")
            var written = 0
            for row in 1..<rows {
                let title = cells[row * columns] ?? NSAttributedString(string: "")
                var fields: [(NSAttributedString, NSAttributedString)] = []
                for column in 1..<columns {
                    let value = cells[row * columns + column] ?? NSAttributedString(string: "")
                    guard !value.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    fields.append((headers[column], value))
                }
                guard !title.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !fields.isEmpty else { continue }
                if written > 0 { list.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: max(8, bodyFont.pointSize * 0.5))])) }
                list.append(item(title: title, fields: fields, bodyFont: bodyFont, foreground: foreground))
                written += 1
            }
            guard written > 0 else {
                text.replaceCharacters(in: table.range, with: "")
                continue
            }
            let replacement = NSMutableAttributedString(attributedString: list)
            if table.range.location > 0, (text.string as NSString).character(at: table.range.location - 1) != 10 {
                replacement.insert(NSAttributedString(string: "\n", attributes: [.font: bodyFont]), at: 0)
            }
            if NSMaxRange(table.range) < text.length {
                replacement.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            }
            text.replaceCharacters(in: table.range, with: replacement)
        }
    }

    private static func item(title: NSAttributedString, fields: [(NSAttributedString, NSAttributedString)],
                             bodyFont: UIFont, foreground: UIColor) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let bullet = NSMutableParagraphStyle()
        bullet.lineSpacing = 2
        bullet.headIndent = bodyFont.pointSize * 1.1
        let bulletText = NSMutableAttributedString(string: "• ", attributes: [
            .font: bodyFont, .foregroundColor: foreground, .paragraphStyle: bullet,
        ])
        bulletText.append(semibold(title, bodyFont: bodyFont))
        bulletText.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        output.append(bulletText)

        let fieldStyle = NSMutableParagraphStyle()
        fieldStyle.lineSpacing = 2
        fieldStyle.headIndent = bodyFont.pointSize * 1.1
        let secondary = foreground.withAlphaComponent(0.62)
        for (header, value) in fields {
            let line = NSMutableAttributedString(string: "  ", attributes: [.font: bodyFont, .foregroundColor: secondary, .paragraphStyle: fieldStyle])
            let label = header.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                line.append(NSAttributedString(string: label + ": ", attributes: [
                    .font: bodyFont, .foregroundColor: secondary,
                ]))
            }
            line.append(value)
            line.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            output.append(line)
        }
        return output
    }

    private static func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        var range = NSRange(location: 0, length: text.length)
        while range.length > 0, string.character(at: range.location) == 10 { range.location += 1; range.length -= 1 }
        while range.length > 0, string.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return text.attributedSubstring(from: range)
    }

    private static func semibold(_ text: NSAttributedString, bodyFont: UIFont) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.font, in: full) { value, range, _ in
            let font = (value as? UIFont) ?? bodyFont
            let traits = font.fontDescriptor.symbolicTraits.union(.traitBold)
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                output.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
            }
        }
        return output
    }
}
#endif
