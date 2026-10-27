import Foundation

/// Shared native Markdown table coordinates; no second source parser is used.
nonisolated enum MarkdownTableProjection {
    struct Cell {
        let row: Int
        let column: Int
        var range: NSRange
    }

    struct Layout {
        let id: Int
        var range: NSRange
        let alignments: [PresentationIntent.TableColumn.Alignment]
        var cells: [Cell]
    }

    static func layouts(in source: AttributedString) -> [Layout] {
        var tables: [Layout] = []
        for (intent, range) in source.runs[\.presentationIntent] {
            guard let intent else { continue }
            var column: Int?
            var row: Int?
            var tableID: Int?
            var alignments: [PresentationIntent.TableColumn.Alignment] = []
            for component in intent.components {
                switch component.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow: row = 0
                case .tableRow(let index): row = index
                case .table(let columns):
                    tableID = component.identity
                    alignments = columns.map(\.alignment)
                default: break
                }
            }
            guard let column, let row, let tableID, !alignments.isEmpty else { continue }
            let nsRange = NSRange(range, in: source)
            let cell = Cell(row: row, column: column, range: nsRange)
            if tables.last?.id == tableID {
                let t = tables.count - 1
                tables[t].range = NSUnionRange(tables[t].range, nsRange)
                if let last = tables[t].cells.last, last.row == row, last.column == column {
                    tables[t].cells[tables[t].cells.count - 1].range = NSUnionRange(last.range, nsRange)
                } else { tables[t].cells.append(cell) }
            } else {
                tables.append(Layout(id: tableID, range: nsRange, alignments: alignments, cells: [cell]))
            }
        }
        return tables
    }
}

#if os(macOS)
import AppKit

/// Mac bubbles draw Markdown tables as native AppKit text tables (design:
/// Markdown tables). `ChatMarkdown` leaves each table cell as its own run; this
/// pass rebuilds every table as `NSTextTableBlock` cell paragraphs, so the
/// bubble's TextKit 1 view lays out aligned columns while selection, Copy and
/// links keep working. The phone reuses the projection with UIKit text tables.
@MainActor
enum MacMarkdownTable {
    /// Horizontal cell padding; the first column starts flush with body text.
    private static let cellPadding: CGFloat = 10
    private static let rowPadding: CGFloat = 5
    /// A long column wraps at this width so short columns keep their content width.
    private static let maxNaturalColumnWidth: CGFloat = 400
    private static let spacingAround: CGFloat = 8

    private typealias Layout = MarkdownTableProjection.Layout

    /// `text` must be the UTF-16-preserving conversion of `source` (fonts may differ).
    static func apply(to text: NSMutableAttributedString, source: AttributedString, bodyFont: NSFont) {
        let tables = MarkdownTableProjection.layouts(in: source)
        let string = text.string as NSString
        for (index, table) in tables.enumerated().reversed() where NSMaxRange(table.range) <= text.length {
            // Two tables separated only by a blank line need their own gap.
            let followsTable = index > 0 && {
                let previousEnd = NSMaxRange(tables[index - 1].range)
                let gap = NSRange(location: previousEnd, length: max(table.range.location - previousEnd, 0))
                return string.substring(with: gap).allSatisfy(\.isNewline)
            }()
            replace(table, in: text, bodyFont: bodyFont, followsTable: followsTable)
        }
    }

    private static func replace(
        _ layout: Layout, in text: NSMutableAttributedString, bodyFont: NSFont, followsTable: Bool
    ) {
        let columns = layout.alignments.count
        let rows = (layout.cells.map(\.row).max() ?? 0) + 1
        var contents: [Int: NSAttributedString] = [:]
        for cell in layout.cells where cell.column < columns {
            contents[cell.row * columns + cell.column] = trimmingNewlines(text.attributedSubstring(from: cell.range))
        }

        // Column widths follow their content (Fixed layout with shares of the
        // natural width); the table never exceeds the bubble and shrinks evenly.
        var widths = Array(repeating: CGFloat(1), count: columns)
        for (index, content) in contents {
            let measured = content.boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width
            let column = index % columns
            widths[column] = max(widths[column], min(ceil(measured) + 2, maxNaturalColumnWidth))
        }
        let padding = (0..<columns).map { $0 == 0 ? cellPadding : cellPadding * 2 }
        let natural = zip(widths, padding).reduce(CGFloat(0)) { $0 + $1.0 + $1.1 }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setValue(natural + 2, type: .absoluteValueType, for: .width)
        table.setValue(100, type: .percentageValueType, for: .maximumWidth)

        let output = NSMutableAttributedString()
        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(
                    table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1
                )
                block.setValue(widths[column] / natural * 100, type: .percentageValueType, for: .width)
                block.setWidth(rowPadding, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(rowPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(column == 0 ? 0 : cellPadding, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(cellPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
                // Quiet rules only: a firmer line under the header, hairlines between rows.
                block.setWidth(row == 0 ? 1 : 0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(row == 0 ? .tertiaryLabelColor : .separatorColor, for: .maxY)

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineSpacing = ChatMarkdown.MacRhythm.lineSpacing
                style.alignment = alignment(layout.alignments[column])

                let cell = NSMutableAttributedString(
                    attributedString: contents[row * columns + column]
                        ?? NSAttributedString(string: "\u{00A0}", attributes: [.font: bodyFont])
                )
                cell.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
                output.append(cell)
            }
        }

        // ChatMarkdown's paragraph break after the table is part of the last
        // cell's run (inserted text takes the attributes before it), so the
        // range ends where the next block starts.
        let range = layout.range
        let string = text.string as NSString
        let hasTextAfter = NSMaxRange(range) < string.length
        let needsBreakBefore = range.location > 0 && string.character(at: range.location - 1) != 0x0A
        if !hasTextAfter {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        if followsTable {
            // A short empty paragraph; block margins would narrow the columns.
            let spacer = NSFont.systemFont(ofSize: spacingAround)
            output.insert(NSAttributedString(string: "\n", attributes: [.font: spacer]), at: 0)
        }
        if needsBreakBefore {
            output.insert(NSAttributedString(string: "\n", attributes: [.font: bodyFont]), at: 0)
        }
        text.replaceCharacters(in: range, with: output)

        let after = range.location + output.length
        if hasTextAfter, after < text.length {
            addSpacing(before: true, at: after, in: text)
        }
        if range.location > 0 {
            addSpacing(before: false, at: range.location - 1, in: text)
        }
    }

    /// Separates the table from neighbouring paragraphs without padding its cells.
    private static func addSpacing(before: Bool, at location: Int, in text: NSMutableAttributedString) {
        let paragraph = (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let existing = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        guard existing?.textBlocks.isEmpty ?? true else { return }
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        if before {
            style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, spacingAround)
        } else {
            style.paragraphSpacing = max(style.paragraphSpacing, spacingAround)
        }
        text.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }

    private static func alignment(_ alignment: PresentationIntent.TableColumn.Alignment) -> NSTextAlignment {
        switch alignment {
        case .center: .center
        case .right: .right
        default: .natural
        }
    }

    private static func trimmingNewlines(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        var start = 0
        var end = string.length
        while start < end, string.character(at: start) == 0x0A { start += 1 }
        while end > start, string.character(at: end - 1) == 0x0A { end -= 1 }
        return text.attributedSubstring(from: NSRange(location: start, length: end - start))
    }
}
#endif
