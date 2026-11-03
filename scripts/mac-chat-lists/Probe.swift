import AppKit

/// Regression probe for the Mac conversation's shared text network: a list that
/// starts a message must keep its marker flush and its text on the same line.
///
/// TextKit lays the first line after a `.containerBreak` out as a continuation
/// of the break, applying `headIndent` instead of `firstLineHeadIndent`. Lists
/// use a hanging indent, so that quirk used to push the marker to the indent and
/// eject the tabbed text onto the next line, making the drawn message one line
/// taller than its measured row. See
/// docs/troubleshooting/2026-10-27-mac-message-first-line-list-indent.md.
///
/// Production sources are compiled directly; data is a fixture, no preferences,
/// sessions or pointer events are used.
@main
struct MacChatListsProbe {
    static let numbered = """
    1. 流程日志的写法改造现在就安排subagent来实现
    2. 流程步骤记录保留多少天，这个问题不是冷热表分离吗？如果是的话，一样地安排subagent做冷热分离调研和设计以及实现
    3. 业务优先，不要阻塞业务
    6. 这部分你打算怎么实现呢？全局计划/体系/配置缓存？
    """
    static let bulleted = "- 打开旧会话时先显示上次看过的尾巴\n- 换网重连不再整段冷启动拉历史"
    static let plain = "上一条消息"
    static let rowWidth: CGFloat = 826
    static let bodyPointSize: CGFloat = 16.1

