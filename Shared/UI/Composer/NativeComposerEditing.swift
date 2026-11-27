#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Uses the public responder chain and text-input contract without replacing
/// the SwiftUI field or changing first responder ownership.
enum NativeComposerEditing {
    @discardableResult
    static func clearSubmittedText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let request = ComposerClearRequest(text: text)
        UIApplication.shared.sendAction(
            #selector(UIResponder.corralClearSubmittedComposerText(_:)),
            to: nil, from: request, for: nil
        )
        return request.didClear
    }
}

private final class ComposerClearRequest: NSObject {
    let text: String
    var didClear = false

    init(text: String) { self.text = text }
}

/// Non-interactive geometry anchor; the SwiftUI field still owns editing and focus.
/// UIKit's editing notification supplies the native editor, without walking its view hierarchy.
struct NativeComposerPasteAnchor: UIViewRepresentable {
    var onAttachment: (NSItemProvider) -> Void

    func makeUIView(context: Context) -> NativeComposerPasteAnchorView {
        let view = NativeComposerPasteAnchorView()
        view.onAttachment = onAttachment
        return view
    }

    func updateUIView(_ uiView: NativeComposerPasteAnchorView, context: Context) {
        uiView.onAttachment = onAttachment
    }
}

final class NativeComposerPasteAnchorView: UIView, UITextPasteDelegate {
    private weak var editor: UITextView?
    private weak var originalDelegate: (any UITextPasteDelegate)?
    private var originalConfiguration: UIPasteConfiguration?
    private var originalAllowsEditingTextAttributes = false
    var onAttachment: ((NSItemProvider) -> Void)?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(editingDidBegin), name: UITextView.textDidBeginEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(editingDidEnd), name: UITextView.textDidEndEditingNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() }
    }

    @objc private func editingDidBegin(_ notification: Notification) {
        guard let editor = notification.object as? UITextView, let window, editor.window === window,
              editor !== self.editor else { return }
        let center = editor.convert(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: self)
        guard bounds.contains(center) else { return }
        detach()
        self.editor = editor
        originalDelegate = editor.pasteDelegate
        originalConfiguration = editor.pasteConfiguration
        originalAllowsEditingTextAttributes = editor.allowsEditingTextAttributes
        // UIKit's edit menu disables Paste for image-only data in plain-text mode,
        // even when canPaste(_:) accepts the item providers. The delegate still
        // keeps attachments out of the text storage and flattens rich text.
        editor.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.image.identifier, UTType.fileURL.identifier, UTType.url.identifier,
            UTType.plainText.identifier, UTType.data.identifier,
        ])
        editor.pasteDelegate = self
        editor.allowsEditingTextAttributes = true
    }

    @objc private func editingDidEnd(_ notification: Notification) {
        if let editor, notification.object as? UITextView === editor { detach() }
    }

    private func detach() {
        if let editor, editor.pasteDelegate === self {
            editor.pasteConfiguration = originalConfiguration
            editor.allowsEditingTextAttributes = originalAllowsEditingTextAttributes
            editor.pasteDelegate = originalDelegate
        }
        editor = nil
        originalDelegate = nil
        originalConfiguration = nil
    }

    func textPasteConfigurationSupporting(
        _ supporting: any UITextPasteConfigurationSupporting, transform item: any UITextPasteItem
    ) {
        let provider = item.itemProvider
        if let onAttachment, ComposerAttachmentSource(provider: provider) != nil {
            item.setNoResult()
            onAttachment(provider)
        } else if ComposerAttachmentSource.hasRichText(provider), provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                Task { @MainActor in
                    if let text { item.setResult(string: text) } else { item.setDefaultResult() }
                }
            }
        } else if originalDelegate?.textPasteConfigurationSupporting?(supporting, transform: item) == nil {
            item.setDefaultResult()
        }
    }
}

extension UIResponder {
    @objc func corralClearSubmittedComposerText(_ sender: Any?) {
        guard isFirstResponder,
              let request = sender as? ComposerClearRequest,
              let input = self as? any UITextInput,
              let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument),
              input.text(in: range) == request.text else { return }
        input.unmarkText()
        guard let committedRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument),
              input.text(in: committedRange) == request.text else { return }
        input.replace(committedRange, withText: "")
        request.didClear = true
    }
}
#endif
