import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Full-screen Markdown document reader presented when tapping a `.md` link
/// in chat. Supports loading progress, Rendered/Source switching, ShareLink,
/// external link opening, and Mermaid/PlantUML diagram rendering without
/// triggering secondary host-file jumps.
struct MarkdownFileViewer: View {
    let presentation: ChatFileLoader.MarkdownPresentation
    let hostID: String
    let onRetry: () -> Void
    let onDismiss: () -> Void
    var onSystemPreview: ((URL) -> Void)? = nil

    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var viewMode: ViewMode = .rendered
    @State private var document: MarkdownDocument?
    @State private var rawSource: String?
    @State private var isDecoding = false
    @State private var nonUTF8 = false
    @State private var noticeMessage: String?
    @State private var noticeTask: Task<Void, Never>?

    private enum ViewMode: Hashable {
        case rendered
        case source
    }

    private var loadedFile: LoadedChatFile? {
        if case .loaded(let file) = presentation.phase { return file }
        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                switch presentation.phase {
                case .loading(let progress):
                    loadingView(progress: progress)
                case .failed(let message):
                    errorView(message: message)
                case .loaded(let file):
                    loadedContent(file: file)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(loadedFile?.name ?? presentation.link.displayName)
            .inlineNavigationTitle()
            .toolbar { toolbarContent }
        }
        .task(id: loadedFile?.id) {
            await prepareDocument()
        }
        .onDisappear {
            noticeTask?.cancel()
        }
    }

    // MARK: - Toolbar

