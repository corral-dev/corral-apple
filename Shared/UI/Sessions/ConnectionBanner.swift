import SwiftUI

/// Session-list connection status: one caption line in the first group header
/// (status dot + text; host name lives in the nav title).
struct ConnectionBanner: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let state: AppModel.ConnectionState
    var transport: ConnectionTransport?

    var body: some View {
        HStack(spacing: Space.sm * interfaceScale) {
            // Same status vocabulary as the session rows: one small colored dot.
            Circle()
                .fill(dotColor)
                .interfaceFrame(width: TouchTarget.attentionDot, height: TouchTarget.attentionDot)
                .accessibilityHidden(true)

            statusText
                .interfaceFont(Typography.connection)
                .foregroundStyle(Color.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            if showsProgress {
                ProgressView()
                    .interfaceControlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: Text {
        if case let .failed(message) = state { return Text(message) }
        return Text(statusLabel)
    }

    private var showsProgress: Bool {
        switch state {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private var dotColor: Color {
        switch state {
        case .connected: Palette.attentionWorking
        case .connecting, .reconnecting: Palette.attentionWaiting
        case .failed: Palette.attentionUnread
        case .disconnected: Color.secondary
        }
    }

    private var statusLabel: LocalizedStringKey {
        switch state {
        case .connected:
            switch transport {
            case .local: "connection.connected_local"
            case .relay: "connection.connected_relay"
            case nil: "connection.connected"
            }
        case .connecting: "connection.connecting"
        case .reconnecting: "connection.reconnecting"
        case .failed: "connection.failed"
        case .disconnected: "connection.disconnected"
        }
    }
}
