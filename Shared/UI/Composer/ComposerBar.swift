import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct DraftImageAttachment: Identifiable, Equatable {
    let id: UUID
    let base64: String
    let preview: PlatformImage
    /// Retained after an ambiguous delivery so an explicit retry is idempotent.
    var commandID: String? = nil

    static func == (lhs: DraftImageAttachment, rhs: DraftImageAttachment) -> Bool {
        lhs.id == rhs.id && lhs.base64 == rhs.base64 && lhs.commandID == rhs.commandID
    }
}

struct DraftFileAttachment: Identifiable, Equatable {
    let id: UUID
    let name: String
    let data: Data
    var commandID: String? = nil

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

struct ComposerBar: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.sessionTextScale) private var sessionTextScale
    @Binding var text: String
    @Binding var attachments: [DraftImageAttachment]
    @Binding var fileAttachments: [DraftFileAttachment]
    var isBusy = false
    /// When true, focus the field once after appear (new-session path only).
    var autoFocus = false
    /// Non-zero moves the caret into the field, on mount and on every change
    /// (a Mac pane was selected); zero leaves focus alone.
    var focusRequest = 0
    /// Reports the field gaining or losing keyboard focus.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// This session's own prompts, oldest first, recalled with Up / Down.
    var history: [String] = []
    /// Set while the assistant runs and the host can interrupt it; an empty
    /// composer then shows stop in place of send.
    var onStop: (() -> Void)? = nil
    /// The interrupt is in flight: stop stays, quiet and disabled.
    var isStopping = false
    #if DEBUG
    /// Isolated native-editing regression trigger; never exposed by production UI.
    var inspectionSubmitRequest = 0
    #endif
    var showsFollowUpContextAction = false
    var onSend: (_ text: String, _ images: [DraftImageAttachment], _ files: [DraftFileAttachment]) -> Void
    var onFollowUp: ((_ text: String, _ images: [DraftImageAttachment], _ files: [DraftFileAttachment]) -> Void)? = nil
    var onRecallQueued: (() -> Bool)? = nil

    @FocusState private var focused: Bool
    @State private var showFileImporter = false
    @State private var didAutoFocus = false
    @State private var macFocusTrigger = 0
    @State private var recall = ComposerHistory()
    @State private var quickLookURL: URL?
    @State private var openingImageID: UUID?
    @State private var previewFailed = false
    @State private var attachmentError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.composerRecedes) private var recedes

    private static let maxAttachments = ComposerSendPolicy.maxAttachments
    private static let maxImageBytes = 8 * 1024 * 1024
    private static let standardRasterExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"
    ]
    private static let sendVisual: CGFloat = 32
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.composer * interfaceScale, style: .continuous)
    }

    private var totalAttachmentCount: Int {
        attachments.count + fileAttachments.count
    }

    private var canSend: Bool {
        ComposerSendPolicy.canSend(
            text: text,
            attachmentCount: totalAttachmentCount,
            isBusy: isBusy
        )
    }

    private var showsStop: Bool {
        onStop != nil && ComposerSendPolicy.showsStop(
            text: text,
            attachmentCount: totalAttachmentCount,
            isRunning: true
        )
    }

    private var canAttachMore: Bool {
        ComposerSendPolicy.canStartAction(isBusy: isBusy)
            && totalAttachmentCount < Self.maxAttachments
    }

    var body: some View {
        card
            .chatReadableColumn()
            // Same page margin as the conversation so the card’s left and right
            // edges line up with the bubbles, not sit wider than them.
            .interfacePadding(.horizontal, Space.base)
            .interfacePadding(.top, Space.sm)
            .interfacePadding(.bottom, Space.sm)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: totalAttachmentCount)
            .task(id: autoFocus) {
                guard autoFocus, !didAutoFocus else { return }
                // Focus belongs to this mounted composer, not a delayed window task.
                await Task.yield()
                guard !Task.isCancelled else { return }
                #if os(macOS)
                macFocusTrigger &+= 1
                #else
                focused = true
                #endif
                didAutoFocus = true
            }
            // Also runs on mount, so a pane selected before its composer
            // existed (new pane, terminal → chat) still receives the caret.
            .task(id: focusRequest) {
                guard focusRequest != 0 else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                #if os(macOS)
                macFocusTrigger &+= 1
                #else
                focused = true
                #endif
            }
            #if !os(macOS)
            .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
            #endif
            .quickLookPreview($quickLookURL)
            .onChange(of: quickLookURL) { oldURL, newURL in
                if let oldURL, oldURL != newURL {
                    DraftImagePreview.remove(oldURL)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                addFileURLs(urls)
            }
            .alert("composer.preview_failed", isPresented: $previewFailed) {
                Button("action.ok", role: .cancel) {}
            }
            .onDisappear {
                openingImageID = nil
                if let quickLookURL { DraftImagePreview.remove(quickLookURL) }
                quickLookURL = nil
            }
            #if DEBUG
            .onChange(of: inspectionSubmitRequest) { _, request in
                if request > 0 { sendDraft() }
            }
            #if os(macOS)
            .task { await replayInspectionKeys() }
            #endif
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                let inspectImage = arguments.contains("-CorralInspectDraftImage")
                let inspectFile = arguments.contains("-CorralInspectDraftFile")
                guard inspectImage || inspectFile else { return }
                if attachments.isEmpty, let fixture = DraftImageInspection.attachment() {
                    attachments = [fixture]
                    if arguments.contains("-CorralInspectDraftImageOpen") {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        openImagePreview(fixture)
                    }
                }
                if inspectFile, fileAttachments.isEmpty {
                    fileAttachments = [
                        DraftFileAttachment(
                            id: UUID(),
                            name: "spec.pdf",
                            data: Data(repeating: 0x25, count: 14_336)
                        )
                    ]
                }
                text = ProcessInfo.processInfo.environment["CORRAL_INSPECT_DRAFT_TEXT"] ?? "Draft preserved"
            }
            #endif
    }

    /// Compact two-row card: one line of text, a small gap, then plus and send
    /// on the bottom edge. Do not inflate the field into a tall empty well.
    /// The action row is only the 32-point visuals — no extra band under the
    /// buttons. Tapping anywhere on the card focuses the field.
    private var card: some View {
        VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
            if !attachments.isEmpty || !fileAttachments.isEmpty {
                attachmentStrip
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            if let attachmentError {
                Text(verbatim: attachmentError)
                    .interfaceFont(.caption)
                    .foregroundStyle(Palette.danger)
            }

            textField
                .interfaceFrame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())

            actionRow
        }
        .interfacePadding(.horizontal, Space.base)
        .interfacePadding(.top, Space.base)
        .interfacePadding(.bottom, Space.sm)
        .modifier(ComposerMaterial(shape: cardShape))
        // Another Mac pane holds the keys: this card steps back until its pane is focused.
        .opacity(recedes ? 0.5 : 1)
        .contentShape(cardShape)
        .onTapGesture {
            #if os(macOS)
            macFocusTrigger &+= 1
            #else
            focused = true
            #endif
        }
        .accessibilityIdentifier("composer.surface")
        // Arbitrary files & images dragged in attach like picked ones.
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            addAttachments(from: providers)
            return !providers.isEmpty
        }
        #if os(macOS)
        .focusEffectDisabled()
        .onPasteCommand(of: [.fileURL, .image]) { providers in
            addAttachments(from: providers)
        }
        #endif
    }

    @ViewBuilder
    private var textField: some View {
        #if os(macOS)
        MacComposerTextView(
            text: $text,
            placeholder: String(localized: "composer.placeholder"),
            font: Typography.sessionUIFont(.bubbleBody, scale: sessionTextScale * interfaceScale),
            textColor: .labelColor,
            accessibilityLabel: String(localized: "composer.placeholder"),
            focusTrigger: macFocusTrigger,
            onSubmit: sendDraft,
            onFollowUp: followUpDraft,
            onArrowHistory: { isUp in recallHistory(older: isUp) == .handled },
            onRecallQueued: recallQueuedIfEmpty,
            onPasteFileURLs: { urls in addFileURLs(urls) },
            onPasteImageData: { data in addImageData([data]) },
            onFocusChange: { isFocused in onFocusChange?(isFocused) }
        )
        .accessibilityIdentifier("composer.input")
        .background { MacComposerInputAnchor() }
        #else
        TextField("composer.placeholder", text: $text, axis: .vertical)
            .sessionFont(.bubbleBody)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 6)
            .focused($focused)
            .submitLabel(.send)
            .onSubmit(sendDraft)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers == .option else { return .ignored }
                followUpDraft()
                return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { press in
                if press.modifiers == .option, recallQueuedIfEmpty() { return .handled }
                return recallHistory(older: true)
            }
            .onKeyPress(.downArrow, phases: .down) { _ in recallHistory(older: false) }
        #endif
    }

    @ViewBuilder
    private var attachButton: some View {
        #if os(macOS)
        Button {
            showFileImporter = true
        } label: {
            Image(systemName: "plus")
                .interfaceFont(.title2.weight(.medium))
                .interfaceFrame(width: Self.sendVisual, height: Self.sendVisual)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(Text("composer.attach"))
        .accessibilityLabel(Text("composer.attach"))
        #else
        ImagePickerButton(
            isEnabled: canAttachMore,
            onPicked: { base64, preview in
                guard canAttachMore else { return }
                attachmentError = nil
                attachments.append(
                    DraftImageAttachment(id: UUID(), base64: base64, preview: preview)
                )
            },
            onChooseFiles: {
                showFileImporter = true
            }
        )
        #endif
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            attachButton
            .foregroundStyle(canAttachMore ? Color.primary : Color.secondary.opacity(0.45))
            .interfaceFrame(width: Self.sendVisual, height: Self.sendVisual)
            .modifier(ComposerHitTarget(visual: Self.sendVisual))
            .disabled(!canAttachMore)

            Spacer(minLength: 0)

            sendButton
        }
        .interfaceFrame(height: Self.sendVisual)
    }

    /// Send, or stop while the assistant runs and nothing is drafted.
    private var sendButton: some View {
        let stop = showsStop
        let active = stop ? !isStopping && !isBusy : canSend
        let label: LocalizedStringKey = stop ? "composer.stop" : "composer.send"
        let identifier: String = stop ? "composer.stop" : "composer.send"
        let fill: Color = active ? Palette.accent : Color(.quaternarySystemFill)
        return Button {
            if stop { stopTurn() } else { sendDraft() }
        } label: {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .contentTransition(.symbolEffect(.replace))
                // Stop sits one step below the send-arrow size: subheadline
                // (15pt) keeps the square at ~0.39 of the 32pt circle
                // (footnote ~0.34 read too small, body ~0.45 too chunky;
                // measured 2026-10-12). A text style, so Mac interface zoom
                // scales it exactly like the arrow.
                .interfaceFont(stop ? .subheadline.weight(.bold) : .body.weight(.bold))
                .foregroundStyle(active ? Palette.onAccent : Color.secondary)
                .interfaceFrame(width: Self.sendVisual, height: Self.sendVisual)
                .background(Circle().fill(fill))
        }
        .buttonStyle(PressableButtonStyle())
        .modifier(ComposerHitTarget(visual: Self.sendVisual))
        .disabled(!active)
        .accessibilityIdentifier(identifier)
        #if os(macOS)
        .help(Text(label))
        #else
        // Hardware keyboard on iPad (owner request 2026-11-01). A ⌘ chord
        // never reaches an input method, so marked text is never sent; plain
        // Return keeps the touch keyboard's behavior. Stop is never bound.
        .keyboardShortcut(stop ? nil : KeyboardShortcut(.return, modifiers: .command))
        #endif
        .accessibilityLabel(Text(label))
        .contextMenu {
            if !stop && showsFollowUpContextAction && canSend && onFollowUp != nil {
                Button {
                    followUpDraft()
                } label: {
                    Label("composer.followup.queue_action", systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }

    private func stopTurn() {
        guard showsStop, !isStopping, !isBusy else { return }
        onStop?()
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm * interfaceScale) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, item in
                    attachmentChip(index: index, item: item)
                }
                ForEach(Array(fileAttachments.enumerated()), id: \.element.id) { index, item in
                    fileChip(index: index, item: item)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func fileChip(index: Int, item: DraftFileAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { openFilePreview(item) } label: {
                HStack(spacing: Space.xs * interfaceScale) {
                    Image(systemName: draftFileIconName(for: item.name))
                        .interfaceFont(.title3)
                        .foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.name)
                            .interfaceFont(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: item.formattedSize)
                            .interfaceFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .interfacePadding(.horizontal, Space.sm)
                .interfaceFrame(minWidth: 110, maxWidth: 190, minHeight: 56, maxHeight: 56, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text(verbatim: item.name))
            .disabled(openingImageID != nil)

            attachmentRemoveButton(label: "composer.remove_file") {
                fileAttachments.removeAll { $0.id == item.id }
            }
        }
        .interfacePadding(.top, 10)
        .interfacePadding(.trailing, 10)
    }

    private func attachmentRemoveButton(label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.55))
                .interfaceFont(.body)
                .interfaceFrame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .offset(x: 10, y: -10)
        .accessibilityLabel(Text(label))
    }

    private func draftFileIconName(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "7z", "rar": return "doc.zipper"
        case "md", "markdown", "txt", "rtf", "log": return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "swift", "py", "ts", "tsx", "js", "rs", "go":
            return "curlybraces.square"
        default: return "doc.fill"
        }
    }

    private func attachmentChip(index: Int, item: DraftImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { openImagePreview(item) } label: {
                Image(platformImage: item.preview)
                    .resizable()
                    .scaledToFill()
                    .interfaceFrame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text("\(index + 1)")
                            .interfaceFont(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .interfacePadding(.horizontal, 5)
                            .interfacePadding(.vertical, 2)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .interfacePadding(Space.xs)
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("composer.image_index \(index + 1)"))
            .accessibilityHint(Text("chat.image.open_hint"))
            .accessibilityIdentifier("composer.image.\(index)")
            .disabled(openingImageID != nil)

            attachmentRemoveButton(label: "composer.remove_image") {
                attachments.removeAll { $0.id == item.id }
            }
        }
        .interfaceFrame(width: 64, height: 64)
        .interfacePadding(.top, 10)
        .interfacePadding(.trailing, 10)
    }

    private func openImagePreview(_ item: DraftImageAttachment) {
        guard openingImageID == nil else { return }
        openingImageID = item.id
        Task {
            let url = await DraftImagePreview.prepare(base64: item.base64)
            guard openingImageID == item.id else {
                if let url { DraftImagePreview.remove(url) }
                return
            }
            openingImageID = nil
            guard attachments.contains(where: { $0.id == item.id }) else {
                if let url { DraftImagePreview.remove(url) }
                return
            }
            if let url {
                clearFocus()
                quickLookURL = url
            } else {
                previewFailed = true
            }
        }
    }

    private func openFilePreview(_ item: DraftFileAttachment) {
        guard openingImageID == nil else { return }
        openingImageID = item.id
        Task {
            let url = await DraftImagePreview.prepareFile(name: item.name, data: item.data)
            guard openingImageID == item.id else {
                if let url { DraftImagePreview.remove(url) }
                return
            }
            openingImageID = nil
            guard fileAttachments.contains(where: { $0.id == item.id }) else {
                if let url { DraftImagePreview.remove(url) }
                return
            }
            if let url {
                clearFocus()
                quickLookURL = url
            } else {
                previewFailed = true
            }
        }
    }

    private func requestFocus() {
        #if os(macOS)
        macFocusTrigger &+= 1
        #else
        focused = true
        #endif
    }

    private func clearFocus() {
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        focused = false
        #endif
    }

    private func sendDraft() {
        guard let taken = takeSubmittedDraft() else { return }
        onSend(taken.text, taken.images, taken.files)
    }

    private func followUpDraft() {
        guard let taken = takeSubmittedDraft() else { return }
        if let onFollowUp {
            onFollowUp(taken.text, taken.images, taken.files)
        } else {
            onSend(taken.text, taken.images, taken.files)
        }
    }

    private func takeSubmittedDraft() -> (text: String, images: [DraftImageAttachment], files: [DraftFileAttachment])? {
        guard ComposerSendPolicy.canSend(
            text: text,
            attachmentCount: totalAttachmentCount,
            isBusy: isBusy
        ) else { return nil }
        let images = attachments
        let files = fileAttachments
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(iOS)
        // Clear through the active native input transaction while retaining
        // the field and its keyboard, including confirmed IME composition.
        NativeComposerEditing.clearSubmittedText(text)
        #endif
        text = ""
        attachments = []
        fileAttachments = []
        attachmentError = nil
        recall.reset()
        requestFocus()
        return (payload, images, files)
    }

    private func recallQueuedIfEmpty() -> Bool {
        guard text.isEmpty && attachments.isEmpty && fileAttachments.isEmpty else { return false }
        return onRecallQueued?() ?? false
    }

    /// Up / Down step through this session's prompts when the caret sits on the
    /// edge line; otherwise the key keeps moving the caret inside the text.
    /// Attachments are untouched and nothing is sent.
    private func recallHistory(older: Bool) -> KeyPress.Result {
        guard caretAllowsRecall(older: older) else { return .ignored }
        let next = older
            ? recall.older(entries: history, current: text)
            : recall.newer(entries: history)
        guard let next else { return .ignored }
        #if os(macOS)
        if let editor = activeEditor {
            // Native replacement updates the text binding and places the caret
            // after the recalled prompt without a persistent selection binding.
            editor.insertText(next, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        } else {
            text = next
        }
        #else
        text = next
        #endif
        return .handled
    }

    private func caretAllowsRecall(older: Bool) -> Bool {
        if !older, !recall.isBrowsing { return false }
        // An untouched recalled entry keeps stepping, even across its own lines.
        if recall.isShowingUnchanged(text) { return true }
        #if os(macOS)
        if let editor = (NSApp.keyWindow ?? NSApp.orderedWindows.first)?.firstResponder as? NSTextView {
            // Leave arrows to an input method choosing a candidate.
            guard !editor.hasMarkedText() else { return false }
            return editor.caretIsOnEdgeLine(first: older)
        }
        #endif
        // No caret access here (iOS 17): only an empty field starts browsing.
        return text.isEmpty
    }

    #if os(macOS)
    private var activeEditor: NSTextView? {
        guard let editor = (NSApp.keyWindow ?? NSApp.orderedWindows.first)?.firstResponder as? NSTextView,
              editor.isEditable else { return nil }
        return editor
    }

    private func insertLineBreak() {
        guard let editor = activeEditor, !editor.hasMarkedText() else { return }
        editor.insertText("\n", replacementRange: editor.selectedRange())
    }

    #if DEBUG
    private static var didReplayInspectionKeys = false

    /// Debug-only acceptance without driving the keyboard: with
    /// `CORRAL_INSPECT_COMPOSER_KEYS` (`draft:<text>`, `up`, `down`, comma
    /// separated, one step every three seconds) real arrow key events go
    /// through the window to the selected pane's field. Release has none.
    private func replayInspectionKeys() async {
        guard let script = ProcessInfo.processInfo.environment["CORRAL_INSPECT_COMPOSER_KEYS"] else { return }
        try? await Task.sleep(for: .seconds(3))
        // The selected pane's composer (the one not stepping back) takes it, once.
        guard !Task.isCancelled, !recedes, !Self.didReplayInspectionKeys else { return }
        Self.didReplayInspectionKeys = true
        requestFocus()
        for step in script.split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .seconds(3))
            if step.hasPrefix("draft:") {
                text = String(step.dropFirst(6)).replacingOccurrences(of: "\\n", with: "\n")
                if let editor = activeEditor {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
                continue
            }
            let up = step == "up"
            guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first,
                  let key = UnicodeScalar(up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey),
                  let event = NSEvent.keyEvent(
                      with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                      context: nil, characters: String(key), charactersIgnoringModifiers: String(key),
                      isARepeat: false, keyCode: up ? 126 : 125
                  ) else { continue }
            window.sendEvent(event)
        }
    }
    #endif
    #endif

    private func addAttachments(from providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addFileURLs([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in addImageData([data]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    let name = url.lastPathComponent
                    Task { @MainActor in ingestLoadedFile(name: name, data: data, isExplicitImage: false) }
                }
            }
        }
    }

    private func addFileURLs(_ urls: [URL]) {
        attachmentError = nil
        for url in urls {
            guard canAttachMore else { break }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                attachmentError = String(localized: "composer.folder_unsupported")
                continue
            }
            if let fileSize = values?.fileSize, fileSize > ComposerSendPolicy.maxFileAttachmentBytes {
                attachmentError = String(localized: "composer.file_too_large")
                continue
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let isImageType = Self.standardRasterExtensions.contains(url.pathExtension.lowercased())
            ingestLoadedFile(name: url.lastPathComponent, data: data, isExplicitImage: isImageType)
        }
    }

    private func ingestLoadedFile(name: String, data: Data, isExplicitImage: Bool) {
        guard canAttachMore else { return }
        if data.count > ComposerSendPolicy.maxFileAttachmentBytes {
            attachmentError = String(localized: "composer.file_too_large")
            return
        }
        if isExplicitImage, data.count <= Self.maxImageBytes,
           let encoded = ImageAttachmentEncoder.encode(data) {
            attachmentError = nil
            attachments.append(DraftImageAttachment(id: UUID(), base64: encoded.base64, preview: encoded.preview))
            return
        }
        attachmentError = nil
        let cleanName = ChatFileLink.sanitizedFileName(name, fallback: "attachment")
        fileAttachments.append(DraftFileAttachment(id: UUID(), name: cleanName, data: data))
    }

    private func addImageData(_ items: [Data]) {
        attachmentError = nil
        for data in items {
            guard canAttachMore,
                  let encoded = ImageAttachmentEncoder.encode(data) else { continue }
            attachments.append(DraftImageAttachment(id: UUID(), base64: encoded.base64, preview: encoded.preview))
        }
    }
}

