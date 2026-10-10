#if os(iOS)
import SwiftUI

struct HostListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showPairing = false
    #if DEBUG
    @State private var showNotificationSettings = false
    #endif

    var body: some View {
        Group {
            if appModel.hosts.isEmpty {
                emptyState
            } else {
                List(appModel.hosts) { host in
                    NavigationLink(value: host) {
                        HostRow(host: host)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationDestination(for: HostInfo.self) { host in
                    SessionListView(host: host)
                }
            }
        }
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
        #if DEBUG
        .sheet(isPresented: $showNotificationSettings) {
            if let host = appModel.hosts.first {
                NavigationStack {
                    HostSettingsView(host: host)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("action.done") { showNotificationSettings = false }
                        } }
                }
                .task { if !appModel.isConnected(to: host) { await appModel.connect(to: host) } }
            }
        }
        #endif
        .onAppear {
            appModel.refreshHosts()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectNotifications") {
                showNotificationSettings = true
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectPairing") {
                showPairing = true
            }
        }
        .task {
            guard !appModel.hosts.isEmpty else { return }
            await appModel.connectSelectedHost()
        }
    }

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
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct HostRow: View {
    let host: HostInfo

    var body: some View {
        HStack(spacing: Space.md) {
            MachineIconTile(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(host.hostID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }
}
#endif
