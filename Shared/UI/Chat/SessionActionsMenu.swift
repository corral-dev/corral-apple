import SwiftUI

/// 会话详情页右上复制/接力菜单的状态机与调用。
///
/// Copy, handoff and capability-gated native restart actions.
/// 协议约定（与 CLI `session.copy` 并行实现对齐，已锁）：
/// - 复制：`session.copy`，参数 `{"key": <源 key>}`，成功 `d = {"session": <SessionSummary>}`；
/// - 接力：`session.handoff`，参数 `{"key": <源 key>, "runtime": <目标 id>}`，
///   成功 `d = {"session": <SessionSummary>}`（与 `session.new`/`resume` 同形）；
/// - 失败透服务端 `RemoteCallError.message`，缺 message 走 `error.unknown`；
/// - 无历史/占位卡失败时原会话不动（只在这里报错，不改列表/详情）。
/// 菜单状态规则（产品裁定，已锁）：
/// - 只读配对（hello `access == "readonly"`）隐藏远程操作；本地显示模式可切换；旧开发机无 `access` 字段按 full 显示；
/// - `runtimes.list` 缺 `available` 按可用处理，`available == false` 直接隐藏该行（不是置灰）；
/// - 离线 / client 未 ready 时远程操作禁用；本地显示模式不受此限制；
/// - Kimi 作目标必须写明：`-p` 非交互跑完即退出，后续回电脑 `kimi -c` 继续，不承诺持续交互。
enum SessionActionsMenu {
    static let forkSymbol = "arrow.triangle.branch"
    static let handoffSymbol = "arrowshape.turn.up.right"

    // MARK: - 纯状态机（可单测，不依赖 SwiftUI 环境）

    /// Remote actions visibility. Local display choices have a separate gate.
    static func isMenuVisible(access: String?) -> Bool {
        !isReadonly(access: access)
    }

    /// 只读配对判定：hello `access` 为 "readonly"（大小写/空白宽容）；
    /// 缺字段（旧开发机）按 full 处理。
    static func isReadonly(access: String?) -> Bool {
        (access ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "readonly"
    }

    /// Remote actions need a ready client. The caller also gates busy actions.
    static func isMenuEnabled(clientReady: Bool) -> Bool {
        clientReady
    }

    /// 接力子菜单行：过滤掉 `available == false`；缺字段（nil）按可用保留。
    /// 仅保留活跃 allowlist 内的运行时；dormant 兼容（如 kimi）不在接力菜单中出现。
    /// 含来源自身（同助手复制式接力合法）。
    static func handoffTargets(from runtimes: [RuntimeEntry]) -> [RuntimeEntry] {
        runtimes.filter { $0.isUsable && $0.isActive }
    }

    /// Kimi 作目标时的能力提示键（确认框内必须展示）。
    static func needsKimiNotice(runtimeID: String) -> Bool {
        runtimeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "kimi"
    }

    /// 服务端失败文案：透 `RemoteCallError.message`；缺 message 走 `error.unknown`。
    static func failureMessage(for error: Error) -> String {
        if let remote = error as? RemoteCallError, !remote.message.isEmpty {
            return remote.message
        }
        // Connection errors (not connected, host timeout, …) carry localized text.
        if let described = error as? LocalizedError, let text = described.errorDescription, !text.isEmpty {
            return text
        }
        return String(localized: String.LocalizationValue("error.unknown"))
    }

    /// 从 `session.copy` / `session.handoff` 成功载荷里解出新会话。
    /// `{"session": {...}}`；缺 `session` 时抛 `error.unknown` 文案的调用错误。
    static func decodeNewSession(from payload: Any) throws -> SessionSummary {
        guard let dict = payload as? [String: Any],
              let sessionDict = dict["session"] else {
            throw RemoteCallError(
                code: WireProtocol.eInternal,
                message: String(localized: String.LocalizationValue("error.unknown")),
                hint: ""
            )
        }
        return try RemoteJSONDecoder.decode(SessionSummary.self, from: sessionDict)
    }

    // MARK: - RPC 参数（与 CLI 并行实现锁定的约定）

    static func copyParams(sourceKey: String) -> [String: Any] {
        ["key": sourceKey]
    }

    static func handoffParams(sourceKey: String, targetRuntimeID: String) -> [String: Any] {
        ["key": sourceKey, "runtime": targetRuntimeID]
    }

    /// Decode compact share JSON returned by `session.export`.
    static func decodeExportJSON(from payload: Any) throws -> String {
        guard let dict = payload as? [String: Any],
              let json = dict["json"] as? String else {
            throw RemoteCallError(
                code: WireProtocol.eInternal,
                message: String(localized: String.LocalizationValue("error.unknown")),
                hint: ""
            )
        }
        return json
    }

    @MainActor
    static func exportJSON(sourceKey: String, client: RemoteClient) async throws -> String {
        let payload = try await client.call(
            WireProtocol.mSessionExport,
            params: copyParams(sourceKey: sourceKey)
        )
        return try decodeExportJSON(from: payload)
    }
}

// MARK: - SwiftUI 菜单视图

extension SessionDetailMode {
    var title: LocalizedStringKey {
        switch self {
        case .chat: "mac.pane.chat"
        case .terminal: "mac.pane.terminal"
        }
    }

