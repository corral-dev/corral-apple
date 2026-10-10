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

struct ComposerBar: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Binding var text: String
    @Binding var attachments: [DraftImageAttachment]
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
    var onSend: (_ text: String, _ images: [DraftImageAttachment]) -> Void

    @FocusState private var focused: Bool
    #if os(macOS)
    @State private var selection: TextSelection?
    @State private var showImageImporter = false
    #endif
    @State private var didAutoFocus = false
    @State private var recall = ComposerHistory()
    @State private var quickLookURL: URL?
    @State private var openingImageID: UUID?
    @State private var previewFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.composerRecedes) private var recedes

    private static let maxAttachments = ComposerSendPolicy.maxAttachments
    private static let sendVisual: CGFloat = 32
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.composer * interfaceScale, style: .continuous)
    }

    private var canSend: Bool {
        ComposerSendPolicy.canSend(
            text: text,
            attachmentCount: attachments.count,
            isBusy: isBusy
        )
    }

    private var canAttachMore: Bool {
        ComposerSendPolicy.canStartAction(isBusy: isBusy)
            && attachments.count < Self.maxAttachments
    }

    var body: some View {
        card
            .chatReadableColumn()
            // Same page margin as the conversation so the card’s left and right
            // edges line up with the bubbles, not sit wider than them.
            .interfacePadding(.horizontal, Space.base)
            .interfacePadding(.top, Space.sm)
            .interfacePadding(.bottom, Space.sm)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: attachments.count)
            .task(id: autoFocus) {
                guard autoFocus, !didAutoFocus else { return }
                // Focus belongs to this mounted composer, not a delayed window task.
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = true
                didAutoFocus = true
            }
            // Also runs on mount, so a pane selected before its composer
            // existed (new pane, terminal → chat) still receives the caret.
            .task(id: focusRequest) {
                guard focusRequest != 0 else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = true
            }
            .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
            .quickLookPreview($quickLookURL)
            .onChange(of: quickLookURL) { oldURL, newURL in
                if let oldURL, oldURL != newURL {
                    DraftImagePreview.remove(oldURL)
                }
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
            #if os(macOS)
            .task { await replayInspectionKeys() }
            #endif
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard arguments.contains("-CorralInspectDraftImage"), attachments.isEmpty,
                      let fixture = DraftImageInspection.attachment() else { return }
                // Local fixture only; the production preview handler never sends.
                attachments = [fixture]
                text = "Draft preserved"
                if arguments.contains("-CorralInspectDraftImageOpen") {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    openImagePreview(fixture)
                }
            }
            #endif
    }

    /// Compact two-row card: one line of text, a small gap, then plus and send
    /// on the bottom edge. Do not inflate the field into a tall empty well.
    /// The action row is only the 32-point visuals — no extra band under the
    /// buttons. Tapping anywhere on the card focuses the field.
    private var card: some View {
        VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
            if !attachments.isEmpty {
                attachmentStrip
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            textField
                .sessionFont(.bubbleBody)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .focused($focused)
                .onSubmit(sendDraft)
                .onKeyPress(.upArrow, phases: .down) { _ in recallHistory(older: true) }
                .onKeyPress(.downArrow, phases: .down) { _ in recallHistory(older: false) }
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
        .onTapGesture { focused = true }
        .accessibilityIdentifier("composer.surface")
        #if os(macOS)
        .focusEffectDisabled()
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            addImages(from: providers)
        }
        .dropDestination(for: Data.self) { items, _ in
            addImageData(items)
            return !items.isEmpty
        }
        .fileImporter(
            isPresented: $showImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            addImageData(urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            })
        }
        #endif
    }

    @ViewBuilder
    private var textField: some View {
        #if os(macOS)
        // Return sends through onSubmit (the field editor finishes any input-method
        // composition first); Shift-Return inserts a line break at the caret.
        TextField("composer.placeholder", text: $text, selection: $selection, axis: .vertical)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                insertLineBreak()
                return .handled
            }
        #else
        TextField("composer.placeholder", text: $text, axis: .vertical)
            .submitLabel(.send)
        #endif
    }

    @ViewBuilder
    private var attachButton: some View {
        #if os(macOS)
        Button {
            showImageImporter = true
        } label: {
            Image(systemName: "plus")
                .interfaceFont(.title2.weight(.medium))
                .interfaceFrame(width: Self.sendVisual, height: Self.sendVisual)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(Text("composer.attach_image"))
        .accessibilityLabel(Text("composer.attach_image"))
        #else
        ImagePickerButton(isEnabled: canAttachMore) { base64, preview in
            guard canAttachMore else { return }
            attachments.append(
                DraftImageAttachment(id: UUID(), base64: base64, preview: preview)
            )
        }
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

    private var sendButton: some View {
        Button(action: sendDraft) {
            Image(systemName: "arrow.up")
                .interfaceFont(.body.weight(.bold))
                .foregroundStyle(canSend ? Palette.onAccent : Color.secondary)
                .interfaceFrame(width: Self.sendVisual, height: Self.sendVisual)
                .background(
                    Circle().fill(canSend ? Palette.accent : Color(.quaternarySystemFill))
                )
        }
        .buttonStyle(PressableButtonStyle())
        .modifier(ComposerHitTarget(visual: Self.sendVisual))
        .disabled(!canSend)
        .accessibilityLabel(Text("composer.send"))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm * interfaceScale) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, item in
                    attachmentChip(index: index, item: item)
                }
            }
        }
        .accessibilityElement(children: .contain)
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

            Button {
                attachments.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
                    .interfaceFont(.body)
                    .interfaceFrame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .offset(x: 10, y: -10)
            .accessibilityLabel(Text("composer.remove_image"))
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
                focused = false
                quickLookURL = url
            } else {
                previewFailed = true
            }
        }
    }

    private func sendDraft() {
        guard ComposerSendPolicy.canSend(
            text: text,
            attachmentCount: attachments.count,
            isBusy: isBusy
        ) else { return }
        let images = attachments
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        attachments = []
        recall.reset()
        focused = true
        onSend(payload, images)
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
        text = next
        #if os(macOS)
        selection = TextSelection(insertionPoint: text.endIndex)
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
    private func insertLineBreak() {
        guard case .selection(let range)? = selection?.indices else {
            text += "\n"
            return
        }
        text.replaceSubrange(range, with: "\n")
        let caret = text.index(range.lowerBound, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
        selection = TextSelection(insertionPoint: caret)
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
        focused = true
        for step in script.split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .seconds(3))
            if step.hasPrefix("draft:") {
                text = String(step.dropFirst(6)).replacingOccurrences(of: "\\n", with: "\n")
                selection = TextSelection(insertionPoint: text.endIndex)
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

    private func addImages(from providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in addImageData([data]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in addImageData([data]) }
                }
            }
        }
    }

    private func addImageData(_ items: [Data]) {
        for data in items {
            guard canAttachMore,
                  let encoded = ImageAttachmentEncoder.encode(data) else { continue }
            attachments.append(DraftImageAttachment(id: UUID(), base64: encoded.base64, preview: encoded.preview))
        }
    }
    #endif
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
