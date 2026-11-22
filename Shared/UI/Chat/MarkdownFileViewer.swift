import QuickLook
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Full-screen Markdown document reader supporting multi-layer navigation
/// inside a single `NavigationStack`, in-viewer Quick Look for non-Markdown
/// linked files, Rendered/Source switching, outline & line/anchor jumping, and
/// external URL opening.
struct MarkdownFileViewer: View {
    let presentation: ChatFileLoader.MarkdownPresentation
    let hostID: String
    var loader: ChatFileLoader? = nil
    var onRetry: () -> Void
    var onDismiss: () -> Void
    var onSystemPreview: ((URL) -> Void)? = nil
    var onOpenLocalLink: (([String], ChatFileLink) -> ChatFileLoader.MarkdownPresentation?)? = nil

    @State private var localStack: [ChatFileLoader.MarkdownPresentation] = []
    @State private var localQuickLookURL: URL?

    private var pushedIDsBinding: Binding<[UUID]> {
        if let loader {
            return Binding(
                get: { loader.pushedMarkdownIDs },
                set: { loader.pushedMarkdownIDs = $0 }
            )
        }
        return Binding(
            get: { localStack.map(\.id) },
            set: { newIDs in
                let remaining = Set(newIDs)
                localStack = newIDs.compactMap { id in
                    localStack.first(where: { $0.id == id && remaining.contains($0.id) })
                }
            }
        )
    }

    private var quickLookBinding: Binding<URL?> {
        if let loader {
            return Binding(
                get: { loader.viewerQuickLookURL },
                set: { loader.viewerQuickLookURL = $0 }
            )
        }
        return $localQuickLookURL
    }

    private func layerPresentation(for layerID: UUID) -> ChatFileLoader.MarkdownPresentation? {
        if let loader {
            return loader.presentation(for: layerID)
        }
        if presentation.id == layerID {
            return presentation
        }
        return localStack.first(where: { $0.id == layerID })
    }

    private func openNestedLink(from layer: ChatFileLoader.MarkdownPresentation, link: ChatFileLink) {
        if let loader {
            loader.openFromViewer(seq: layer.seq, via: layer.childVia, link: link)
            return
        }
        if let onOpenLocalLink, let next = onOpenLocalLink(layer.childVia, link) {
            if case .loaded(let file) = next.phase, !file.isMarkdown {
                localQuickLookURL = file.localURL
            } else {
                localStack.append(next)
            }
        }
    }

    private func handleSystemPreview(_ url: URL) {
        if let loader {
            loader.viewerQuickLookURL = url
        } else if onOpenLocalLink != nil {
            localQuickLookURL = url
        } else if let onSystemPreview {
            onDismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onSystemPreview(url)
            }
        } else {
            localQuickLookURL = url
        }
    }

    var body: some View {
        let rootLayer = loader?.markdownPresentation ?? presentation
        NavigationStack(path: pushedIDsBinding) {
            pageView(for: rootLayer, isRoot: true)
                .navigationDestination(for: UUID.self) { layerID in
                    if let layer = layerPresentation(for: layerID) {
                        pageView(for: layer, isRoot: false)
                    } else {
                        ContentUnavailableView(
                            "chat.file.unavailable.title",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
        }
        .quickLookPreview(quickLookBinding)
        #if os(iOS)
        .overlay {
            if let download = loader?.nonMarkdownDownload, download.error == nil {
                inViewerDownloadOverlay(download)
            }
        }
        .alert(
            "chat.file.unavailable.title",
            isPresented: Binding(
                get: { loader?.nonMarkdownDownload?.error != nil },
                set: { if !$0 { loader?.dismissNonMarkdown() } }
            )
        ) {
            Button("action.retry") { loader?.retryNonMarkdown() }
            Button("action.cancel", role: .cancel) { loader?.dismissNonMarkdown() }
        } message: {
            Text(verbatim: loader?.nonMarkdownDownload?.error ?? "")
        }
        #endif
    }

    @ViewBuilder
    private func pageView(
        for layer: ChatFileLoader.MarkdownPresentation,
        isRoot: Bool
    ) -> some View {
        MarkdownFilePageView(
            presentation: layer,
            hostID: hostID,
            canOpenNestedFiles: loader != nil || onOpenLocalLink != nil,
            onRetry: {
                if let loader {
                    loader.retryMarkdown(layerID: layer.id)
                } else if isRoot {
                    onRetry()
                }
            },
            onDismiss: onDismiss,
            onSystemPreview: handleSystemPreview,
            onOpenNestedLink: { link in
                openNestedLink(from: layer, link: link)
            }
        )
    }

    private func inViewerDownloadOverlay(_ download: ChatFileLoader.NonMarkdownDownload) -> some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                if let progress = download.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                } else {
                    ProgressView()
                }
                Text("chat.file.loading_named \(download.link.displayName)")
                    .interfaceFont(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("action.cancel") {
                    loader?.dismissNonMarkdown()
                }
                .interfaceFont(.footnote.weight(.medium))
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.md)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(Space.base)
    }
}

