import Foundation
import SwiftTerm

/// A selection retains its history identity through sheet dismissal/view updates.
struct TerminalPromptRequest: Identifiable {
    let id = UUID()
    let seq: Int
    let generation: Int
}

extension TerminalView {
    /// Search the actual buffer, preserving wide glyphs at soft-wrap boundaries.
    /// SwiftTerm's native scroll API owns viewport movement. No input is sent.
    func revealPrompt(_ query: String) -> Bool {
        let emulator = getTerminal()
        let trimmed = emulator.buffer.totalLinesTrimmed
        var projection = ""
        var rowEnds: [(end: Int, row: Int)] = []
        var pendingSpace = false
        var utf16Length = 0
        var row = trimmed
        while let line = emulator.getScrollInvariantLine(row: row) {
            if row > trimmed && !line.isWrapped { pendingSpace = true }
            // Translation skips only null cells belonging to a wide glyph;
            // it never removes the final translated character (CJK regression).
            let next = emulator.getScrollInvariantLine(row: row + 1)
            let continues = next?.isWrapped == true
            var endColumn = line.count
            // A wide glyph moved to the next row may leave one unused cell.
            // Exclude only that null padding, never a wide glyph's trailing half.
            if continues, let next, endColumn > 1, next[0].width == 2,
               line[endColumn - 1].getCharacter() == "\u{0}", line[endColumn - 2].width != 2 {
                endColumn -= 1
            }
            let text = line.translateToString(trimRight: !continues, endCol: endColumn,
                                              skipNullCellsFollowingWide: true,
                                              characterProvider: { emulator.getCharacter(for: $0) })
            for character in text {
                if character.isWhitespace {
                    pendingSpace = true
                } else {
                    if pendingSpace && !projection.isEmpty { projection.append(" "); utf16Length += 1 }
                    pendingSpace = false
                    projection.append(character)
                    utf16Length += String(character).utf16.count
                }
            }
            rowEnds.append((utf16Length, row - trimmed))
            row += 1
        }
        guard !query.isEmpty, let match = projection.range(of: query, options: .literal),
              projection.range(of: query, options: .literal,
                               range: projection.index(after: match.lowerBound)..<projection.endIndex) == nil else { return false }
        let position = match.lowerBound.utf16Offset(in: projection)
        guard let target = rowEnds.first(where: { $0.end > position })?.row else { return false }
        if !emulator.isCurrentBufferAlternate { scrollTo(row: max(0, target - emulator.rows / 3)) }
        return true
    }
}