    static var failures: [String] = []

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkLeadingParagraphSpacing()
        checkImageSeparators()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rowWidth + 40, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth + 40, height: 640))
        window.contentView = holder
        window.orderFront(nil)

        let sources: [MacConversationTextDocument.Source] = [
            .init(id: 1, text: plain, isUser: true),
            .init(id: 2, text: numbered, isUser: true),
            .init(id: 3, text: bulleted, isUser: true),
            .init(id: 4, text: plain, isUser: false),
        ]
        let document = makeDocument(sources)

        // Realize every row like the conversation table does, one mount each.
        var mounts: [MacMessageTextMount] = []
        for source in sources {
            guard let view = document.textView(for: source.id) else {
                failures.append("no text view for message \(source.id)")
                continue
            }
            let mount = MacMessageTextMount(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 120))
            holder.addSubview(mount)
            mount.attach(view)
            mount.needsLayout = true
            mounts.append(mount)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        for mount in mounts { mount.layoutSubtreeIfNeeded() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        for source in sources {
            guard let view = document.textView(for: source.id),
                  let layout = view.layoutManager,
                  let container = view.textContainer else { continue }
            layout.ensureLayout(for: container)
            let lines = lineFragments(layout: layout, container: container, storage: view.string as NSString)
            let height = layout.usedRect(for: container).height
            let measured = document.measurement(for: source.id)?.size(
                for: document.text(for: source.id) ?? NSAttributedString(string: ""),
                font: NSFont.systemFont(ofSize: bodyPointSize),
                width: rowWidth,
                hasPrecedingBlock: document.hasPrecedingBlock(source.id),
                hasFollowingBlock: source.id < sources.count
            ).height ?? -1
            check(source: source, lines: lines, drawnHeight: height, measuredHeight: measured)
        }

        window.close()
        if failures.isEmpty {
            print("PASS Mac list-first layout and 560 paragraph-boundary/width/font transitions fit every final line")
        } else {
            failures.forEach { print("FAIL \($0)") }
            exit(1)
        }
    }

    @MainActor static func makeDocument(_ sources: [MacConversationTextDocument.Source]) -> MacConversationTextDocument {
        let font = NSFont.systemFont(ofSize: bodyPointSize)
        let style = MacConversationTextDocument.Style(
            font: font, foreground: .labelColor, userForeground: .labelColor
        )
        let document = MacConversationTextDocument()
        document.update(identity: ObjectIdentifier(document), sources: sources, style: style) { source in
            render(source, font: font)
        }
        return document
    }

    /// Mirrors MacMessageTextRenderer.convert: keep ChatMarkdown's relative font
    /// sizes and colors, scale to the session's body size.
    @MainActor static func render(_ source: MacConversationTextDocument.Source, font: NSFont) -> NSAttributedString {
        let attributed = ChatMarkdown.attributed(source.text)
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let reference = ChatMarkdown.referenceBodyPointSize
        mutable.enumerateAttributes(in: NSRange(location: 0, length: mutable.length)) { attributes, range, _ in
            if let existing = attributes[.font] as? NSFont {
                let ratio = existing.pointSize / max(reference, 1)
                mutable.addAttribute(.font, value: NSFont(descriptor: existing.fontDescriptor, size: font.pointSize * ratio) ?? font,
                                     range: range)
            } else {
                mutable.addAttribute(.font, value: font, range: range)
            }
            if attributes[.foregroundColor] == nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return mutable
    }

    /// A detached row must model both native container boundaries. A bold lead
    /// or heading has spacing-before that TextKit omits at storage start but
    /// honors after the live container's near-zero paragraph start.
    @MainActor static func checkLeadingParagraphSpacing() {
        let samples = [
            "**A bold lead 标题**\n\nA wrapped paragraph 中文 with a final readable line.\n\n最后一行必须完整显示。",
            "# Heading 标题\n\nBody with a final line.\n\n最后一行必须完整显示。",
            "### Heading 标题\n\nBody with a final line.",
            "Plain 中文 paragraph with emoji 👩🏽‍💻 and a final line.",
            "1. First 中文 item\n2. Second item",
            "> Quoted 中文 paragraph\n\nFinal line.",
            "```swift\nlet value = 1\n```\n\nFinal line.",
        ]
        for pointSize in [11.2, 14, 16.1, 21] {
            let font = NSFont.systemFont(ofSize: pointSize)
            for width in [240.0, 420, 594, 826] {
                for (sampleIndex, sample) in samples.enumerated() {
                    let document = MacConversationTextDocument()
                    let target = MacConversationTextDocument.Source(id: 2, text: sample, isUser: false)
                    let before = MacConversationTextDocument.Source(id: 1, text: "Earlier message.", isUser: true)
                    let after = MacConversationTextDocument.Source(id: 3, text: "Later message.", isUser: true)
                    // Reuse the same block and measurement through append,
                    // prepend, tail removal and leading-history eviction.
                    let windows = [[target], [target, after], [before, target, after], [before, target], [target]]
                    for (step, sources) in windows.enumerated() {
                        document.update(identity: ObjectIdentifier(document), sources: sources,
                                        style: .init(font: font, foreground: .labelColor, userForeground: .labelColor)) {
                            render($0, font: font)
                        }
                        guard let text = document.text(for: 2), let view = document.textView(for: 2),
                              let container = view.textContainer, let ownRange = document.range(for: 2),
                              let measurement = document.measurement(for: 2) else {
                            failures.append("paragraph fixture lost its native text network")
                            continue
                        }
                        let measured = measurement.size(for: text, font: font, width: width,
                                                        hasPrecedingBlock: document.hasPrecedingBlock(2),
                                                        hasFollowingBlock: document.hasFollowingBlock(2))
                        view.textContainerInset = .zero
                        view.isVerticallyResizable = false
                        view.isHorizontallyResizable = false
                        view.frame = NSRect(origin: .zero, size: measured)
                        document.layout.ensureLayout(for: container)
                        let drawn = document.layout.usedRect(for: container).maxY
                        let covered = document.layout.characterRange(
                            forGlyphRange: document.layout.glyphRange(for: container), actualGlyphRange: nil)
                        let tag = "sample \(sampleIndex) step \(step) font \(pointSize) width \(width)"
                        if measured.height != ceil(drawn) {
                            failures.append("\(tag): drawn \(drawn) vs row \(measured.height)")
                        }
                        if covered.location > ownRange.location || NSMaxRange(covered) < NSMaxRange(ownRange) {
                            failures.append("\(tag): container omits message characters")
                        }
                    }
                }
            }
        }
    }

    @MainActor static func checkImageSeparators() {
        let five = (1...5).map { "**Candidate \($0)**\n\n![Image \($0)](/tmp/candidate-\($0).png)\n\nFollowing prose." }.joined(separator: "\n\n")
        let samples: [(String, Int)] = [
            (five, 5),
            ("Before\n\n![One](/tmp/repeated.png)\n\n![Two](/tmp/repeated.png)\n\nAfter", 2),
            ("Before\n\n![ ](/tmp/spaces.png)\n\nAfter", 1),
        ]
        for (source, expected) in samples {
            let text = ChatMarkdown.attributed(source)
            let images = text.runs.filter { $0.imageURL != nil }
            if images.count != expected {
                failures.append("image separators: expected \(expected) declarations, got \(images.count) image runs")
            }
            for run in images where String(text[run.range].characters).contains("\n") {
                failures.append("structural newline inherited imageURL")
            }
        }
    }

    struct Line {
        var text: String
        var x: CGFloat
        var y: CGFloat
        var height: CGFloat
    }

    @MainActor static func lineFragments(layout: NSLayoutManager, container: NSTextContainer,
                                         storage: NSString) -> [Line] {
        var lines: [Line] = []
        let glyphs = layout.glyphRange(for: container)
        var glyph = glyphs.location
        while glyph < NSMaxRange(glyphs) {
            var used = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &used)
            let characters = layout.characterRange(forGlyphRange: used, actualGlyphRange: nil)
            let x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
            lines.append(Line(text: storage.substring(with: characters), x: x, y: rect.minY, height: rect.height))
            glyph = NSMaxRange(used)
            if lines.count > 200 { break }
        }
        return lines
    }

    @MainActor static func check(source: MacConversationTextDocument.Source, lines rawLines: [Line],
                                 drawnHeight: CGFloat, measuredHeight: CGFloat) {
        let tag = "message \(source.id)"
        // The document gives each container a near-zero paragraph start after
        // the previous message's separator; it is not part of the message.
        var lines = rawLines
        if let first = lines.first, first.text == "\n", first.y < 1 {
            if first.height > 0.5 {
                failures.append("\(tag): paragraph-start line occupies \(first.height) pt")
            }
            lines.removeFirst()
        }
        guard let first = lines.first else {
            failures.append("\(tag): no drawn lines")
            return
        }
        if source.id == 2 || source.id == 3 {
            let marker = source.id == 2 ? "1.\t" : "•\t"
            if !first.text.hasPrefix(marker) || first.text.count <= marker.count {
                failures.append("\(tag): first line must contain \(marker.debugDescription) and its item text, got \(first.text.debugDescription)")
            }
            if abs(first.x) > 0.5 {
                failures.append("\(tag): list marker starts at x=\(first.x), expected 0")
            }
            for line in lines where line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || line.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1."
                || line.text.trimmingCharacters(in: .whitespacesAndNewlines) == "•"
                || line.text == "\t" {
                failures.append("\(tag): stray marker/tab line at y=\(line.y): \(line.text.debugDescription)")
            }
        } else {
            if !first.text.hasPrefix("上一条消息") || abs(first.x) > 0.5 {
                failures.append("\(tag): plain paragraph start changed: x=\(first.x) \(first.text.debugDescription)")
            }
        }
        if measuredHeight >= 0, measuredHeight != ceil(drawnHeight) {
            failures.append("\(tag): drawn height \(drawnHeight) differs from detached measurement \(measuredHeight)")
        }
    }
}