// MARK: - Single Document Layer Page

private struct MarkdownFilePageView: View {
    struct ScrollTarget: Equatable {
        let id = UUID()
        let blockID: Int
        let anchor: UnitPoint
        let highlight: Bool
    }

    let presentation: ChatFileLoader.MarkdownPresentation
    let hostID: String
    let canOpenNestedFiles: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void
    let onSystemPreview: ((URL) -> Void)?
    let onOpenNestedLink: (ChatFileLink) -> Void

    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var viewMode: ViewMode = .rendered
    @State private var document: MarkdownDocument?
    @State private var rawSource: String?
    @State private var isDecoding = false
    @State private var showDecodingSpinner = false
    @State private var nonUTF8 = false
    @State private var noticeMessage: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var pendingScrollTarget: ScrollTarget?
    @State private var highlightedBlockID: Int?
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var appliedInitialTarget = false

    private enum ViewMode: Hashable {
        case rendered
        case source
    }

    private var loadedFile: LoadedChatFile? {
        if case .loaded(let file) = presentation.phase { return file }
        return nil
    }

    private static var canvasBackground: Color {
        #if canImport(UIKit)
        Color(.systemBackground)
        #else
        Color(.textBackgroundColor)
        #endif
    }

    private static var surfaceBackground: Color {
        #if canImport(UIKit)
        Color(.secondarySystemBackground)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    private static var surfaceHeaderBackground: Color {
        #if canImport(UIKit)
        Color(.tertiarySystemBackground)
        #else
        Color(.tertiarySystemGroupedBackground)
        #endif
    }

    var body: some View {
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
        .background(Self.canvasBackground)
        .navigationTitle(loadedFile?.name ?? presentation.link.displayName)
        .inlineNavigationTitle()
        .toolbar { toolbarContent }
        .task(id: loadedFile?.id) {
            await prepareDocument()
        }
        .onDisappear {
            noticeTask?.cancel()
            highlightClearTask?.cancel()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let file = loadedFile {
            ToolbarItemGroup(placement: .corralTrailing) {
                if !nonUTF8 && !(document?.truncatedToSource ?? false) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            viewMode = (viewMode == .rendered) ? .source : .rendered
                        }
                    } label: {
                        Label(
                            viewMode == .rendered ? "chat.file.switch_to_source" : "chat.file.switch_to_rendered",
                            systemImage: viewMode == .rendered ? "chevron.left.forwardslash.chevron.right" : "doc.richtext"
                        )
                    }
                    .labelStyle(.iconOnly)
                }

                Menu {
                    if !nonUTF8 && !(document?.truncatedToSource ?? false) {
                        Picker("", selection: $viewMode) {
                            Label("chat.file.view.rendered", systemImage: "doc.richtext").tag(ViewMode.rendered)
                            Label("chat.file.view.source", systemImage: "chevron.left.forwardslash.chevron.right").tag(ViewMode.source)
                        }
                    }
                    ShareLink(item: file.localURL) {
                        Label("action.share", systemImage: "square.and.arrow.up")
                    }
                    if let rawSource {
                        Button {
                            PlatformPasteboard.copy(rawSource)
                            showNotice(String(localized: "chat.file.copied"))
                        } label: {
                            Label("chat.file.copy_markdown", systemImage: "doc.on.doc")
                        }
                    }
                    Button {
                        PlatformPasteboard.copy(file.displayPath)
                        showNotice(String(localized: "chat.file.copied_path"))
                    } label: {
                        Label("chat.file.copy_path", systemImage: "link")
                    }
                    if let onSystemPreview {
                        Button {
                            onSystemPreview(file.localURL)
                        } label: {
                            Label("chat.file.system_preview", systemImage: "eye")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Text("action.more"))
            }

            if #available(iOS 26.0, macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .corralTrailing)
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
                .truncationMode(.middle)
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
        ZStack(alignment: .top) {
            if isDecoding {
                if showDecodingSpinner {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Self.canvasBackground.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
                MarkdownSourceScrollView(
                    source: rawSource,
                    targetLine: file.targetLine,
                    header: { documentMetadataHeader(file: file, showOutline: false) },
                    truncatedNotice: document?.truncatedToSource == true
                        ? String(localized: "chat.file.large_source_notice")
                        : nil,
                    canvasBackground: Self.canvasBackground
                )
            } else if let document {
                MarkdownRenderedScrollView(
                    document: document,
                    hostID: hostID,
                    colorScheme: colorScheme,
                    canvasBackground: Self.canvasBackground,
                    surfaceBackground: Self.surfaceBackground,
                    surfaceHeaderBackground: Self.surfaceHeaderBackground,
                    scrollTarget: pendingScrollTarget,
                    highlightedBlockID: highlightedBlockID,
                    header: { documentMetadataHeader(file: file, showOutline: true) },
                    linkHandler: { url in
                        handleInDocumentLink(url)
                    }
                )
            }

            if let noticeMessage {
                noticeBanner(message: noticeMessage)
                    .padding(.top, Space.sm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func documentMetadataHeader(file: LoadedChatFile, showOutline: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
            Button {
                PlatformPasteboard.copy(file.displayPath)
                showNotice(String(localized: "chat.file.copied_path"))
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "folder")
                        .interfaceFont(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: file.displayPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: Space.sm * interfaceScale) {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .interfaceFont(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                if !presentation.via.isEmpty {
                    Label {
                        Text(verbatim: "\(presentation.via.count + 1)")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "arrow.turn.down.right")
                    }
                    .interfaceFont(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Self.surfaceBackground, in: Capsule())
                }

                if let line = file.targetLine {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            viewMode = (viewMode == .source) ? .rendered : .source
                        }
                    } label: {
                        Text("chat.file.line_badge \(line)")
                            .interfaceFont(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                if showOutline,
                   let document,
                   document.headings.count >= 2,
                   !document.truncatedToSource {
                    Menu {
                        ForEach(document.headings) { item in
                            Button {
                                triggerScroll(blockID: item.id, anchor: .top, highlight: true)
                            } label: {
                                Text(verbatim: String(repeating: "  ", count: max(0, item.level - 1)) + item.title)
                            }
                        }
                    } label: {
                        Label("chat.file.outline", systemImage: "list.bullet.indent")
                            .interfaceFont(.caption.weight(.medium))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Palette.accent.opacity(0.10), in: Capsule())
                    }
                }
            }

            Divider()
                .opacity(0.6)
                .padding(.top, Space.xs)
        }
        .padding(.bottom, Space.xs)
    }

    private func noticeBanner(message: String) -> some View {
        HStack(spacing: Space.xs * interfaceScale) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.accent)
            Text(verbatim: message)
                .interfaceFont(.footnote.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    // MARK: - Helpers

    private func prepareDocument() async {
        guard let file = loadedFile else {
            document = nil
            rawSource = nil
            nonUTF8 = false
            appliedInitialTarget = false
            return
        }
        isDecoding = true
        showDecodingSpinner = false
        let spinnerTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if isDecoding {
                showDecodingSpinner = true
            }
        }
        let fileURL = file.localURL
        let parsed: (String?, MarkdownDocument?) = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                return (nil, nil)
            }
            return (text, MarkdownDocument.parse(text))
        }.value
        spinnerTask.cancel()

        isDecoding = false
        showDecodingSpinner = false
        if let text = parsed.0, let doc = parsed.1 {
            rawSource = text
            document = doc
            nonUTF8 = false
            if file.targetLine != nil && viewMode == .rendered && doc.truncatedToSource {
                viewMode = .source
            } else if !appliedInitialTarget {
                appliedInitialTarget = true
                if let line = file.targetLine, let blockID = doc.blockID(forLine: line) {
                    triggerScroll(blockID: blockID, anchor: .center, highlight: true)
                } else if let anchor = file.targetAnchor, let blockID = doc.blockID(forAnchor: anchor) {
                    triggerScroll(blockID: blockID, anchor: .top, highlight: true)
                }
            }
        } else {
            rawSource = nil
            document = nil
            nonUTF8 = true
        }
    }

    private func triggerScroll(blockID: Int, anchor: UnitPoint, highlight: Bool) {
        pendingScrollTarget = ScrollTarget(blockID: blockID, anchor: anchor, highlight: highlight)
        if highlight {
            highlightClearTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) {
                highlightedBlockID = blockID
            }
            highlightClearTask = Task {
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    highlightedBlockID = nil
                }
            }
        }
    }

    /// Routes in-document links:
    /// - `#anchor` scrolls to matching heading in the same document
    /// - host file links (`file://` or relative/absolute paths) push/preview via `media.file`
    /// - external URLs (`http(s)` / `mailto:`) open via system handler.
    private func handleInDocumentLink(_ url: URL) -> (() -> Void)? {
        let raw = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#"), let doc = document {
            let fragment = String(raw.dropFirst())
            if let blockID = doc.blockID(forAnchor: fragment) {
                return { [self] in
                    triggerScroll(blockID: blockID, anchor: .top, highlight: true)
                }
            }
            return {}
        }

        if let link = ChatFileLink.classify(url) {
            if canOpenNestedFiles {
                return { [self] in
                    onOpenNestedLink(link)
                }
            }
            return { [self] in
                showNotice(String(localized: "chat.file.secondary_link_unsupported"))
            }
        }

        if let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            return {
                openURL(url)
            }
        }
        return {}
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            noticeMessage = message
        }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                noticeMessage = nil
            }
        }
    }
}