    var switchTitle: LocalizedStringKey {
        self == .chat ? "mac.pane.switch_to_terminal" : "mac.pane.switch_to_chat"
    }
}

/// Shared single-session menu content used by both the detail More button and
/// the mobile session-list context menu.
@MainActor
struct SessionMenuItems: View {
    let session: SessionSummary
    var runtimes: [RuntimeEntry] = []
    var runtimesLoaded: Bool = false
    var runtimesLoading: Bool = false
    var runtimesError: String? = nil
    var onRetryRuntimes: () -> Void = {}
    var access: String?
    var clientReady: Bool
    var isBusy: Bool
    var supportsExport: Bool = false
    var supportsRestart: Bool = false
    var onPin: (() -> Void)? = nil
    var onOpenTerminal: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onHandoff: ((RuntimeEntry) -> Void)? = nil
    var onPendingHandoff: ((RuntimeEntry) -> Void)? = nil
    var onExport: (() -> Void)? = nil
    var onRestart: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    var onCopyPath: (() -> Void)? = nil
    var onRequestDelete: (() -> Void)? = nil
    var displayMode: Binding<SessionDetailMode>? = nil

    private var visible: Bool {
        SessionActionsMenu.isMenuVisible(access: access)
    }

    private var enabled: Bool {
        SessionActionsMenu.isMenuEnabled(clientReady: clientReady) && !isBusy
    }

    private var targets: [RuntimeEntry] {
        SessionActionsMenu.handoffTargets(from: runtimes)
    }

    private var isPinned: Bool {
        session.pinned == true || session.group?.pinned == true
    }

    private var workspacePath: String {
        SessionPresentation.fullWorkspacePath(from: session)
    }

