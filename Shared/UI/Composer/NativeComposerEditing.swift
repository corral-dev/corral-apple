#if os(iOS)
import UIKit

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
