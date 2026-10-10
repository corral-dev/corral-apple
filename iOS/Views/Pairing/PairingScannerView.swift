#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Full-bleed camera pairing page. The camera is the page; the only manual
/// route is the native paste button (see UI design knowledge base,
/// "Machines list and pairing screen").
struct PairingScannerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cameraAccess: CameraAccess = .unknown
    @State private var isPairing = false
    @State private var errorMessage: String?
    /// The link that just failed; the live scanner ignores it briefly so the
    /// same on-screen code does not loop the error.
    @State private var failedLink: String?
    @State private var hapticScope = HapticScope()
    @State private var scanAttempts: [String: UUID] = [:]

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = Self.viewfinderSide(for: proxy.size)
                ZStack {
                    cameraLayer
                    ScrollView {
                        VStack(spacing: Space.xl) {
                            header
                            if cameraAccess == .denied {
                                cameraDeniedContent
                            } else {
                                viewfinder(side: side)
                            }
                            errorBanner
                            Spacer(minLength: Space.base)
                            footer
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.top, Space.sm)
                        .padding(.bottom, Space.base)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    // Behind the text but above the camera sibling.
                    .backgroundPreferenceValue(ViewfinderAnchorKey.self) { anchor in
                        GeometryReader { geometry in
                            ViewfinderDim(hole: anchor.map { geometry[$0] }, radius: Self.viewfinderRadius)
                                .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    }
                }
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("action.cancel"))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .presentationBackground(.black)
            .hapticScope(hapticScope)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isPairing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: errorMessage)
        .task {
            await requestCamera()
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectPairingError") {
                startPairing(with: "corral://inspect")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await requestCamera() }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var cameraLayer: some View {
        if cameraAccess == .granted {
            QRScannerRepresentable(
                isScanning: !isPairing,
                ignoredValue: failedLink
            ) { value in
                    startPairing(with: value, automaticScan: true)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(spacing: Space.sm) {
            Text("pairing.scan.title")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("pairing.scan.instruction")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Space.base)
    }

    private func viewfinder(side: CGFloat) -> some View {
        ZStack {
            if isPairing {
                RoundedRectangle(cornerRadius: Self.viewfinderRadius, style: .continuous)
                    .fill(Color.black.opacity(0.5))
                VStack(spacing: Space.md) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("pairing.in_progress")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
            }
            ViewfinderCorners(radius: Self.viewfinderRadius, arm: 30)
                .stroke(
                    isPairing ? Palette.brandYellow : Color.white,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: side, height: side)
        .anchorPreference(key: ViewfinderAnchorKey.self, value: .bounds) { $0 }
        .accessibilityElement(children: .combine)
    }

    private var cameraDeniedContent: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("pairing.camera_denied")
                .font(.headline)
                .foregroundStyle(.white)
            Text("pairing.camera_denied.hint")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            Button("action.open_settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Palette.accent)
            .foregroundStyle(Palette.onAccent)
            .padding(.top, Space.xs)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Space.xl)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(Palette.dangerFill, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .transition(.opacity)
        }
    }

    private var footer: some View {
        VStack(spacing: Space.md) {
            Text("pairing.paste.hint")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
            PasteButton(supportedContentTypes: [.url, .plainText]) { @Sendable providers in
                PastedLinkLoader.load(from: providers) { text in
                    Task { @MainActor in startPairing(with: text) }
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Palette.accent)
            .disabled(isPairing)
            Text("pairing.scan.trust")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, Space.sm)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Behavior

    private static let viewfinderRadius: CGFloat = 28

    private static func viewfinderSide(for size: CGSize) -> CGFloat {
        max(180, min(size.width - 2 * 56, 290))
    }

    private func requestCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAccess = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAccess = granted ? .granted : .denied
        default:
            cameraAccess = .denied
        }
    }

    private func startPairing(with raw: String, automaticScan: Bool = false) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPairing else { return }
        if automaticScan, (try? PairingPayload.parse(string: trimmed)) == nil {
            failedLink = trimmed
            return
        }
        let operationID: UUID
        if automaticScan {
            operationID = scanAttempts[trimmed] ?? hapticScope.beginOperation()
            scanAttempts[trimmed] = operationID
            HapticFeedback.shared.emit(.committed, operationID: operationID, scope: hapticScope)
        } else {
            operationID = hapticScope.beginOperation()
        }
        // Set synchronously so the live scanner pauses before the next frame.
        isPairing = true
        errorMessage = nil
        Task { await pair(link: trimmed, operationID: operationID) }
    }

    private func pair(link: String, operationID: UUID) async {
        do {
            let payload = try PairingPayload.parse(string: link)
            _ = try await appModel.completePairing(payload, deviceName: UIDeviceName.current)
            isPairing = false
            HapticFeedback.shared.emit(.success, operationID: operationID, scope: hapticScope)
            dismiss()
        } catch {
            failedLink = link
            errorMessage = error.localizedDescription
            HapticFeedback.shared.failure(error, operationID: operationID, scope: hapticScope)
            isPairing = false
            // A transient failure (network) can be retried by holding the
            // camera on the same code once this short quiet period ends.
            try? await Task.sleep(for: .seconds(3))
            if failedLink == link { failedLink = nil }
        }
    }
}

private enum CameraAccess {
    case unknown, granted, denied
}

// MARK: - Viewfinder geometry

private struct ViewfinderAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Full-screen dim with one rounded-square hole (filled even-odd).
nonisolated private struct ViewfinderDim: Shape {
    let hole: CGRect?
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

/// Four rounded corner brackets sitting on the viewfinder edge, sharing its radius.
nonisolated private struct ViewfinderCorners: Shape {
    let radius: CGFloat
    let arm: CGFloat

    func path(in rect: CGRect) -> Path {
        let reach = radius + arm
        var path = Path()
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY + reach), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + reach, y: rect.minY)),
            (CGPoint(x: rect.maxX - reach, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + reach)),
            (CGPoint(x: rect.maxX, y: rect.maxY - reach), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - reach, y: rect.maxY)),
            (CGPoint(x: rect.minX + reach, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - reach)),
        ]
        for (start, corner, end) in corners {
            path.move(to: start)
            path.addArc(tangent1End: corner, tangent2End: end, radius: radius)
            path.addLine(to: end)
        }
        return path
    }
}

// MARK: - Paste

/// Loads pasted text off the main actor. The handler must stay `@Sendable`:
/// Swift 6 traps when PasteButton calls a main-actor-inferred closure from
/// its background queue.
nonisolated private enum PastedLinkLoader {
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

// MARK: - 扫码

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    var isScanning: Bool
    var ignoredValue: String?
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {
        controller.onScan = onScan
        controller.ignoredValue = ignoredValue
        controller.setScanning(isScanning)
    }
}

/// Owns the capture session and runs start/stop off the main thread.
nonisolated private final class CaptureSessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.x0c.corral.pairing.capture")

    func start() {
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var ignoredValue: String?
    private let runner = CaptureSessionRunner()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// Keeps the preview live while pairing; only detection pauses.
    private var paused = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        let session = runner.session
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        runner.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        runner.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func setScanning(_ scanning: Bool) {
        paused = !scanning
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !paused,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              URL(string: value)?.scheme?.lowercased() == "corral",
              value != ignoredValue
        else { return }
        paused = true
        onScan?(value)
    }
}
#endif
