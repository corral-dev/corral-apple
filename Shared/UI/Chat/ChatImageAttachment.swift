import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A media attachment that opens a viewer instead of being copied as an object
/// replacement character. Implemented by the diagram and inline-image
/// attachments; the text view delegate routes taps through this protocol.
nonisolated protocol ChatTextAttachmentOpening {
    @MainActor func open()
}

/// Inline image attachment at the Markdown image's position in the message.
/// The image is already decoded by `ChatImageLoader`; while it is missing the
/// attachment reserves a neutral preview block so the message does not reflow
/// from zero height. The alt text stays in the surrounding text.
nonisolated final class ChatImageAttachment: NSTextAttachment, ChatSourceAttachment, ChatTextAttachmentOpening {
    let ref: String
    let alt: String
    let naturalSize: CGSize
    let isPlaceholder: Bool
    private let openAction: @MainActor () -> Void

    @MainActor init(
        ref: String, alt: String, image: PlatformImage?,
        displayScale: CGFloat, open: @escaping @MainActor () -> Void
    ) {
        self.ref = ref
        self.alt = alt
        self.openAction = open
        let placeholder = image == nil
        isPlaceholder = placeholder
        let source = image ?? Self.placeholderImage()
        let pixels = source.size
        naturalSize = placeholder
            ? CGSize(width: max(1, pixels.width), height: max(1, pixels.height))
            : CGSize(width: max(1, pixels.width / max(displayScale, 1)),
                     height: max(1, pixels.height / max(displayScale, 1)))
        super.init(data: nil, ofType: nil)
        self.image = source
        bounds = Self.bounds(for: naturalSize, available: 320)
    }
    required init?(coder: NSCoder) { return nil }

    /// Copy output: the visible alt text already precedes the attachment, so
    /// drop the object-replacement character instead of duplicating it.
    var original: String { "" }

    @MainActor func open() { openAction() }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        Self.bounds(for: naturalSize, available: max(1, lineFrag.width))
    }

    #if canImport(UIKit)
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        Self.bounds(for: naturalSize, available: max(1, proposedLineFragment.width))
    }
    #endif

    private static func bounds(for natural: CGSize, available: CGFloat) -> CGRect {
        let maxHeight: CGFloat = 420
        let scale = min(1, available / max(natural.width, 1), maxHeight / max(natural.height, 1))
        return CGRect(x: 0, y: 0, width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }


    /// Neutral 3:2 block before the host preview arrives. Generated once; the
    /// real image replaces the attachment on the loader's next revision.
    @MainActor private static let placeholder: PlatformImage = {
        let size = CGSize(width: 300, height: 200)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.tertiarySystemFill.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: "photo")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            if let symbol {
                let side = min(size.width, size.height) * 0.28
                symbol.draw(in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side))
            }
        }
        #else
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) {
            let side = min(size.width, size.height) * 0.28
            symbol.draw(in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side))
        }
        image.unlockFocus()
        return image
        #endif
    }()

    @MainActor private static func placeholderImage() -> PlatformImage { placeholder }
}

/// Presentation equality ignores recreated attachment wrapper identity, but
/// still includes the actual bitmap, geometry and source/copy semantics. A
/// SwiftUI refresh must not replace unchanged native text during a scroll.
nonisolated enum ChatTextPresentation {
    static func matches(_ lhs: AttributedString, _ rhs: AttributedString) -> Bool {
        if lhs == rhs { return true }
        let left = NSMutableAttributedString(attributedString: NSAttributedString(lhs))
        let right = NSMutableAttributedString(attributedString: NSAttributedString(rhs))
        guard left.string == right.string else { return false }
        var equal = true
        left.enumerateAttribute(.attachment, in: NSRange(location: 0, length: left.length)) { value, range, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            guard let other = right.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  sameAttachment(attachment, other) else { equal = false; stop.pointee = true; return }
            left.removeAttribute(.attachment, range: range)
            right.removeAttribute(.attachment, range: range)
        }
        return equal && left.isEqual(to: right)
    }

    private static func sameAttachment(_ lhs: NSTextAttachment, _ rhs: NSTextAttachment) -> Bool {
        if lhs === rhs { return true }
        guard lhs.image === rhs.image, lhs.bounds == rhs.bounds else { return false }
        if let left = lhs as? ChatImageAttachment, let right = rhs as? ChatImageAttachment {
            return left.ref == right.ref && left.alt == right.alt && left.naturalSize == right.naturalSize
                && left.isPlaceholder == right.isPlaceholder
        }
        if let left = lhs as? ChatDiagramAttachment, let right = rhs as? ChatDiagramAttachment {
            return left.original == right.original && left.selectionLength == right.selectionLength
        }
        return false
    }
}

#if os(macOS)
extension ChatImageAttachment: MacMessageMediaAttachment {
    var selectionLength: Int { 1 }
}
#endif
