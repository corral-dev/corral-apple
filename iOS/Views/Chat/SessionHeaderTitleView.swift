import SwiftUI

/// Leading-aligned conversation identity in the system navigation bar.
struct SessionHeaderTitleView: View {
    let model: SessionHeaderModel
    /// Nil = 标题按钮整体仍只进提示词（旧调用方）；非 nil = caption 独立进工作区。
    var workspaceRequest: Binding<Bool>? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .lastTextBaseline, spacing: Space.xs) {
                Text(model.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(titleLineLimit)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            metadataRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: TouchTarget.minimum, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var titleLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 2
    }

    @ViewBuilder
    private var metadataRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            ViewThatFits(in: .horizontal) {
                metadataContent(allowsWrap: false)
                metadataContent(allowsWrap: true)
            }
            workspaceCaption
        }
    }

    private func metadataContent(allowsWrap: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            if let assistantName = model.assistantName {
                Text(assistantName)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(allowsWrap ? 2 : 1)
            }
            HStack(alignment: .center, spacing: Space.xs) {
                Circle()
                    .fill(model.state.markerColor)
                    .frame(width: TouchTarget.headerStateDot, height: TouchTarget.headerStateDot)
                    .accessibilityHidden(true)
                Text(model.state.labelKey)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(allowsWrap ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Workspace caption: same footnote line-family as the state row, quieter
    /// color, single line. Lives inside the existing header block — zero new rows
    /// in the conversation layout (the bar only grows if the title already wraps).
    /// 点 caption 进工作区详情（外层标题按钮仍进提示词，互不抢）。
    @ViewBuilder
    private var workspaceCaption: some View {
        if let workspaceRequest {
            Button {
                workspaceRequest.wrappedValue = true
            } label: {
                SessionWorkspaceCaption(
                    workspaceName: (model.workspaceName ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            SessionWorkspaceCaption(
                workspaceName: (model.workspaceName ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
    }

    private var accessibilityLabel: Text {
        var label = Text(model.title)
        if let assistantName = model.assistantName {
            label = label + Text(", ") + Text(assistantName)
        }
        label = label + Text(", ") + Text(model.state.labelKey)
        let name = (model.workspaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return label + Text(", ") + Text("sessions.project.unknown")
        }
        if name == "~" {
            return label + Text(", ") + Text("sessions.project.home")
        }
        return label + Text(", ") + Text(name)
    }
}
