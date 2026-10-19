import SwiftUI

/// Hit line as text: keywords bold in accent, windowed so the first one shows.
enum FulltextHighlight {
    static func text(_ line: FulltextLine, maxLeadScalars: Int, lead: Int) -> Text {
        let window = FulltextSnippet.window(line, maxLeadScalars: maxLeadScalars, lead: lead)
        var attributed = AttributedString(window.text)
        let scalars = attributed.unicodeScalars
        for range in window.ranges {
            let lower = scalars.index(scalars.startIndex, offsetBy: range.lowerBound)
            let upper = scalars.index(scalars.startIndex, offsetBy: range.upperBound)
            attributed[lower..<upper].foregroundColor = Palette.accent
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }
}