    private static var leadingPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let file = loadedFile {
            ToolbarItem(placement: Self.leadingPlacement) {
                Menu {
                    ShareLink(item: file.localURL) {
                        Label("action.share", systemImage: "square.and.arrow.up")
                    }
                    if let rawSource {
                        Button {
                            copyToPasteboard(rawSource)
                        } label: {
                            Label("chat.file.copy_markdown", systemImage: "doc.on.doc")
                        }
                    }
                    Button {
                        copyToPasteboard(file.displayPath)
                    } label: {
                        Label("chat.file.copy_path", systemImage: "link")
                    }
                    if let onSystemPreview {
                        Button {
                            onDismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                onSystemPreview(file.localURL)
                            }
                        } label: {
                            Label("chat.file.system_preview", systemImage: "eye")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        if loadedFile != nil, !nonUTF8, !(document?.truncatedToSource ?? false) {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $viewMode) {
                    Text("chat.file.view.rendered").tag(ViewMode.rendered)
                    Text("chat.file.view.source").tag(ViewMode.source)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        ToolbarItem(placement: .corralTrailing) {
            if #available(iOS 26.0, macOS 26.0, *) {
                Button(role: .close) {
                    onDismiss()
                }
            } else {
                Button("action.dismiss", systemImage: "xmark") {
                    onDismiss()
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    // MARK: - States

    private func loadingView(progress: Double?) -> some View {
        VStack(spacing: Space.base * interfaceScale) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
            } else {
                ProgressView()
            }
            Text("chat.file.loading")
                .interfaceFont(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: presentation.link.displayName)
                .interfaceFont(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        ContentUnavailableView {
            Label("chat.file.unavailable.title", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(verbatim: message)
        } actions: {
            Button("action.retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func loadedContent(file: LoadedChatFile) -> some View {
        VStack(spacing: 0) {
            fileHeaderStrip(file: file)
            if let noticeMessage {
                noticeBanner(message: noticeMessage)
            }
            if isDecoding {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if nonUTF8 {
                ContentUnavailableView {
                    Label("chat.file.unavailable.title", systemImage: "doc")
                } description: {
                    Text(verbatim: file.mime)
                } actions: {
                    ShareLink(item: file.localURL) {
                        Label("action.share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .source || document?.truncatedToSource == true, let rawSource {
                if document?.truncatedToSource == true {
                    noticeBanner(message: String(localized: "chat.file.large_source_notice"))
                }
                MarkdownSourceScrollView(source: rawSource, targetLine: file.targetLine)
            } else if let document {
                MarkdownRenderedScrollView(
                    document: document,
                    hostID: hostID,
                    colorScheme: colorScheme,
                    linkHandler: { url in
                        handleInDocumentLink(url)
                    }
                )
            }
        }
    }

    private func fileHeaderStrip(file: LoadedChatFile) -> some View {
        HStack(spacing: Space.sm * interfaceScale) {
            Text(verbatim: file.displayPath)
                .interfaceFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.xs)
            if let line = file.targetLine {
                Text("chat.file.line_badge \(line)")
                    .interfaceFont(.caption2.weight(.medium))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.accent.opacity(0.12), in: Capsule())
            }
            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                .interfaceFont(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.xs)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func noticeBanner(message: String) -> some View {
        HStack(spacing: Space.xs * interfaceScale) {
            Image(systemName: "info.circle")
                .foregroundStyle(Palette.accent)
            Text(verbatim: message)
                .interfaceFont(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.sm)
        .background(Color(.tertiarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Helpers

    private func prepareDocument() async {
        guard let file = loadedFile else {
            document = nil
            rawSource = nil
            nonUTF8 = false
            return
        }
        isDecoding = true
        let fileURL = file.localURL
        let parsed: (String?, MarkdownDocument?) = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                return (nil, nil)
            }
            return (text, MarkdownDocument.parse(text))
        }.value

        isDecoding = false
        if let text = parsed.0, let doc = parsed.1 {
            rawSource = text
            document = doc
            nonUTF8 = false
            if file.targetLine != nil && viewMode == .rendered && doc.truncatedToSource {
                viewMode = .source
            }
        } else {
            rawSource = nil
            document = nil
            nonUTF8 = true
        }
    }

    /// External links (`http(s)` / `mailto:`) open via the system handler;
    /// local/relative file links do not trigger secondary remote downloads.
    private func handleInDocumentLink(_ url: URL) -> (() -> Void)? {
        if ChatFileLink.classify(url) != nil {
            return { [self] in
                showNotice(String(localized: "chat.file.secondary_link_unsupported"))
            }
        }
        // Only intercept explicit external URLs via `openURL` so everything else
        // (`#anchor` etc.) is safely contained.
        if let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            return {
                openURL(url)
            }
        }
        return {}
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        noticeMessage = message
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            noticeMessage = nil
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Rendered Markdown View

private struct MarkdownRenderedScrollView: View {
    let document: MarkdownDocument
    let hostID: String
    let colorScheme: ColorScheme
    let linkHandler: (URL) -> (() -> Void)?

    @Environment(\.interfaceScale) private var interfaceScale

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.md * interfaceScale) {
                ForEach(document.blocks) { block in
                    blockView(block)
                }
            }
            .padding(.horizontal, Space.base)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(_, let level, let text):
            let scale: CGFloat = switch level {
            case 1: 1.42
            case 2: 1.26
            case 3: 1.14
            default: 1.05
            }
            SelectableAttributedText(
                attributed: ChatMarkdown.styledInline(text, scale: scale, baseWeight: .semibold),
                foreground: .primary,
                tint: Palette.accent,
                fontStyle: .bubbleBody,
                maxHeight: nil,
                linkHandler: linkHandler
            )
            .padding(.top, level <= 2 ? Space.sm : Space.xs)

        case .paragraph(_, let text):
            SelectableAttributedText(
                attributed: ChatMarkdown.styledInline(text),
                foreground: .primary,
                tint: Palette.accent,
                fontStyle: .bubbleBody,
                maxHeight: nil,
                linkHandler: linkHandler
            )

        case .list(_, let items):
            VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm * interfaceScale) {
                        listMarker(for: item)
                        SelectableAttributedText(
                            attributed: ChatMarkdown.styledInline(item.text),
                            foreground: .primary,
                            tint: Palette.accent,
                            fontStyle: .bubbleBody,
                            maxHeight: nil,
                            linkHandler: linkHandler
                        )
                    }
                    .padding(.leading, CGFloat(item.depth) * 18 * interfaceScale)
                }
            }

        case .codeBlock(_, let language, let code, let diagram):
            if let diagram {
                MarkdownDiagramBlockView(
                    hostID: hostID,
                    diagram: diagram,
                    language: language,
                    code: code,
                    colorScheme: colorScheme
                )
            } else {
                MarkdownCodeBlockView(language: language, code: code)
            }

        case .blockQuote(_, let text):
            HStack(alignment: .top, spacing: Space.sm * interfaceScale) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.accent.opacity(0.65))
                    .frame(width: 3)
                SelectableAttributedText(
                    attributed: ChatMarkdown.styledInline(text),
                    foreground: .secondary,
                    tint: Palette.accent,
                    fontStyle: .bubbleBody,
                    maxHeight: nil,
                    linkHandler: linkHandler
                )
            }
            .padding(.vertical, Space.xs)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.sm))

        case .table(_, let alignments, let headers, let rows):
            MarkdownGridTableView(
                alignments: alignments,
                headers: headers,
                rows: rows,
                linkHandler: linkHandler
            )

        case .thematicBreak:
            Divider()
                .padding(.vertical, Space.xs)
        }
    }

    @ViewBuilder
    private func listMarker(for item: MarkdownDocument.ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .interfaceFont(.footnote)
                .foregroundStyle(checked ? Palette.accent : .secondary)
        } else if item.ordered {
            Text(verbatim: "\(item.ordinal).")
                .interfaceFont(.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text(verbatim: "•")
                .interfaceFont(.body.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language?.isEmpty == false ? language! : "code")
                    .interfaceFont(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.lowercase)
                Spacer(minLength: 0)
                Button {
                    copy()
                } label: {
                    Label(
                        copied ? "chat.file.copied" : "chat.file.copy_code",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .interfaceFont(.caption)
                    .foregroundStyle(copied ? Palette.accent : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .background(Color(.tertiarySystemGroupedBackground))

            Divider()

            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.5)
        )
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private struct MarkdownDiagramBlockView: View {
    let hostID: String
    let diagram: ChatDiagramBlock
    let language: String?
    let code: String
    let colorScheme: ColorScheme

    @State private var drawing: ChatDiagramDrawing?
    @State private var inspection: ChatDiagramInspection?

    var body: some View {
        Group {
            if let drawing {
                Button {
                    inspection = ChatDiagramInspection(drawing: drawing, source: code)
                } label: {
                    Image(platformImage: drawing.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .padding(Space.sm)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.md))
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                MarkdownCodeBlockView(language: language, code: code)
            }
        }
        .task(id: "\(hostID)|\(colorScheme)|\(code)") {
            ChatDiagramRenderer.shared.allow(host: hostID)
            drawing = await ChatDiagramRenderer.shared.render(
                host: hostID,
                block: diagram,
                dark: colorScheme == .dark
            )
        }
        .sheet(item: $inspection) { item in
            ChatDiagramViewer(inspection: item)
        }
    }
}

private struct MarkdownGridTableView: View {
    let alignments: [PresentationIntent.TableColumn.Alignment]
    let headers: [AttributedString]
    let rows: [[AttributedString]]
    let linkHandler: (URL) -> (() -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { col, cell in
                        cellView(cell, column: col, isHeader: true)
                    }
                }
                .background(Color(.tertiarySystemGroupedBackground))

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                            cellView(cell, column: col, isHeader: false)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.32), lineWidth: 0.5)
            )
        }
    }

    private func cellView(_ text: AttributedString, column: Int, isHeader: Bool) -> some View {
        let styled = ChatMarkdown.styledInline(
            text,
            scale: 0.92,
            baseWeight: isHeader ? .semibold : .regular
        )
        return SelectableAttributedText(
            attributed: styled,
            foreground: .primary,
            tint: Palette.accent,
            fontStyle: .bubbleBody,
            maxHeight: nil,
            linkHandler: linkHandler
        )
        .frame(minWidth: 96, maxWidth: 260, alignment: alignment(for: column))
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private func alignment(for column: Int) -> Alignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }
}

// MARK: - Source View

private struct MarkdownSourceScrollView: View {
    let source: String
    let targetLine: Int?

    private var lines: [String] {
        source.components(separatedBy: .newlines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let lineNumber = index + 1
                        let isHighlighted = targetLine == lineNumber
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(verbatim: "\(lineNumber)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(isHighlighted ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                                .monospacedDigit()
                                .frame(minWidth: 32, alignment: .trailing)
                            Text(verbatim: line.isEmpty ? " " : line)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(isHighlighted ? Palette.accent.opacity(0.14) : Color.clear)
                        .id(lineNumber)
                    }
                }
                .padding(.vertical, Space.sm)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                if let targetLine, targetLine > 0, targetLine <= lines.count {
                    DispatchQueue.main.async {
                        proxy.scrollTo(targetLine, anchor: .center)
                    }
                }
            }
        }
    }
}
