#if DEBUG
import SwiftUI

/// Deterministic non-user image for same-app preview inspection without pointer input.
enum DraftImageInspection {
    static func attachment() -> DraftImageAttachment? {
        guard let context = CGContext(
            data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        context.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.35, alpha: 1))
        context.fillEllipse(in: CGRect(x: 200, y: 120, width: 240, height: 240))
        guard let bitmap = context.makeImage() else { return nil }
        let image = PlatformImage(corralCGImage: bitmap)
        guard let data = image.corralJPEGData(quality: 0.75) else { return nil }
        return DraftImageAttachment(id: UUID(), base64: data.base64EncodedString(), preview: image)
    }
}

extension View {
    func draftImageInspection() -> some View {
        modifier(DraftImageInspectionModifier())
    }
}

private struct DraftImageInspectionModifier: ViewModifier {
    @State private var presented = ProcessInfo.processInfo.arguments.contains("-CorralInspectDraftImage")
    @State private var draft = ""
    @State private var attachments: [DraftImageAttachment] = []

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presented) {
            NavigationStack {
                VStack {
                    Spacer()
                    ComposerBar(text: $draft, attachments: $attachments, onSend: { _, _ in })
                }
                .navigationTitle("Attachment preview inspection")
                .toolbar {
                    ToolbarItem(placement: .corralTrailing) {
                        Button("action.done") { presented = false }
                    }
                }
            }
        }
    }
}
#endif
