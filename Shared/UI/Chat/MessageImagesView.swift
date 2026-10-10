import QuickLook
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension EnvironmentValues {
    /// Per-conversation preview loader; nil outside a host conversation.
    @Entry var chatImageLoader: ChatImageLoader? = nil
}

/// Parsing runs on every bubble render; long transcripts repeat the same text.
enum ChatImageReferenceCache {
    private final class Box {
        let references: [ChatImageReference]
        init(_ references: [ChatImageReference]) { self.references = references }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 512
        return cache
    }()

    static func references(in text: String) -> [ChatImageReference] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.references }
        let parsed = ChatImageReference.references(in: text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

/// Images a message cites, shown under its text inside the bubble.
struct MessageImagesView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let seq: Int
    let references: [ChatImageReference]
    let isUser: Bool
    var userForeground: Color = Palette.userBubbleForeground
    @Environment(\.chatImageLoader) private var loader

    var body: some View {
        if let loader, loader.isAvailable {
            VStack(alignment: isUser ? .trailing : .leading, spacing: Space.sm * interfaceScale) {
                ForEach(references, id: \.ref) { reference in
                    MessageImageTile(
                        seq: seq, reference: reference, loader: loader,
                        isUser: isUser, userForeground: userForeground
                    )
                }
            }
        }
    }
}

private struct MessageImageTile: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let seq: Int
    let reference: ChatImageReference
    let loader: ChatImageLoader
    let isUser: Bool
    let userForeground: Color

    private enum Phase {
        case loading
        case loaded(PlatformImage)
        case hidden
        case unavailable
    }

    /// Fits the narrowest supported bubble column (375 pt screen minus page and bubble insets).
    private static let maxSide: CGFloat = 240
    private static let placeholderSize = CGSize(width: 200, height: 140)

    @State private var phase: Phase
    @State private var quickLookURL: URL?
    @State private var isOpening = false
    @Environment(\.displayScale) private var displayScale

    init(
        seq: Int, reference: ChatImageReference, loader: ChatImageLoader,
        isUser: Bool, userForeground: Color
    ) {
        self.seq = seq
        self.reference = reference
        self.loader = loader
        self.isUser = isUser
        self.userForeground = userForeground
        // A cached preview lays out at its real size in the first pass; a
        // placeholder that later resizes would shove the bubbles below it.
        let cached = loader.cachedImage(seq: seq, ref: reference.ref, tier: loader.inlineTier())
        _phase = State(initialValue: cached.map(Phase.loaded) ?? .loading)
    }

    private struct LoadKey: Equatable {
        let seq: Int
        let ref: String
        let tier: ChatImageTier
    }

    var body: some View {
        content
            .task(id: LoadKey(seq: seq, ref: reference.ref, tier: loader.inlineTier())) {
                await load()
            }
            .quickLookPreview($quickLookURL)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous)
                .fill(placeholderFill)
                .interfaceFrame(width: Self.placeholderSize.width, height: Self.placeholderSize.height)
                .overlay {
                    ProgressView().tint(isUser ? userForeground : Palette.accent)
                }
                .accessibilityLabel(Text("chat.image.loading"))
        case .loaded(let image):
            Button(action: openFullImage) {
                Image(platformImage: image)
                    .resizable()
                    .interfaceFrame(width: displaySize(of: image).width, height: displaySize(of: image).height)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous))
                    .overlay {
                        if isOpening {
                            ProgressView().tint(isUser ? userForeground : Palette.accent)
                        }
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text(verbatim: reference.displayName))
            .accessibilityHint(Text("chat.image.open_hint"))
            .accessibilityAddTraits(.isImage)
        case .unavailable:
            Label {
                Text("chat.image.unavailable \(reference.displayName)")
            } icon: {
                Image(systemName: "photo")
            }
            .interfaceFont(.footnote)
            .foregroundStyle(isUser ? userForeground : Color.secondary)
            .lineLimit(2)
        case .hidden:
            EmptyView()
        }
    }

    private var placeholderFill: Color {
        isUser ? userForeground.opacity(0.08) : Color(.tertiarySystemFill)
    }

    private func displaySize(of image: PlatformImage) -> CGSize {
        let width = max(image.size.width / max(displayScale, 1), 1)
        let height = max(image.size.height / max(displayScale, 1), 1)
        let scale = min(1, Self.maxSide / width, Self.maxSide / height)
        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    private func load() async {
        let tier = loader.inlineTier()
        if let cached = loader.cachedImage(seq: seq, ref: reference.ref, tier: tier) {
            phase = .loaded(cached)
            return
        }
        if case .loaded = phase {} else { phase = .loading }
        switch await loader.load(seq: seq, ref: reference.ref, tier: tier) {
        case .image(let image):
            phase = .loaded(image)
        case .missing:
            // A path mentioned in prose may simply not exist; only cited images say so.
            phase = reference.kind == .explicit ? .unavailable : .hidden
        case .failed:
            if case .loaded = phase { return }
            phase = reference.kind == .explicit ? .unavailable : .hidden
        }
    }

    /// User-initiated: fetch the best quality and hand it to the system viewer.
    private func openFullImage() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            quickLookURL = await loader.fullImageFile(
                seq: seq,
                ref: reference.ref,
                name: reference.displayName
            )
        }
    }
}