// MARK: - Rendered Markdown View

private struct MarkdownRenderedScrollView<Header: View>: View {
    let document: MarkdownDocument
    let hostID: String
    let colorScheme: ColorScheme
    let canvasBackground: Color
    let surfaceBackground: Color
    let surfaceHeaderBackground: Color
    let scrollTarget: MarkdownFilePageView.ScrollTarget?
    let highlightedBlockID: Int?
    @ViewBuilder let header: () -> Header
    let linkHandler: (URL) -> (() -> Void)?

    @Environment(\.interfaceScale) private var interfaceScale

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.md * interfaceScale) {
                    header()

                    ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                        blockRow(block, isFirst: index == 0)
                            .id(block.id)
                    }
                }
                .padding(.horizontal, Space.base)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(canvasBackground)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target.blockID, anchor: target.anchor)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func blockRow(_ block: MarkdownDocument.Block, isFirst: Bool) -> some View {
        let isHighlighted = highlightedBlockID == block.id
        blockView(block, isFirst: isFirst)
            .overlay(alignment: .leading) {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Palette.accent)
                        .frame(width: 3)
                        .offset(x: -Space.sm)
                }
            }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(_, let level, let text):
            let scale: CGFloat = switch level {
            case 1: 1.44
            case 2: 1.24
            case 3: 1.12
            default: 1.04
            }
            VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                SelectableAttributedText(
                    attributed: ChatMarkdown.styledInline(text, scale: scale, baseWeight: .semibold),
                    foreground: .primary,
                    tint: Palette.accent,
                    fontStyle: .bubbleBody,
                    maxHeight: nil,
                    linkHandler: linkHandler
                )
                if level == 1 {
                    Divider().opacity(0.45)
                }
            }
            .padding(.top, isFirst ? 0 : (level <= 2 ? Space.md : Space.xs))

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
            VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
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
                    colorScheme: colorScheme,
                    surfaceBackground: surfaceBackground,
                    surfaceHeaderBackground: surfaceHeaderBackground
                )
            } else {
                MarkdownCodeBlockView(
                    language: language,
                    code: code,
                    surfaceBackground: surfaceBackground,
                    surfaceHeaderBackground: surfaceHeaderBackground
                )
            }

        case .blockQuote(_, let text):
            HStack(alignment: .top, spacing: Space.sm * interfaceScale) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Palette.accent.opacity(0.7))
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
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                surfaceBackground.opacity(0.75),
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )

        case .table(_, let alignments, let headers, let rows):
            MarkdownGridTableView(
                alignments: alignments,
                headers: headers,
                rows: rows,
                surfaceBackground: surfaceBackground,
                surfaceHeaderBackground: surfaceHeaderBackground,
                linkHandler: linkHandler
            )

        case .thematicBreak:
            Divider()
                .opacity(0.7)
                .padding(.vertical, Space.xs)
        }
    }

    @ViewBuilder
    private func listMarker(for item: MarkdownDocument.ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .sessionFont(.bubbleBody)
                .foregroundStyle(checked ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
        } else if item.ordered {
            Text(verbatim: "\(item.ordinal).")
                .sessionFont(.bubbleBody)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text(verbatim: "•")
                .sessionFont(.bubbleBody)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    let surfaceBackground: Color
    let surfaceHeaderBackground: Color

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
                    .interfaceFont(.caption.weight(.medium))
                    .foregroundStyle(copied ? Palette.accent : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(surfaceHeaderBackground)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func copy() {
        PlatformPasteboard.copy(code)
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
    let surfaceBackground: Color
    let surfaceHeaderBackground: Color

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
                        .background(
                            surfaceBackground,
                            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                MarkdownCodeBlockView(
                    language: language,
                    code: code,
                    surfaceBackground: surfaceBackground,
                    surfaceHeaderBackground: surfaceHeaderBackground
                )
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
    let surfaceBackground: Color
    let surfaceHeaderBackground: Color
    let linkHandler: (URL) -> (() -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { col, cell in
                        cellView(cell, column: col, isHeader: true)
                    }
                }
                .background(surfaceHeaderBackground)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().opacity(0.5)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                            cellView(cell, column: col, isHeader: false)
                        }
                    }
                }
            }
            .background(surfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
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

private struct MarkdownSourceScrollView<Header: View>: View {
    let source: String
    let targetLine: Int?
    @ViewBuilder let header: () -> Header
    let truncatedNotice: String?
    let canvasBackground: Color

    private var lines: [String] {
        source.components(separatedBy: .newlines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    header()
                        .padding(.horizontal, Space.base)

                    if let truncatedNotice {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Palette.accent)
                            Text(verbatim: truncatedNotice)
                                .interfaceFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Space.base)
                        .padding(.bottom, Space.sm)
                    }

                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let lineNumber = index + 1
                        let isHighlighted = targetLine == lineNumber
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(verbatim: "\(lineNumber)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(isHighlighted ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                                .monospacedDigit()
                                .frame(minWidth: 34, alignment: .trailing)
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
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xl)
            }
            .background(canvasBackground)
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
