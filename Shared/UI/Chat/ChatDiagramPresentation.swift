import Observation
import PDFKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
@Observable
final class ChatDiagramStore {
    let hostID: String
    private var completed: [String: Int] = [:]
    var inspection: ChatDiagramInspection?

    init(hostID: String) {
        self.hostID = hostID
        ChatDiagramRenderer.shared.allow(host: hostID)
    }

    func revision(text: String, dark: Bool) -> Int {
        let blocks = ChatMarkdown.diagrams(in: text)
        return blocks.reduce(blocks.isEmpty || !dark ? 0 : 100_000) { value, block in
            value &+ (completed[ChatDiagramRenderer.shared.key(host: hostID, block: block, dark: dark)] ?? 0)
        }
    }

    func prepare(text: String, dark: Bool) async {
        let blocks = ChatMarkdown.diagrams(in: text)
        if blocks.contains(where: \.progressive) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        for block in blocks {
            guard !Task.isCancelled else { return }
            let drawing = await ChatDiagramRenderer.shared.render(host: hostID, block: block, dark: dark)
            guard !Task.isCancelled else { return }
            if drawing != nil {
                let key = ChatDiagramRenderer.shared.key(host: hostID, block: block, dark: dark)
                completed[key] = 1
                if completed.count > 512 { completed = [key: 1] }
            }
        }
    }

    func attributed(text: String, dark: Bool) -> AttributedString {
        let base = ChatMarkdown.attributed(text)
        let blocks = ChatMarkdown.diagrams(in: text)
        guard !blocks.isEmpty else { return base }
        _ = revision(text: text, dark: dark)
        let native = NSMutableAttributedString(attributedString: NSAttributedString(base))
        let plain = String(base.characters)
        var replacements: [(NSRange, ChatDiagramBlock, ChatDiagramDrawing)] = []
        for block in blocks {
            guard let drawing = ChatDiagramRenderer.shared.cached(host: hostID, block: block, dark: dark) else { continue }
            if let id = block.codeIdentity {
                let ranges = base.runs.filter { run in
                    run.presentationIntent?.components.contains(where: { $0.identity == id }) == true
                }.map(\.range)
                guard let first = ranges.first, let last = ranges.last,
                      let start = String.Index(first.lowerBound, within: plain),
                      let end = String.Index(last.upperBound, within: plain) else { continue }
                var range = NSRange(start..<end, in: plain)
                // The structural newline belongs to the preceding block, not
                // the drawing. Keep paragraph boundaries around attachments.
                while range.length > 0, (native.string as NSString).substring(with: NSRange(location: range.location, length: 1)) == "\n" {
                    range.location += 1; range.length -= 1
                }
                replacements.append((range, block, drawing))
            } else {
                replacements.append((NSRange(location: 0, length: native.length), block, drawing))
            }
        }
        for (range, block, drawing) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            let attachment = ChatDiagramAttachment(drawing: drawing, original: block.original, selectionLength: max(1, range.length - 1)) { [weak self] in
                self?.inspection = ChatDiagramInspection(drawing: drawing, source: block.original)
            }
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttribute(.font, value: PlatformFont.systemFont(ofSize: ChatMarkdown.referenceBodyPointSize),
                                     range: NSRange(location: 0, length: replacement.length))
            replacement.append(NSAttributedString(string: "\n"))
            native.replaceCharacters(in: range, with: replacement)
        }
        return AttributedString(native)
    }
}

nonisolated final class ChatDiagramAttachment: NSTextAttachment {
    let original: String
    let selectionLength: Int
    private let naturalSize: CGSize
    private let openAction: @MainActor () -> Void

    @MainActor init(drawing: ChatDiagramDrawing, original: String, selectionLength: Int, open: @escaping @MainActor () -> Void) {
        self.original = original
        self.selectionLength = selectionLength
        naturalSize = drawing.size
        openAction = open
        super.init(data: nil, ofType: nil)
        image = drawing.image
        bounds = CGRect(origin: .zero, size: drawing.size)
    }
    required init?(coder: NSCoder) { return nil }
    @MainActor func open() { openAction() }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        #if canImport(UIKit)
        let font = textContainer?.layoutManager?.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? UIFont
        #else
        let font = textContainer?.layoutManager?.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont
        #endif
        let fontScale = (font?.pointSize ?? 17) / 16
        let available = max(32, min(textContainer?.size.width ?? lineFrag.width, lineFrag.width) - 16)
        let scale = min(fontScale, available / naturalSize.width)
        return CGRect(x: 0, y: 0, width: naturalSize.width * scale, height: naturalSize.height * scale)
    }

    /// Expand only selected attachment positions; adjacent prose retains its
    /// existing native plain-text representation, including multi-message Copy.
    static func plainText(_ text: NSAttributedString, range: NSRange) -> String? {
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        let selected = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        var replacements: [(NSRange, String)] = []
        selected.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            if let diagram = value as? ChatDiagramAttachment { replacements.append((range, diagram.original)) }
        }
        guard !replacements.isEmpty else { return nil }
        for (range, source) in replacements.reversed() { selected.replaceCharacters(in: range, with: source) }
        return selected.string
    }
}

#if os(macOS)
extension ChatDiagramAttachment: MacMessageMediaAttachment {}
#endif

struct ChatDiagramInspection: Identifiable {
    let id = UUID()
    let drawing: ChatDiagramDrawing
    let source: String
}

struct ChatDiagramViewer: View {
    let inspection: ChatDiagramInspection
    @Environment(\.dismiss) private var dismiss
    @State private var source = false

    private var idealHeight: CGFloat {
        let width = max(inspection.drawing.size.width, 1)
        let aspect = inspection.drawing.size.height / width
        return min(820, max(280, 760 * aspect + 96))
    }

    var body: some View {
        NavigationStack {
            Group {
                if source {
                    ScrollView { Text(verbatim: inspection.source).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }
                } else { ChatDiagramPDF(data: inspection.drawing.pdf) }
            }
            .navigationTitle(Text("chat.diagram.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } }
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    Picker("chat.diagram.title", selection: $source) {
                        Text("chat.diagram.title").tag(false)
                        Text("chat.diagram.source").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                #else
                ToolbarItem(placement: .principal) {
                    Picker("chat.diagram.title", selection: $source) {
                        Text("chat.diagram.title").tag(false)
                        Text("chat.diagram.source").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 800, minHeight: 280, idealHeight: idealHeight)
        #endif
    }
}

#if canImport(UIKit)
private struct ChatDiagramPDF: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        view.backgroundColor = .systemBackground
        view.pageShadowsEnabled = false
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#else
private struct ChatDiagramPDF: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        // The page is transparent so the drawing's light/dark ink composites
        // on the sheet's own surface instead of WebKit's white paper.
        view.backgroundColor = .windowBackgroundColor
        view.pageShadowsEnabled = false
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}
#endif
