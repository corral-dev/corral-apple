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

    /// The project reads first on the meta line: primary semibold over the
    /// secondary time (Mac design: Collapsed split and project prominence).
    @ViewBuilder
    private var projectLabel: some View {
        let project = SessionPresentation.projectName(from: session)
        Group {
            if project == "~" {
                Text("sessions.project.home")
            } else if project.isEmpty {
                Text("sessions.project.unknown")
            } else {
                Text(project)
            }
        }
        .interfaceFont(Typography.sessionMeta.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// Activity dot plus the independent red unread dot. Both can show at
    /// once; an empty row keeps one dot of space so the time baseline holds.
    @ViewBuilder
    private var statusDotPlaceholder: some View {
        let dots = statusDots
        if dots.isEmpty {
            Color.clear
                .interfaceFrame(width: TouchTarget.attentionDot, height: TouchTarget.attentionDot)
                .accessibilityHidden(true)
        } else {
            HStack(spacing: 4 * interfaceScale) {
                ForEach(dots.indices, id: \.self) { index in
                    Circle()
                        .fill(dots[index].color)
                        .interfaceFrame(width: TouchTarget.attentionDot, height: TouchTarget.attentionDot)
                        .accessibilityLabel(Text(dots[index].label))
                }
            }
            .fixedSize()
        }
    }

    /// Activity first, then the independent red unread overlay.
    /// `recent` shares the working green.
    private var statusDots: [(color: Color, label: LocalizedStringKey)] {
        var dots: [(color: Color, label: LocalizedStringKey)] = []
        switch SessionPresentation.activityMarker(for: session) {
        case .waiting:
            dots.append((Palette.attentionWaiting, "sessions.attention.waiting"))
        case .working:
            dots.append((Palette.attentionWorking, "sessions.attention.working"))
        case .recent:
            dots.append((Palette.attentionWorking, "sessions.live"))
        case .unread, nil:
            break
        }
        if SessionPresentation.hasUnread(for: session) {
            dots.append((Palette.attentionUnread, "sessions.attention.unread"))
        }
        return dots
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
