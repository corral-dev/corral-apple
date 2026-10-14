import SwiftUI

/// The pinned picker entry exposes selections even when their quick chips are offscreen.
struct ProjectFilterSummaryLabel: View {
    let selected: Set<SessionProjectFilter>
    let options: [SessionProjectOption]
    let maximumNameWidth: CGFloat

    var title: Text {
        guard !selected.isEmpty else { return Text("sessions.filter.more") }
        guard selected.count == 1, let selection = selected.first else {
            return Text("sessions.filter.project.selected \(selected.count)")
        }
        switch selection {
        case .all:
            return Text("sessions.filter.more")
        case .noProject:
            return Text("sessions.filter.project.none")
        case .project(let path):
            let label = options.first { $0.path == path }?.label
                ?? SessionListFiltering.labelsByPath([path])[path] ?? path
            return label == "~" ? Text("sessions.project.home") : Text(verbatim: label)
        }
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            title
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maximumNameWidth)
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .accessibilityHidden(true)
        }
    }
}
