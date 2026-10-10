import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Downscales an outbound image to the same JPEG budget the iOS picker uses
/// (longest side 1600 px, quality 0.75) with ImageIO, which is shared by both
/// platforms and never decodes the full-size original into memory.
enum ImageAttachmentEncoder {
    static func encode(
        _ data: Data,
        maxDimension: Int = 1600,
        quality: CGFloat = 0.75
    ) -> (base64: String, preview: PlatformImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        #if canImport(UIKit)
        let preview = UIImage(cgImage: image)
        #else
        let preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #endif
        return ((output as Data).base64EncodedString(), preview)
    }
}
