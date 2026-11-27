import SubswapQuotaCore
import SubswapQuotaUI
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
struct CorralQuotasContentView: View {
    let feed: HostQuotaFeed
    var ringSize: CGFloat = 64

    @State private var copiedInstallCommand = false

    private static let installCommand = "brew install x0c/tap/subswap"

    var body: some View {
        switch feed.state {
        case .loading:
            SubswapQuotaPlaceholderView(ringSize: ringSize)
        case .hostUnsupported:
            ContentUnavailableView(
                "quotas.unsupported.title",
                systemImage: "arrow.up.circle",
                description: Text("quotas.unsupported.body")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .subswapNotInstalled:
            ContentUnavailableView {
                Label("quotas.not_installed.title", systemImage: "gauge.with.dots.needle.0percent")
            } description: {
                Text("quotas.not_installed.body")
            } actions: {
                VStack(spacing: 10) {
                    Text(Self.installCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button {
                        copyInstallCommand()
                    } label: {
                        Label(
                            copiedInstallCommand ? "quotas.not_installed.copied" : "action.copy",
                            systemImage: copiedInstallCommand ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView(
                "quotas.empty.title",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("quotas.empty.body")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("quotas.error.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("action.retry") {
                    Task { await feed.manualRefresh() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(snapshot):
            ScrollView {
                SubswapQuotaGrid(snapshot: snapshot, ringSize: ringSize, interaction: .readOnly)
                    .padding(DashboardSpacing.page)
            }
            .background(RingSurface.page)
            .refreshable {
                await feed.manualRefresh()
            }
        }
    }

    private func copyInstallCommand() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
        #else
        UIPasteboard.general.string = Self.installCommand
        #endif
        copiedInstallCommand = true
    }
}
