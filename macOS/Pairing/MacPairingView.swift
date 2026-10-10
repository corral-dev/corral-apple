import SwiftUI

/// Pairing on the Mac: the computer-side command, then paste the link it prints
/// (or click a `corral://` link, handled by the window). A Mac has no camera
/// scanning step; pasting the link is the primary path.
struct MacPairingView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var link = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Space.xl * interfaceScale) {
            MachineIconTile(size: 72)
            VStack(spacing: Space.sm * interfaceScale) {
                Text("mac.pairing.title")
                    .interfaceFont(.title2.weight(.semibold))
                Text("mac.pairing.description")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(verbatim: "corral remote pair")
                    .interfaceFont(.body.monospaced())
                    .textSelection(.enabled)
                    .interfacePadding(.horizontal, Space.md)
                    .interfacePadding(.vertical, Space.sm)
                    .background(Palette.codeSurface, in: RoundedRectangle(cornerRadius: Radius.sm * interfaceScale, style: .continuous))
            }
            VStack(spacing: Space.md * interfaceScale) {
                HStack(spacing: Space.sm * interfaceScale) {
                    TextField("mac.pairing.link_placeholder", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(startPairing)
                        .disabled(isPairing)
                    PasteButton(supportedContentTypes: [.url, .plainText]) { @Sendable providers in
                        MacPastedLinkLoader.load(from: providers) { text in
                            Task { @MainActor in
                                link = text
                                startPairing()
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(isPairing)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .interfaceFont(.callout)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.md * interfaceScale) {
                    if isSheet {
                        Button("action.cancel", role: .cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    Button(action: startPairing) {
                        if isPairing {
                            ProgressView().interfaceControlSize(.small)
                        } else {
                            Text("mac.pairing.pair")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isPairing || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interfaceFrame(maxWidth: 420)
            Text("mac.pairing.trust")
                .interfaceFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .interfaceFrame(maxWidth: 420)
        }
        .interfacePadding(Space.xxl)
        .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func startPairing() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPairing else { return }
        isPairing = true
        errorMessage = nil
        Task {
            defer { isPairing = false }
            do {
                let payload = try PairingPayload.parse(string: trimmed)
                _ = try await appModel.completePairing(payload, deviceName: UIDeviceName.current)
                link = ""
                if isSheet { dismiss() }
            } catch is CancellationError {
                // Superseded by the window's own connection once the machine appears.
                link = ""
                if isSheet { dismiss() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Loads pasted text off the main actor (PasteButton calls back on a background queue).
nonisolated enum MacPastedLinkLoader {
    static func load(from providers: [NSItemProvider], deliver: @escaping @Sendable (String) -> Void) {
        guard let provider = providers.first else { return }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { deliver(url.absoluteString) }
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                if let text { deliver(text) }
            }
        }
    }
}
