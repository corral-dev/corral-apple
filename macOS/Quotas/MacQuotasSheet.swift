import SubswapQuotaUI
import SwiftUI

@MainActor
struct MacQuotasSheet: View {
    let host: HostInfo
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var feed: HostQuotaFeed

    init(host: HostInfo) {
        self.host = host
        _feed = State(initialValue: HostQuotaFeed(host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("quotas.title")
                        .font(.title3.weight(.semibold))
                    Text(host.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.sm)
                Button {
                    Task { await feed.manualRefresh() }
                } label: {
                    if feed.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.medium))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(feed.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .help(Text("quotas.refresh"))
                .accessibilityLabel(Text("quotas.refresh"))

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .keyboardShortcut(.cancelAction)
                .help(Text("action.dismiss"))
                .accessibilityLabel(Text("action.dismiss"))
            }
            .padding(.horizontal, DashboardSpacing.page)
            .padding(.vertical, 14)

            Divider()

            CorralQuotasContentView(feed: feed, ringSize: 64)
        }
        .background(RingSurface.page)
        .frame(width: 880, height: 600)
        .task(id: host.hostID) {
            if feed.host.hostID != host.hostID {
                feed.deactivate()
                feed = HostQuotaFeed(host: host)
            }
            await feed.activate(appModel: appModel)
        }
        .onDisappear {
            feed.deactivate()
        }
    }
}
