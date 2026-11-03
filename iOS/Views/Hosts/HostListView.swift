#if os(iOS)
import SwiftUI

/// The machines page shown only while no machine is paired: the pairing
/// empty state. With a paired machine the adaptive split opens straight on
/// its sessions and machines switch from the title menu (owner decision 2026-11-01).
struct HostListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showPairing = false

    var body: some View {
        emptyState
            .navigationTitle("nav.hosts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPairing = true
                    } label: {
                        Label("hosts.pair", systemImage: "qrcode.viewfinder")
                    }
                }
            }
            .sheet(isPresented: $showPairing) {
                PairingScannerView()
            }
            .onAppear {
                appModel.refreshHosts()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-CorralRenderEmptyHosts") {
                    renderEmptyStateForInspection()
                }
                #endif
            }
    }

    #if DEBUG
    /// Offscreen captures of the empty machine list (light, dark) for
    /// acceptance while the simulator display is unavailable.
    private func renderEmptyStateForInspection() {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: emptyState
                .frame(width: 393, height: 852)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale.current))
            renderer.scale = 3
            let url = FileManager.default.temporaryDirectory
                .appending(path: "corral-empty-hosts-\(scheme == .dark ? "dark" : "light").png")
            try? renderer.uiImage?.pngData()?.write(to: url)
        }
    }
    #endif

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("hosts.empty.title")
            } icon: {
                MachineIconTile(size: 72)
                    .padding(.bottom, Space.xs)
            }
        } description: {
            Text("hosts.empty.description")
        } actions: {
            Button("hosts.pair") { showPairing = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Palette.accent)
                .foregroundStyle(Palette.onAccent)
            Link("pairing.install_guide", destination: CorralLinks.installGuide)
                .font(.callout)
                .tint(Palette.accent)
        }
        .background(Color(.systemGroupedBackground))
    }
}
#endif
