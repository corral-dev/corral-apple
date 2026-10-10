import SwiftUI

/// Session row: at ordinary text sizes exactly three lines — one-line title,
/// one-line preview (blank when genuinely empty), project + time + status.
/// Height never depends on title length or preview presence and no unused line
/// is reserved; see docs/UI_DESIGN_KNOWLEDGE_BASE.md#row-height-contract.
/// Accessibility sizes reflow for readability.
struct SessionRowView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: SessionSummary

    private var isAccessibility: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md * interfaceScale) {
            runtimeBadge

            VStack(alignment: .leading, spacing: SessionRowLayout.textStackSpacing) {
                titleLine
                previewLine
                metaLine
                    .interfacePadding(.top, 2)
            }
            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
        }
        .interfacePadding(.vertical, SessionRowLayout.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private var titleLine: some View {
        Group {
            if isAccessibility {
                titleText
                    .lineLimit(nil)
            } else {
                titleText
                    .lineLimit(SessionRowLayout.titleLineLimit)
            }
        }
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .interfaceFrame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: some View {
        Text(SessionPresentation.displayTitle(for: session))
            .interfaceFont(.body.weight(.medium))
            .foregroundStyle(.primary)
    }

    /// Always one line at ordinary sizes so every row has the same height; an
    /// empty preview stays blank rather than inventing text.
    @ViewBuilder
    private var previewLine: some View {
        let preview = SessionPresentation.preview(for: session)
        if isAccessibility {
            if !preview.isEmpty {
                Text(preview)
                    .interfaceFont(Typography.sessionPreview)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .interfaceFrame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(preview.isEmpty ? " " : preview)
                .interfaceFont(Typography.sessionPreview)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(preview.isEmpty)
        }
    }

    /// 末行：位置在左，时间+状态在右。置顶标不占新行；无状态时占位保持时间不跳。
    private var metaLine: some View {
        HStack(spacing: Space.xs * interfaceScale) {
            projectLabel
            if session.pinned == true {
                Image(systemName: "pin.fill")
                    .interfaceFont(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("sessions.section.pinned"))
            }

            Spacer(minLength: Space.sm * interfaceScale)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                let time = SessionPresentation.timeLabel(for: session, now: context.date)
                if !time.isEmpty {
                    Text(time)
                        .interfaceFont(Typography.sessionMeta)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            statusDotPlaceholder
                .fixedSize()
        }
    }

    @ViewBuilder
    private var projectLabel: some View {
        let project = SessionPresentation.projectName(from: session)
        if project == "~" {
            Text("sessions.project.home")
                .interfaceFont(Typography.sessionMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if project.isEmpty {
            Text("sessions.project.unknown")
                .interfaceFont(Typography.sessionMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(project)
                .interfaceFont(Typography.sessionMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 有状态画点，无状态占同样尺寸，保证时间基线不跳。
    @ViewBuilder
    private var statusDotPlaceholder: some View {
        if let status = statusDot {
            Circle()
                .fill(status.color)
                .interfaceFrame(width: TouchTarget.attentionDot, height: TouchTarget.attentionDot)
                .accessibilityLabel(Text(status.label))
        } else {
            Color.clear
                .interfaceFrame(width: TouchTarget.attentionDot, height: TouchTarget.attentionDot)
                .accessibilityHidden(true)
        }
    }

    /// Host-decided TUI dot (`marker`); `recent` shares the working green.
    private var statusDot: (color: Color, label: LocalizedStringKey)? {
        switch SessionPresentation.statusMarker(for: session) {
        case .waiting:
            return (Palette.attentionWaiting, "sessions.attention.waiting")
        case .working:
            return (Palette.attentionWorking, "sessions.attention.working")
        case .unread:
            return (Palette.attentionUnread, "sessions.attention.unread")
        case .recent:
            return (Palette.attentionWorking, "sessions.live")
        case nil:
            return nil
        }
    }

    /// 官方助手标识；未知助手才回退系统符号。
    private var runtimeBadge: some View {
        RuntimeBadge(runtimeID: session.runtime, size: SessionRowLayout.badgeSize)
    }
}

/// 列表行布局常量：行内三段间距与标题行数集中在此，验收只调这里。
enum SessionRowLayout {
    /// One line at ordinary sizes (row height contract); accessibility reflows.
    static let titleLineLimit = 1
    /// 标题→预览、预览/标题→末行：紧凑但不断行粘连。
    static let textStackSpacing: CGFloat = 4
    /// 每行上下内边距：系统留白之上只补这一层，不叠加。
    static let rowVerticalPadding: CGFloat = 8
    /// 助手标识与标题顶部对齐的固定尺寸。
    static let badgeSize: CGFloat = 32
}
