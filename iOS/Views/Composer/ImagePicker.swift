#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit

struct ImagePickerButton: View {
    var isEnabled: Bool = true
    var onPicked: (_ base64: String, _ preview: UIImage) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            // A plus on the bottom-left of the floating card, matching the
            // ChatGPT composer: a plain add glyph, not a photo thumbnail.
            Image(systemName: "plus")
                .font(.title2.weight(.medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(Text("composer.attach_image"))
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let compressed = compressJPEG(data) {
                    onPicked(compressed.jpeg.base64EncodedString(), compressed.preview)
                }
                item = nil
            }
        }
    }

    private func compressJPEG(
        _ data: Data,
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.75
    ) -> (jpeg: Data, preview: UIImage)? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, true, 1)
        image.draw(in: CGRect(origin: .zero, size: target))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let resized,
              let jpeg = resized.jpegData(compressionQuality: quality) else { return nil }
        return (jpeg, resized)
    }
}
#endif
