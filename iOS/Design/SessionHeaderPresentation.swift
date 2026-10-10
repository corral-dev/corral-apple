import SwiftUI

/// Conversation-header identity: title, assistant, one execution/connection
/// state, and the workspace short name (caption row, costs no extra height).
struct SessionHeaderModel: Equatable {
    var title: String
    var assistantName: String?
    var state: SessionHeaderState
    /// nil/empty when unknown: the caption falls back to localized Unknown.
    var workspaceName: String?
    /// Full display path for the workspace sheet (copyable). May be empty.
    var workspacePath: String?
    /// Owning machine display name for the workspace sheet. May be empty.
    var hostName: String?

    init(
        title: String,
        assistantName: String? = nil,
        state: SessionHeaderState,
        workspaceName: String? = nil,
        workspacePath: String? = nil,
        hostName: String? = nil
    ) {
        self.title = title
        self.assistantName = assistantName
        self.state = state
        self.workspaceName = workspaceName
        self.workspacePath = workspacePath
        self.hostName = hostName
    }
}

enum SessionHeaderState: Equatable {
    case running
    case needsReply
    case ready
    case ended
    case connecting
    case offline
    case updating
    case terminal

    var labelKey: LocalizedStringResource {
        switch self {
        case .running: "sessions.attention.working"
        case .needsReply: "session.detail.header.needs_reply"
        case .ready: "session.detail.header.ready"
        case .ended: "session.detail.header.ended"
        case .connecting: "connection.connecting"
        case .offline: "session.detail.header.offline"
        case .updating: "session.detail.header.updating"
        case .terminal: "session.detail.terminal"
        }
    }

    var markerColor: Color {
        switch self {
        case .running: Palette.attentionWorking
        case .needsReply: Palette.attentionWaiting
        case .ready, .ended, .connecting, .offline, .updating, .terminal:
            Color.secondary
        }
    }
}

enum SessionHeaderPresentation {
    /// Display-only title for the conversation header and prompt sheet.
    static func title(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "session.detail.untitled") : trimmed
    }

    static func make(
        rawTitle: String,
        runtime: String?,
        live: Bool,
        attention: AttentionKind,
        conversationReady: Bool,
        connection: AppModel.ConnectionState,
        showsTerminal: Bool,
        workspaceName: String? = nil,
        workspacePath: String? = nil,
        hostName: String? = nil
    ) -> SessionHeaderModel {
        let assistant = Palette.runtimeDisplayName(runtime)
        return SessionHeaderModel(
            title: title(from: rawTitle),
            assistantName: assistant.isEmpty ? nil : assistant,
            state: resolveState(
                live: live,
                attention: attention,
                conversationReady: conversationReady,
                connection: connection,
                showsTerminal: showsTerminal
            ),
            workspaceName: workspaceName,
            workspacePath: workspacePath,
            hostName: hostName
        )
    }

    static func resolveState(
        live: Bool,
        attention: AttentionKind,
        conversationReady: Bool,
        connection: AppModel.ConnectionState,
        showsTerminal: Bool
    ) -> SessionHeaderState {
        switch connection {
        case .connecting, .reconnecting:
            return .connecting
        case .disconnected, .failed:
            return live ? .offline : .ended
        case .connected:
            break
        }

        if !conversationReady {
            return .updating
        }
        if showsTerminal {
            return .terminal
        }
        // Fresh attention from the open conversation wins over a stale !live flag.
        // Cursor sessions often keep a keepalive pane while list cache still says ended.
        switch attention {
        case .working:
            return .running
        case .waiting:
            return .needsReply
        case .none, .unread:
            break
        }
        if !live {
            return .ended
        }
        return .ready
    }
}