#if os(macOS)
private extension NSTextView {
    /// Caret (no selection) on the first or last visual line, wrapping included.
    func caretIsOnEdgeLine(first: Bool) -> Bool {
        let range = selectedRange()
        guard range.length == 0 else { return false }
        let edge = first ? 0 : (string as NSString).length
        guard range.location != edge else { return true }
        let caret = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        let edgeLine = firstRect(forCharacterRange: NSRange(location: edge, length: 0), actualRange: nil)
        return abs(caret.midY - edgeLine.midY) < 1
    }
}
#endif

extension EnvironmentValues {
    /// Set by a Mac split pane whose neighbour has focus; the iPhone never sets it.
    @Entry var composerRecedes = false
}

/// Expand the control to a 44-point hit target without changing layout height.
private struct ComposerHitTarget: ViewModifier {
    @Environment(\.interfaceScale) private var interfaceScale
    var visual: CGFloat

    func body(content: Content) -> some View {
        let slop = max(0, (TouchTarget.minimum - visual) / 2)
        content
            .interfacePadding(slop)
            .contentShape(Rectangle())
            .interfacePadding(-slop)
    }
}

/// One native material surface; nested controls do not stack extra glass layers.
private struct ComposerMaterial: ViewModifier {
    @Environment(\.interfaceScale) private var interfaceScale
    let shape: RoundedRectangle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(.secondarySystemGroupedBackground), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
