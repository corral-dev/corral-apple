#if os(iOS)
import SwiftUI

/// Full-text search result: badge, one-line title, up to two hit lines and the
/// project · hits · time line. Search results are outside the list row height
/// contract (owner clarification 2026-10-19); see
/// docs/UI_DESIGN_KNOWLEDGE_BASE.md#iphone-full-text-search.
struct FulltextResultRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: SessionSummary
    let match: FulltextMatch

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            RuntimeBadge(runtimeID: session.runtime, size: SessionRowLayout.badgeSize)
            VStack(alignment: .leading, spacing: FulltextResultLayout.lineSpacing) {
                Text(SessionPresentation.displayTitle(for: session))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                ForEach(Array(match.lines.prefix(FulltextResultLayout.maxHits).enumerated()), id: \.offset) { _, line in
                    snippet(line)
                }
                metaLine
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SessionRowLayout.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private func snippet(_ line: FulltextLine) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            roleMark(line.role)
                .frame(width: FulltextResultLayout.roleMark, height: FulltextResultLayout.snippetLineHeight)
            FulltextHighlight.text(
                line,
                maxLeadScalars: FulltextResultLayout.maxLeadScalars,
                lead: FulltextResultLayout.windowLead
            )
            .font(.subheadline)
            .foregroundStyle(line.role == "user" ? Color.primary : Color.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func roleMark(_ role: String) -> some View {
        if role == "user" {
            Image(systemName: "person.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("chat.role.user"))
        } else if let logo = Palette.runtimeLogoName(session.runtime) {
            Image(logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(.vertical, 3)
                .accessibilityLabel(Text("chat.role.assistant"))
        } else {
            Image(systemName: Palette.runtimeSymbol(session.runtime))
                .font(.caption2)
                .foregroundStyle(Palette.runtime(session.runtime))
                .accessibilityLabel(Text("chat.role.assistant"))
        }
    }

    private var metaLine: some View {
        HStack(spacing: Space.xs) {
            SessionProjectLabel(session: session)
            if match.totalHits > 0 {
                Text(verbatim: "·")
                Text("search.hits \(match.totalHits)")
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Space.sm)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let time = SessionPresentation.timeLabel(for: session, now: context.date)
                if !time.isEmpty {
                    Text(time)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            SessionStatusDots(session: session)
                .fixedSize()
        }
        .font(Typography.sessionMeta)
        .foregroundStyle(.secondary)
    }
}

/// Result geometry, tuned on the phone: two hit lines of up to two lines each.
enum FulltextResultLayout {
    static let maxHits = 2
    static let lineSpacing: CGFloat = 6
    static let roleMark: CGFloat = 13
    static let snippetLineHeight: CGFloat = 20
    /// About one and a half phone lines of CJK before the first hit…
    static let maxLeadScalars = 28
    /// …then reopen this much context ahead of it.
    static let windowLead = 8
}
#endif