    var body: some View {
        if let displayMode {
            Section {
                Button {
                    displayMode.wrappedValue = displayMode.wrappedValue.toggled
                } label: {
                    Label(displayMode.wrappedValue.switchTitle, systemImage: displayMode.wrappedValue.switchSymbol)
                }
            }
        }

        if visible, (onPin != nil || onOpenTerminal != nil) {
            Section {
                if let onPin {
                    Button(action: onPin) {
                        Label(
                            isPinned ? "sessions.action.unpin" : "sessions.action.pin",
                            systemImage: isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .disabled(!enabled)
                }
                if let onOpenTerminal {
                    Button(action: onOpenTerminal) {
                        Label("session.actions.open_terminal", systemImage: "terminal")
                    }
                    .disabled(!enabled)
                }
            }
        }

        if (visible && (onCopy != nil || onHandoff != nil || onRestart != nil || (session.live && onStop != nil)))
            || onExport != nil {
            Section {
                if visible {
                    if let onCopy {
                        copyButton(action: onCopy)
                    }
                    if let onHandoff {
                        handoffMenu(onHandoff: onHandoff)
                    }
                }
                if let onExport {
                    Button(action: onExport) {
                        Label("mac.session.export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!clientReady || !supportsExport || isBusy)
                }
                if visible {
                    if let onRestart {
                        Button(action: onRestart) {
                            Label(
                                supportsRestart ? "session.actions.restart" : "session.actions.restart.update_host",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(!enabled || !supportsRestart)
                    }
                    if session.live, let onStop {
                        Button(action: onStop) {
                            Label("sessions.action.stop", systemImage: "stop.fill")
                        }
                        .disabled(!enabled)
                    }
                }
            }
        }

        Section {
            Button {
                PlatformPasteboard.copy(workspacePath)
                onCopyPath?()
            } label: {
                Label("session.workspace.copy_path", systemImage: "folder")
            }
            .disabled(workspacePath.isEmpty)
        }

        if visible, let onRequestDelete {
            Section {
                Button(role: .destructive, action: onRequestDelete) {
                    Label("sessions.action.delete", systemImage: "trash")
                }
                .disabled(!enabled)
            }
        }
    }

    @ViewBuilder
    private func copyButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isBusy {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("session.actions.copy")
                }
            } else {
                Label("session.actions.copy", systemImage: SessionActionsMenu.forkSymbol)
            }
        }
        .disabled(!enabled || isBusy)
    }

    @ViewBuilder
    private func handoffMenu(onHandoff: @escaping (RuntimeEntry) -> Void) -> some View {
        Menu {
            if runtimesLoading {
                Text("session.actions.handoff.loading")
            } else if let runtimesError {
                Text(verbatim: runtimesError)
                Button("action.retry", systemImage: "arrow.clockwise", action: onRetryRuntimes)
            } else if !runtimesLoaded {
                Button("action.retry", systemImage: "arrow.clockwise", action: onRetryRuntimes)
            } else if targets.isEmpty {
                Text("session.actions.handoff.empty")
            } else {
                ForEach(targets) { target in
                    Button {
                        if SessionActionsMenu.needsKimiNotice(runtimeID: target.id),
                           let onPendingHandoff {
                            onPendingHandoff(target)
                        } else {
                            onHandoff(target)
                        }
                    } label: {
                        let name = target.name?.isEmpty == false
                            ? target.name!
                            : Palette.runtimeDisplayName(target.id)
                        Text(name.isEmpty ? target.id : name)
                    }
                    .disabled(!enabled)
                }
            }
        } label: {
            Label("session.actions.handoff", systemImage: SessionActionsMenu.handoffSymbol)
        }
        .disabled(!enabled)
    }
}

/// Top-trailing More menu uses a plain ellipsis with a 44-point target.
/// Busy remote actions never block local display switching or path copy.
@MainActor
struct SessionActionsMenuView: View {
    let session: SessionSummary
    /// 接力候选（含来源自身；调用方应在 runtimes.list 回来后传入，已做 available 过滤亦可）。
    var runtimes: [RuntimeEntry]
    /// Empty, pending and failed catalogs have distinct presentations.
    var runtimesLoaded: Bool = false
    var runtimesLoading: Bool = false
    var runtimesError: String? = nil
    var onRetryRuntimes: () -> Void = {}
    var access: String?
    var clientReady: Bool
    var isBusy: Bool
    var supportsExport: Bool = false
    var supportsRestart: Bool = false
    var onPin: (() -> Void)? = nil
    var onRestart: () -> Void = {}
    var onCopy: () -> Void
    var onHandoff: (RuntimeEntry) -> Void
    var onExport: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    var onCopyPath: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// Project terminal for the session's folder; nil hides the item (old host,
    /// or a platform that opens terminals elsewhere).
    var onOpenTerminal: (() -> Void)? = nil
    /// Local display selection is independent of remote mutation permissions.
    var displayMode: Binding<SessionDetailMode>? = nil

    @State private var pendingHandoff: RuntimeEntry?
    @State private var confirmDelete = false

    private var hasAnyEnabledEntry: Bool {
        displayMode != nil
            || !SessionPresentation.fullWorkspacePath(from: session).isEmpty
            || (clientReady && !isBusy)
    }

    var body: some View {
        Menu {
            SessionMenuItems(
                session: session,
                runtimes: runtimes,
                runtimesLoaded: runtimesLoaded,
                runtimesLoading: runtimesLoading,
                runtimesError: runtimesError,
                onRetryRuntimes: onRetryRuntimes,
                access: access,
                clientReady: clientReady,
                isBusy: isBusy,
                supportsExport: supportsExport,
                supportsRestart: supportsRestart,
                onPin: onPin,
                onOpenTerminal: onOpenTerminal,
                onCopy: onCopy,
                onHandoff: onHandoff,
                onPendingHandoff: { pendingHandoff = $0 },
                onExport: onExport,
                onRestart: onRestart,
                onStop: onStop,
                onCopyPath: onCopyPath,
                onRequestDelete: onDelete != nil ? { confirmDelete = true } : nil,
                displayMode: displayMode
            )
        } label: {
            Label("session.actions.menu", systemImage: "ellipsis")
        }
        .disabled(!hasAnyEnabledEntry)
        .interfaceFrame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
        .accessibilityHint(Text("session.actions.menu.hint"))
        .confirmationDialog(
            "session.actions.handoff.confirm_title",
            isPresented: Binding(
                get: { pendingHandoff != nil },
                set: { if !$0 { pendingHandoff = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("session.actions.handoff.confirm") {
                if let target = pendingHandoff {
                    pendingHandoff = nil
                    onHandoff(target)
                }
            }
            Button("action.cancel", role: .cancel) { pendingHandoff = nil }
        } message: {
            if let target = pendingHandoff {
                handoffConfirmMessage(for: target)
            }
        }
        .confirmationDialog(
            "sessions.delete_confirm.title",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("sessions.action.delete", role: .destructive) { onDelete?() }
            Button("action.cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func handoffConfirmMessage(for target: RuntimeEntry) -> some View {
        let name = target.name?.isEmpty == false
            ? target.name!
            : Palette.runtimeDisplayName(target.id)
        if SessionActionsMenu.needsKimiNotice(runtimeID: target.id) {
            Text("session.actions.handoff.kimi_notice")
        } else {
            Text(
                String(
                    localized: "session.actions.handoff.confirm_message",
                    defaultValue: "Start a new \(name) session from this conversation?"
                )
            )
        }
    }
}
