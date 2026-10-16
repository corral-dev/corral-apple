import SwiftUI

/// 会话页工作区入口：顶栏标题按钮里的副行 caption（folder + 短名），
/// 不在对话区另起一行。点工作区 caption 进详情，点标题/状态仍进提示词。
struct SessionWorkspaceCaption: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let workspaceName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs * interfaceScale) {
            Image(systemName: "folder")
                .interfaceFont(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            workspaceLabel
        }
        .interfaceFrame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workspaceAccessibilityLabel)
        .accessibilityHint(Text("session.workspace.open_hint"))
    }

    @ViewBuilder
    private var workspaceLabel: some View {
        // 调用方已算好短名（含 "~" 哨兵）；这里只做显示，不读 session。
        if workspaceName == "~" {
            Text("sessions.project.home")
                .interfaceFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if workspaceName.isEmpty {
            Text("sessions.project.unknown")
                .interfaceFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(workspaceName)
                .interfaceFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var workspaceAccessibilityLabel: Text {
        let name: Text = workspaceName.isEmpty
            ? Text("sessions.project.unknown")
            : (workspaceName == "~" ? Text("sessions.project.home") : Text(workspaceName))
        return Text("\(Text("session.workspace.label")), \(name)")
    }
}

/// 工作区详情：名称、完整目录（可复制）、所属开发机。只确认位置。
/// 顶栏副行 caption 的点入目标；标题本体仍打开提示词。
/// session 仍是唯一真相源：短名/全路径都从 session 派生，
/// hostName 只做展示（缺失即未知），不参与定位。
struct SessionWorkspaceSheet: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let session: SessionSummary
    let hostName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("session.workspace.name") {
                        workspaceName
                    }
                    LabeledContent("session.workspace.host") {
                        Text(hostName.isEmpty ? String(localized: "sessions.project.unknown") : hostName)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("session.workspace.path") {
                    Text(fullPath.isEmpty ? String(localized: "sessions.project.unknown") : fullPath)
                        .interfaceFont(.body.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                    if !fullPath.isEmpty {
                        Button {
                            PlatformPasteboard.copy(fullPath)
                        } label: {
                            Label("session.workspace.copy_path", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }
            .navigationTitle("session.workspace.title")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .corralTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .interfaceFont(.title2)
                            .foregroundStyle(.secondary)
                            .frame(
                                width: TouchTarget.minimum,
                                height: TouchTarget.minimum
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(Text("action.dismiss"))
                }
            }
        }
    }

    private var workspaceName: Text {
        let project = SessionPresentation.projectName(from: session)
        if project == "~" { return Text("sessions.project.home") }
        if project.isEmpty { return Text("sessions.project.unknown") }
        return Text(project)
    }

    private var fullPath: String {
        SessionPresentation.fullWorkspacePath(from: session)
    }
}
