import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage

/// iOS grouped-surface names used by the shared views, mapped to Mac surfaces.
/// The conversation page is the window's text background; cards and assistant
/// surfaces sit one step above it in both appearances.
extension NSColor {
    static let systemGroupedBackground = NSColor.textBackgroundColor
    static let secondarySystemGroupedBackground = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
            : NSColor(srgbRed: 0.955, green: 0.955, blue: 0.96, alpha: 1)
    }
    static let tertiarySystemGroupedBackground = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.21, green: 0.21, blue: 0.22, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.93, alpha: 1)
    }
    static let tertiarySystemBackground = secondarySystemGroupedBackground
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                         .accessibilityHighContrastVibrantDark]) != nil
    }
}
#endif

extension PlatformImage {
    /// Encoded JPEG for outbound attachments and preview caches.
    func corralJPEGData(quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        jpegData(compressionQuality: quality)
        #else
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }

    /// Wraps a decoded bitmap at one point per pixel on both platforms.
    convenience init(corralCGImage cgImage: CGImage) {
        #if canImport(UIKit)
        self.init(cgImage: cgImage)
        #else
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    var corralCGImage: CGImage? {
        #if canImport(UIKit)
        cgImage
        #else
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Copies plain text to the general pasteboard.
enum PlatformPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Trailing confirm/close slot of a sheet: the navigation bar's trailing edge
    /// on iOS, the standard confirmation slot of a Mac sheet.
    static var corralTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .confirmationAction
        #endif
    }
}

extension View {
    /// Inline (compact) navigation titles on iOS; Mac windows have no large titles.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Conversation layout differences between the phone and the Mac window.
enum ChatLayout {
    /// The Mac centers conversation and composer in a readable column so wide
    /// windows never produce overlong lines; the phone uses the full width.
    static var readableWidth: CGFloat? {
        #if os(macOS)
        760
        #else
        nil
        #endif
    }

    /// Owner decision 2026-10-04: assistant replies on the Mac are plain text on
    /// the page (desktop convention); iOS keeps the assistant bubble.
    static var assistantUsesBubble: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}

extension View {
    /// Centers content in the platform's readable column (no-op on iPhone).
    func chatReadableColumn() -> some View {
        interfaceFrame(maxWidth: ChatLayout.readableWidth ?? .infinity)
            .frame(maxWidth: .infinity)
    }
}

extension EnvironmentValues {
    /// Visible height of the conversation scroll view, published by
    /// `ChatScrollView`. The Mac caps long bubbles against it (a window, not the
    /// screen, is the reading surface); 0 until the first layout pass.
    @Entry var chatViewportHeight: CGFloat = 0
}
