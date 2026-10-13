import SwiftUI

/// Pairing on the Mac. This Mac first: connect, or install Corral with
/// Homebrew and connect, in place. Another computer: run the command there,
/// then paste the link it prints (or click a `corral://` link, handled by the
/// window). A Mac has no camera scanning step.
struct MacPairingView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var link = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var localSetup: MacLocalHostSetup

    init(isSheet: Bool = false, localSetup: MacLocalHostSetup = MacLocalHostSetup()) {
        self.isSheet = isSheet
        _localSetup = State(initialValue: localSetup)
    }

    private static let pairCommand = "corral remote pair"

    var body: some View {
        VStack(spacing: Space.xl * interfaceScale) {
            MachineIconTile(size: 72)
            Text("mac.pairing.title")
                .interfaceFont(.title2.weight(.semibold))
            if localSetup.state != .hidden {
                thisMacSection
                Divider().interfaceFrame(maxWidth: 420)
            }
            VStack(spacing: Space.sm * interfaceScale) {
                if localSetup.state != .hidden {
                    Text("mac.pairing.other_computer")
                        .interfaceFont(.headline)
                }
                Text("mac.pairing.description")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: Space.xs * interfaceScale) {
                    Text(verbatim: Self.pairCommand)
                        .interfaceFont(.body.monospaced())
                        .textSelection(.enabled)
                    Button("action.copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.pairCommand, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(Text("action.copy"))
                }
                .interfacePadding(.horizontal, Space.md)
                .interfacePadding(.vertical, Space.sm)
                .background(Palette.codeSurface, in: RoundedRectangle(cornerRadius: Radius.sm * interfaceScale, style: .continuous))
                Link("mac.pairing.install_guide", destination: MacLocalHostSetup.installGuideURL)
                    .interfaceFont(.callout)
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
        .task { await localSetup.refresh(pairedHostIDs: pairedHostIDs) }
    }

    private var pairedHostIDs: Set<String> { Set(appModel.hosts.map(\.hostID)) }

    /// One action for this Mac, chosen by what is already installed.
    @ViewBuilder
    private var thisMacSection: some View {
        VStack(spacing: Space.sm * interfaceScale) {
            Text("mac.pairing.this_mac")
                .interfaceFont(.headline)
            switch localSetup.state {
            case .checking, .hidden:
                ProgressView().interfaceControlSize(.small)
            case .ready(let corral):
                Button("mac.pairing.connect_this_mac") {
                    localSetup.connect(corral: corral, appModel: appModel, onPaired: finishLocalPairing)
                }
                .buttonStyle(.borderedProminent)
            case .needsInstall(let brew):
                Button("mac.pairing.install_corral") {
                    localSetup.install(brew: brew, appModel: appModel, onPaired: finishLocalPairing)
                }
                .buttonStyle(.borderedProminent)
            case .needsHomebrew:
                Text("mac.pairing.needs_homebrew")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: Space.md * interfaceScale) {
                    Link("mac.pairing.get_homebrew", destination: MacLocalHostSetup.homebrewURL)
                    Button("mac.pairing.check_again") {
                        Task { await localSetup.refresh(pairedHostIDs: pairedHostIDs) }
                    }
                }
            case .running(let step):
                HStack(spacing: Space.sm * interfaceScale) {
                    ProgressView().interfaceControlSize(.small)
                    Text(step == .installing ? "mac.pairing.installing" : "mac.pairing.connecting")
                        .foregroundStyle(.secondary)
                    Button("action.cancel") { localSetup.cancel(pairedHostIDs: pairedHostIDs) }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .interfaceFont(.callout)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("action.retry") {
                    Task { await localSetup.refresh(pairedHostIDs: pairedHostIDs) }
                }
            }
        }
        .interfaceFrame(maxWidth: 420)
    }

    private func finishLocalPairing() {
        if isSheet { dismiss() }
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
