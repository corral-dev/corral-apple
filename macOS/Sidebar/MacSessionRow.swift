import SwiftUI

/// Desktop session row: exactly two lines at every content state.
/// Line 1 is the assistant glyph, title, status dot and compact time; line 2
/// is the project (omitted when the enclosing group already names it) and the
/// preview. See docs/design/MACOS_CLIENT_DESIGN.md, sidebar density redesign.
struct MacSessionRow: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.sidebarRowSize) private var rowSize
    @Environment(\.sidebarNow) private var now
    let session: SessionSummary
    /// Present for every host split member, even when its peers are filtered out.
    var splitHelp: String?

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs * interfaceScale) {
            RuntimeGlyph(runtimeID: session.runtime, size: MacSidebarMetrics.glyph(rowSize))
                .interfaceFrame(height: MacSidebarMetrics.titleLineHeight, alignment: .center)

            VStack(alignment: .leading, spacing: MacSidebarMetrics.lineSpacing * interfaceScale) {
                HStack(spacing: Space.xs * interfaceScale) {
                    Text(SessionPresentation.displayTitle(for: session))
                        .interfaceFont(.body)
                        .fontWeight(needsPerson ? .semibold : nil)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Space.xs * interfaceScale)
                    statusDot
                    Text(verbatim: MacSidebarMetrics.compactTime(for: session, now: now))
                        .interfaceFont(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .interfaceFrame(height: MacSidebarMetrics.titleLineHeight)

                HStack(spacing: Space.xs * interfaceScale) {
                    if let splitHelp {
                        Image(systemName: "rectangle.split.2x1")
                            .imageScale(.small)
                            .help(Text(verbatim: splitHelp))
                            .accessibilityLabel(Text("mac.session.in_split"))
                    }
                    secondaryLine
                        .truncationMode(.tail)
                }
                .interfaceFont(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .interfacePadding(.vertical, MacSidebarMetrics.rowPadding)
        .interfaceFrame(height: MacSidebarMetrics.rowHeight)
        .help(Text(verbatim: tooltip))
        .accessibilityElement(children: .combine)
    }

    /// Waiting for an answer or unread: the title is semibold, the Mail
    /// convention (design: Visual guidance pass); the trailing dots stay.
    /// Red unread is independent from the yellow waiting activity: either one
    /// (or both together) keeps the emphasis.
    private var needsPerson: Bool {
        SessionPresentation.activityMarker(for: session) == .waiting
            || SessionPresentation.hasUnread(for: session)
    }

    /// Project then preview; a blank string keeps the line when both are empty.
    /// The project reads first: primary semibold over the secondary preview
    /// (design: Collapsed split and project prominence).
    private var secondaryLine: Text {
        let preview = SessionPresentation.preview(for: session)
        let project = visibleProject
        switch (project, preview.isEmpty) {
        case (nil, true): return Text(verbatim: " ")
        case (nil, false): return Text(preview)
        case (let project?, true): return project
        case (let project?, false): return Text("\(project)  \(Text(preview))")
        }
    }

    private var visibleProject: Text? {
        let name = SessionPresentation.projectName(from: session)
        switch name {
        case "~": return Text("sessions.project.home").fontWeight(.semibold).foregroundStyle(.primary)
        case "": return Text("sessions.project.unknown").fontWeight(.semibold).foregroundStyle(.primary)
        default: return Text(verbatim: name).fontWeight(.semibold).foregroundStyle(.primary)
        }
    }

    /// Activity dot plus the independent red unread dot; both can show at once.
    @ViewBuilder
    private var statusDot: some View {
        let dots = statusDots
        if !dots.isEmpty {
            HStack(spacing: 4 * interfaceScale) {
                ForEach(dots.indices, id: \.self) { index in
                    Circle()
                        .fill(dots[index].color)
                        .interfaceFrame(width: 7, height: 7)
                        .accessibilityLabel(Text(dots[index].label))
                }
            }
            .fixedSize()
        }
    }

    /// Activity first, then the independent red unread overlay.
    private var statusDots: [(color: Color, label: LocalizedStringKey)] {
        var dots: [(color: Color, label: LocalizedStringKey)] = []
        switch SessionPresentation.activityMarker(for: session) {
        case .waiting:
            dots.append((MacSidebarMetrics.color(for: .waiting), MacSidebarMetrics.label(for: .waiting)))
        case .working:
            dots.append((MacSidebarMetrics.color(for: .working), MacSidebarMetrics.label(for: .working)))
        case .recent:
            dots.append((MacSidebarMetrics.color(for: .recent), MacSidebarMetrics.label(for: .recent)))
        case .unread, nil:
            break
        }
        if SessionPresentation.hasUnread(for: session) {
            dots.append((MacSidebarMetrics.color(for: .unread), MacSidebarMetrics.label(for: .unread)))
        }
        return dots
    }

    private var tooltip: String {
        let preview = String(SessionPresentation.preview(for: session).prefix(280))
        return [
            SessionPresentation.displayTitle(for: session),
            SessionPresentation.fullWorkspacePath(from: session),
            preview,
            splitHelp ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}

/// Official assistant artwork as a bare sidebar glyph, without the phone's tile.
struct RuntimeGlyph: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let runtimeID: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let name = Palette.runtimeLogoName(runtimeID) {
                Image(name)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: Palette.runtimeSymbol(runtimeID))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Palette.runtime(runtimeID))
            }
        }
        .interfaceFrame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Sidebar sizing and the shared status-dot vocabulary.
enum MacSidebarMetrics {
    /// Line height of the body-sized title line; the glyph centers on it.
    static let titleLineHeight: CGFloat = 17
    /// Vertical rhythm (design: Vertical rhythm, owner request 2026-10-08).
    static let lineSpacing: CGFloat = 2
    static let rowPadding: CGFloat = 4
    /// Equal two-line session height; supporting entries remain compact.
    static let rowHeight: CGFloat = 52
    static let compactRowHeight: CGFloat = 32
    static let sectionHeight: CGFloat = 28
    static let filterHeight: CGFloat = 28

    /// Follows the system sidebar icon size (General → Sidebar icon size).
    static func glyph(_ rowSize: SidebarRowSize) -> CGFloat {
        switch rowSize {
        case .small: 14
        case .large: 18
        default: 16
        }
    }

    /// Clock time today, short date before; the day section names the day.
    static func compactTime(for session: SessionSummary, now: Date) -> String {
        guard session.mtime > 0 else { return session.time }
        let date = Date(timeIntervalSince1970: session.mtime)
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }

    static func color(for marker: SessionPresentation.StatusMarker) -> Color {
        switch marker {
        case .waiting: Palette.attentionWaiting
        case .working, .recent: Palette.attentionWorking
        case .unread: Palette.attentionUnread
        }
    }

    static func label(for marker: SessionPresentation.StatusMarker) -> LocalizedStringKey {
        switch marker {
        case .waiting: "sessions.attention.waiting"
        case .working: "sessions.attention.working"
        case .unread: "sessions.attention.unread"
        case .recent: "sessions.live"
        }
    }
}
