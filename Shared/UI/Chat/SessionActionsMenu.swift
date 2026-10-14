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
}

// MARK: - SwiftUI 菜单视图

enum SessionDetailMode: String, CaseIterable, Identifiable, Hashable {
    case chat
    case terminal

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .chat: "session.detail.chat"
        case .terminal: "session.detail.terminal"
        }
    }
}

/// Top-trailing More menu uses a plain ellipsis with a 44-point target.
/// Busy remote actions never block the local display picker.
@MainActor
struct SessionActionsMenuView: View {
    let session: SessionSummary
    /// 接力候选（含来源自身；调用方应在 runtimes.list 回来后传入，已做 available 过滤亦可）。
    var runtimes: [RuntimeEntry]
    var access: String?
    var clientReady: Bool
    var isBusy: Bool
    var supportsRestart: Bool = false
    var onRestart: () -> Void = {}
    var onCopy: () -> Void
    var onHandoff: (RuntimeEntry) -> Void
    /// Project terminal for the session's folder; nil hides the item (old host,
    /// or a platform that opens terminals elsewhere).
    var onOpenTerminal: (() -> Void)? = nil
    /// Local display selection is independent of remote mutation permissions.
    var displayMode: Binding<SessionDetailMode>? = nil

    @State private var pendingHandoff: RuntimeEntry?

    private var visible: Bool {
        SessionActionsMenu.isMenuVisible(access: access)
    }

    private var enabled: Bool {
        SessionActionsMenu.isMenuEnabled(clientReady: clientReady) && !isBusy
    }

    private var targets: [RuntimeEntry] {
        SessionActionsMenu.handoffTargets(from: runtimes)
    }

    var body: some View {
        if visible || displayMode != nil {
            Menu {
                if let displayMode {
                    Section {
                        Picker("session.detail.mode", selection: displayMode) {
                            ForEach(SessionDetailMode.allCases) { mode in
                                #if os(iOS)
                                Label(mode.title, systemImage: mode == .chat ? "bubble.left.and.text.bubble.right" : "terminal")
                                    .labelStyle(.titleAndIcon)
                                    .tag(mode)
                                #else
                                Text(mode.title).tag(mode)
                                #endif
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
                if visible {
                    if let onOpenTerminal {
                        Section {
                            Button(action: onOpenTerminal) {
                                Label("session.actions.open_terminal", systemImage: "terminal")
                            }
                            .disabled(!enabled)
                        }
                    }
                    copySection
                    handoffSection
                    Section {
                        Button {
                            onRestart()
                        } label: {
                            Label(supportsRestart ? "session.actions.restart" : "session.actions.restart.update_host",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(!enabled || !supportsRestart)
                    }
                }
            } label: {
                Label("session.actions.menu", systemImage: "ellipsis")
            }
            .disabled(displayMode == nil && !enabled)
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
        }
    }

    @ViewBuilder
    private var copySection: some View {
        Button {
            onCopy()
        } label: {
            if isBusy {
                Label("session.actions.copy", systemImage: "doc.on.doc")
            } else {
                Label("session.actions.copy", systemImage: "doc.on.doc")
            }
        }
        .disabled(!enabled)
        if isBusy {
            ProgressView()
        }
    }

    @ViewBuilder
    private var handoffSection: some View {
        Menu("session.actions.handoff") {
            if targets.isEmpty {
                Text("session.actions.handoff.empty")
            } else {
                ForEach(targets) { target in
                    Button {
                        if SessionActionsMenu.needsKimiNotice(runtimeID: target.id) {
                            pendingHandoff = target
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
        }
        .disabled(!enabled)
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
