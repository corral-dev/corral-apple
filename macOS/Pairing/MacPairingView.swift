import AppKit
import SwiftUI

/// Pairing on the Mac. This Mac first: connect, or install Corral and connect,
/// in place. Another computer: run the command there, then paste the pairing
/// link (or open a `corral://` link, handled by the window).
struct MacPairingView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var isSheet = false

    @State private var link = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var copiedCommand = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var localSetup: MacLocalHostSetup

    init(isSheet: Bool = false, localSetup: MacLocalHostSetup = MacLocalHostSetup()) {
        self.isSheet = isSheet
        _localSetup = State(initialValue: localSetup)
    }

    #if DEBUG
    init(
        isSheet: Bool = false,
        localSetup: MacLocalHostSetup,
        inspectionLink: String = "",
        inspectionError: String? = nil
    ) {
        self.isSheet = isSheet
        _localSetup = State(initialValue: localSetup)
        _link = State(initialValue: inspectionLink)
        _errorMessage = State(initialValue: inspectionError)
    }
    #endif

    private static let pairCommand = "corral remote pair"

    private var canPair: Bool {
        !isPairing && !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var prominentForeground: Color {
        activeState == .inactive ? .primary : Palette.onAccent
    }

    var body: some View {
        Group {
            if isSheet {
                contentColumn
                    .interfacePadding(Space.xl)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        contentColumn
                            .interfaceFrame(maxWidth: 440)
                            .interfacePadding(Space.xxl)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .background(PairingSurface.page)
        .focusEffectDisabled()
        .task { await localSetup.refresh(pairedHostIDs: pairedHostIDs) }
        .onChange(of: MacCLISync.shared.lastSyncCompletionSerial) { _, _ in
            Task { await localSetup.refresh(pairedHostIDs: pairedHostIDs) }
        }
        .onDisappear { copyResetTask?.cancel() }
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: Space.lg * interfaceScale) {
            headerRow
            if localSetup.state != .hidden {
                thisMacCard
            }
            otherComputerSection
            footerRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: Space.md * interfaceScale) {
            MachineIconTile(size: 32)
            Text("mac.pairing.title")
                .interfaceFont(.title2.weight(.semibold))
            Spacer(minLength: Space.sm * interfaceScale)
            if isSheet {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .interfaceFont(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .keyboardShortcut(.cancelAction)
                .help(Text("action.cancel"))
                .accessibilityLabel(Text("action.cancel"))
            }
        }
    }

    /// One compact card row for setting up or pairing this Mac directly.
    @ViewBuilder
    private var thisMacCard: some View {
        PairingCard {
            Group {
                switch localSetup.state {
                case .checking, .hidden:
                    HStack(spacing: Space.sm * interfaceScale) {
                        Text("mac.pairing.this_mac")
                            .interfaceFont(.headline)
                        Spacer(minLength: Space.sm * interfaceScale)
                        ProgressView().interfaceControlSize(.small)
                    }
                case .ready(let corral):
                    HStack(spacing: Space.sm * interfaceScale) {
                        Text("mac.pairing.this_mac")
                            .interfaceFont(.headline)
                        Spacer(minLength: Space.sm * interfaceScale)
                        Button("mac.pairing.connect") {
                            localSetup.connect(corral: corral, appModel: appModel, onPaired: finishLocalPairing)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .foregroundStyle(prominentForeground)
                        .accessibilityLabel(Text("mac.pairing.connect_this_mac"))
                    }
                case .needsInstall(let brew):
                    HStack(spacing: Space.sm * interfaceScale) {
                        Text("mac.pairing.this_mac")
                            .interfaceFont(.headline)
                        Spacer(minLength: Space.sm * interfaceScale)
                        Button("mac.pairing.install_connect") {
                            localSetup.install(brew: brew, appModel: appModel, onPaired: finishLocalPairing)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .foregroundStyle(prominentForeground)
                        .accessibilityLabel(Text("mac.pairing.install_corral"))
                    }
                case .needsScriptInstall:
                    HStack(spacing: Space.sm * interfaceScale) {
                        Text("mac.pairing.this_mac")
                            .interfaceFont(.headline)
                        Spacer(minLength: Space.sm * interfaceScale)
                        Button("mac.pairing.install_connect") {
                            localSetup.installWithScript(appModel: appModel, onPaired: finishLocalPairing)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .foregroundStyle(prominentForeground)
                        .accessibilityLabel(Text("mac.pairing.install_corral"))
                    }
                case .needsHomebrew:
                    VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
                        HStack(spacing: Space.sm * interfaceScale) {
                            Text("mac.pairing.this_mac")
                                .interfaceFont(.headline)
                            Spacer(minLength: Space.sm * interfaceScale)
                            Link("mac.pairing.get_homebrew", destination: MacLocalHostSetup.homebrewURL)
                                .interfaceFont(.callout.weight(.medium))
                                .tint(Palette.accent)
                                .foregroundStyle(Palette.accent)
                            Button("mac.pairing.check_again") {
                                Task { await localSetup.refresh(pairedHostIDs: pairedHostIDs) }
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("mac.pairing.needs_homebrew")
                            .interfaceFont(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .running(let step):
                    HStack(spacing: Space.sm * interfaceScale) {
                        ProgressView().interfaceControlSize(.small)
                        Text(step == .installing ? "mac.pairing.installing" : "mac.pairing.connecting")
                            .interfaceFont(.headline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Space.sm * interfaceScale)
                        Button("action.cancel") { localSetup.cancel(pairedHostIDs: pairedHostIDs) }
                            .buttonStyle(.bordered)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
                        HStack(spacing: Space.sm * interfaceScale) {
                            Text("mac.pairing.this_mac")
                                .interfaceFont(.headline)
                            Spacer(minLength: Space.sm * interfaceScale)
                            Button("action.retry") {
                                Task { await localSetup.refresh(pairedHostIDs: pairedHostIDs) }
                            }
                            .buttonStyle(.bordered)
                        }
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .interfaceFont(.callout)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .interfacePadding(.horizontal, Space.base)
            .interfacePadding(.vertical, Space.md)
            .interfaceFrame(minHeight: 56)
        }
    }

    private var otherComputerSection: some View {
        VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
            if localSetup.state != .hidden {
                Text("mac.pairing.other_computer")
                    .interfaceFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .interfacePadding(.leading, Space.xs)
            }
            PairingCard {
                VStack(alignment: .leading, spacing: Space.md * interfaceScale) {
                    commandWell
                    linkInputRow
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .interfaceFont(.callout)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .interfacePadding(Space.md)
            }
        }
    }

    private var commandWell: some View {
        let shape = ConcentricRectangle(
            corners: .concentric(minimum: .fixed(Radius.sm * interfaceScale)),
            isUniform: true
        )
        return HStack(spacing: Space.sm * interfaceScale) {
            Text(verbatim: Self.pairCommand)
                .interfaceFont(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: Space.sm * interfaceScale)
            Button {
                copyCommand()
            } label: {
                Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                    .interfaceFont(.callout.weight(.medium))
                    .foregroundStyle(copiedCommand ? Palette.accent : .secondary)
                    .interfaceFrame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .help(Text(copiedCommand ? "action.copied" : "action.copy"))
            .accessibilityLabel(Text(copiedCommand ? "action.copied" : "action.copy"))
        }
        .interfacePadding(.horizontal, Space.md)
        .interfacePadding(.vertical, Space.sm)
        .background(PairingSurface.well, in: shape)
        .overlay(shape.stroke(PairingSurface.wellBorder(for: colorScheme), lineWidth: 0.5))
        .clipShape(shape)
    }

    private var linkInputRow: some View {
        let inputShape = ConcentricRectangle(
            corners: .concentric(minimum: .fixed(Radius.sm * interfaceScale)),
            isUniform: true
        )
        return HStack(spacing: Space.sm * interfaceScale) {
            TextField("mac.pairing.link_placeholder", text: $link)
                .textFieldStyle(.plain)
                .interfaceFont(.body.monospaced())
                .autocorrectionDisabled()
                .onSubmit(startPairing)
                .disabled(isPairing)
                .focusEffectDisabled()
                .interfacePadding(.horizontal, Space.md)
                .interfacePadding(.vertical, 5)
                .background(PairingSurface.inputWell, in: inputShape)
                .overlay(inputShape.stroke(PairingSurface.inputBorder(for: colorScheme), lineWidth: 0.5))
                .clipShape(inputShape)

            PasteButton(supportedContentTypes: [.url, .plainText]) { @Sendable providers in
                MacPastedLinkLoader.load(from: providers) { text in
                    Task { @MainActor in
                        link = text
                        startPairing()
                    }
                }
            }
            .labelStyle(.titleOnly)
            .tint(.secondary)
            .disabled(isPairing)

            pairActionButton
        }
    }

    @ViewBuilder
    private var pairActionButton: some View {
        if canPair {
            Button(action: startPairing) {
                pairButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .foregroundStyle(prominentForeground)
            .keyboardShortcut(.defaultAction)
        } else {
            Button(action: startPairing) {
                pairButtonLabel
            }
            .buttonStyle(.bordered)
            .disabled(true)
        }
    }

    @ViewBuilder
    private var pairButtonLabel: some View {
        if isPairing {
            ProgressView().interfaceControlSize(.small)
        } else {
            Text("mac.pairing.pair")
        }
    }

    private var footerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md * interfaceScale) {
                trustCaption
                Spacer(minLength: Space.sm * interfaceScale)
                installGuideLink
            }
            VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                trustCaption
                installGuideLink
            }
        }
        .interfacePadding(.horizontal, Space.xs)
    }

    private var trustCaption: some View {
        Text("mac.pairing.trust")
            .interfaceFont(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var installGuideLink: some View {
        Button {
            openURL(CorralLinks.installGuide)
        } label: {
            HStack(spacing: 3 * interfaceScale) {
                Text("mac.pairing.install_cli")
                Image(systemName: "arrow.up.right")
                    .interfaceFont(.caption2.weight(.semibold))
            }
            .interfaceFont(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }

    private var pairedHostIDs: Set<String> { Set(appModel.hosts.map(\.hostID)) }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.pairCommand, forType: .string)
        copiedCommand = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedCommand = false
        }
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
                errorMessage = ConnectionFailureMessage.text(for: error)
            }
        }
    }
}

/// Elevated grouped card with a single outer curvature and concentric container shape.
private struct PairingCard<Content: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20 * interfaceScale, style: .continuous)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PairingSurface.card, in: shape)
            .overlay(shape.strokeBorder(PairingSurface.cardBorder(for: colorScheme), lineWidth: 0.5))
            .shadow(
                color: colorScheme == .dark ? .clear : Color.black.opacity(0.04),
                radius: 8,
                y: 2
            )
            .containerShape(shape)
    }
}

/// Appearance-aware macOS grouped surfaces derived from system window/control
/// colours so cards and recessed wells separate cleanly in light and dark modes.
private enum PairingSurface {
    static let page = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? .windowBackgroundColor
            : (NSColor.windowBackgroundColor.blended(withFraction: 0.045, of: .black) ?? .windowBackgroundColor)
    })

    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? (NSColor.windowBackgroundColor.blended(withFraction: 0.075, of: .white) ?? .controlBackgroundColor)
            : .controlBackgroundColor
    })

    static let well = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? .windowBackgroundColor
            : (NSColor.windowBackgroundColor.blended(withFraction: 0.045, of: .black) ?? .windowBackgroundColor)
    })

    static let inputWell = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? (NSColor.windowBackgroundColor.blended(withFraction: 0.02, of: .white) ?? .windowBackgroundColor)
            : .controlBackgroundColor
    })

    static func cardBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.11) : Color.primary.opacity(0.08)
    }

    static func wellBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.07)
    }

    static func inputBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.15) : Color.primary.opacity(0.13)
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
