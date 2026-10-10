import SwiftUI

struct ToolCardView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let tool: ToolCall
    #if os(macOS)
    var isGrouped = false
    #endif
    @State private var detailExpanded = false

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        if isGrouped {
            cardContent
        } else {
            standaloneCard
        }
        #else
        standaloneCard
        #endif
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
            HStack(spacing: Space.sm * interfaceScale) {
                Image(systemName: iconName)
                    .interfaceFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .interfaceFrame(width: 22)
                VStack(alignment: .leading, spacing: 2 * interfaceScale) {
                    Text(tool.name.isEmpty ? tool.kind : tool.name)
                        .sessionFont(.toolTitle)
                        .lineLimit(1)
                    if !tool.summary.isEmpty {
                        Text(tool.summary)
                            .sessionFont(.toolMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            if let options = tool.options, !options.isEmpty {
                FlowLayout(spacing: Space.sm * interfaceScale) {
                    ForEach(options, id: \.self) { option in
                        Text(option)
                            .sessionFont(.toolMeta)
                            .interfacePadding(.horizontal, Space.sm)
                            .interfacePadding(.vertical, Space.xs)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                }
            }

            if let detail = tool.detail, !detail.isEmpty {
                DisclosureGroup("chat.tool.detail", isExpanded: $detailExpanded) {
                    SelectableAttributedText(
                        attributed: AttributedString(detail),
                        foreground: .primary,
                        fontStyle: .code
                    )
                    .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                    .interfacePadding(Space.sm)
                    .background(Palette.codeSurface)
                    #if os(macOS)
                    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(Radius.sm))))
                    #else
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm * interfaceScale, style: .continuous))
                    #endif
                }
                .sessionFont(.toolMeta)
            }

            if let output = tool.output, !output.isEmpty {
                Group {
                    if detailExpanded {
                        SelectableAttributedText(
                            attributed: AttributedString(output),
                            foreground: .secondary,
                            fontStyle: .code
                        )
                    } else {
                        Text(output)
                            .sessionFont(.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }
                }
                .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                .interfacePadding(Space.sm)
                .background(Palette.codeSurface)
                #if os(macOS)
                .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(Radius.sm))))
                #else
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm * interfaceScale, style: .continuous))
                #endif
            }
        }
    }

    private var standaloneCard: some View {
        cardContent
        .interfacePadding(Space.md)
        .background(
            Color(.tertiarySystemBackground),
            in: RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var iconName: String {
        switch tool.kind.lowercased() {
        case "bash", "shell", "terminal": "terminal"
        case "read", "file_read": "doc.text"
        case "write", "edit", "file_write": "pencil"
        case "search", "grep", "glob": "magnifyingglass"
        case "ask", "question", "prompt": "questionmark.circle"
        case "web", "fetch": "globe"
        default: "wrench.and.screwdriver"
        }
    }
}

/// 简单流式布局，用于工具选项标签。
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
