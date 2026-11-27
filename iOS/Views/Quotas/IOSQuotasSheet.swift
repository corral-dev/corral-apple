import SubswapQuotaUI
import SwiftUI

@MainActor
struct IOSQuotasSheet: View {
    let host: HostInfo
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var feed: HostQuotaFeed

    init(host: HostInfo) {
        self.host = host
        _feed = State(initialValue: HostQuotaFeed(host: host))
    }

    var body: some View {
        NavigationStack {
            CorralQuotasContentView(feed: feed, ringSize: 68)
                .navigationTitle("quotas.title")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await feed.manualRefresh() }
                        } label: {
                            Label("quotas.refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(feed.isRefreshing)
                        .accessibilityLabel(Text("quotas.refresh"))
                    }
                    ToolbarItem(placement: .corralTrailing) {
                        if #available(iOS 26.0, *) {
                            Button(role: .close) {
                                dismiss()
                            }
                            .accessibilityLabel(Text("action.dismiss"))
                        } else {
                            Button("action.done") {
                                dismiss()
                            }
                        }
                    }
                }
        }
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
