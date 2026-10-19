import Foundation

/// Hit-line windowing shared by the Mac search panel and iPhone results.
/// Host spans count Unicode scalars (Python string offsets), so windowing and
/// highlight ranges stay in scalar offsets until they reach the text view.
nonisolated enum FulltextSnippet {
    struct Window: Equatable, Sendable {
        let text: String
        /// Highlight ranges as Unicode-scalar offsets into `text`.
        let ranges: [Range<Int>]
    }

    /// A first hit later than `maxLeadScalars` reopens the line `lead`
    /// scalars before it, after an ellipsis, so the keyword stays visible.
    static func window(_ line: FulltextLine, maxLeadScalars: Int, lead: Int) -> Window {
        let valid = line.spans.filter { $0.count == 2 && $0[0] >= 0 && $0[0] < $0[1] }
        var scalars = Array(line.text.unicodeScalars)
        var shift = 0
        if let first = valid.first?[0], first > maxLeadScalars, first < scalars.count {
            let start = max(0, first - lead)
            scalars = Array("…".unicodeScalars) + scalars[start...]
            shift = 1 - start
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let ranges = valid.compactMap { span -> Range<Int>? in
            let start = span[0] + shift, end = min(span[1] + shift, scalars.count)
            return start >= 0 && start < end ? start..<end : nil
        }
        return Window(text: String(view), ranges: ranges)
    }
}
