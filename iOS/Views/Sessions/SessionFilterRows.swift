#if os(iOS)
import SwiftUI

/// Compact device/connection subtitle for the native inline navigation
/// principal area: device name with the connection dot/state/route beneath.
/// Same state vocabulary as `ConnectionBanner` (which owns the in-list row
/// presentation); this centered variant carries no spacer so it sits centered
/// in the principal slot. Native back, settings and create actions are
/// untouched.
struct SessionPrincipalHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let deviceName: String
    let state: AppModel.ConnectionState
    var transport: ConnectionTransport?

    var body: some View {
        VStack(spacing: 1) {
            Text(deviceName)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: Space.sm) {
                Circle()
                    .fill(dotColor)
                    .frame(width: TouchTarget.attentionDot, height: TouchTarget.attentionDot)
                    .accessibilityHidden(true)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var showsProgress: Bool {
        switch state {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private var dotColor: Color {
        switch state {
        case .connected: Palette.attentionWorking
        case .connecting, .reconnecting: Palette.attentionWaiting
        case .failed: Palette.attentionUnread
        case .disconnected: Color.secondary
        }
    }

    private var statusLabel: LocalizedStringKey {
        switch state {
        case .connected:
            switch transport {
            case .local: "connection.connected_local"
            case .relay: "connection.connected_relay"
            case nil: "connection.connected"
            }
        case .connecting: "connection.connecting"
        case .reconnecting: "connection.reconnecting"
        case .failed: "connection.failed"
        case .disconnected: "connection.disconnected"
        }
    }
}

/// Intrinsic-width runtime chips keep each official logo and name on one line.
/// Horizontal scrolling handles narrow screens and larger text without tiles.
struct SessionRuntimeFilterRow: View {
    @Binding var selected: Set<SessionRuntimeFilter>

    var body: some View {
        SessionFilterScrollView {
            HStack(spacing: SessionFilterStyle.chipSpacing) {
                ForEach(SessionRuntimeFilter.ordered, id: \.self) { option in
                    SessionFilterChip(selected: option == .all ? selected.isEmpty : selected.contains(option)) {
                        if option == .all {
                            Text("sessions.filter.all")
                        } else {
                            if let logo = Palette.runtimeLogoName(option.rawValue) {
                                Image(logo)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                                    .accessibilityHidden(true)
                            }
                            Text(verbatim: Palette.runtimeDisplayName(option.rawValue))
                        }
                    } action: {
                        select(option)
                    }
                    .accessibilityLabel(
                        option == .all
                            ? Text("sessions.filter.all")
                            : Text(verbatim: Palette.runtimeDisplayName(option.rawValue))
                    )
                }
            }
        }
        .padding(.horizontal, SessionListLayout.rowHorizontal)
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectSelectedFilters") {
                selected = [.codex]
            } else if ProcessInfo.processInfo.arguments.contains("-CorralInspectMultiFilters") {
                selected = [.claude, .codex]
            }
        }
        #endif
    }
    private func select(_ value: SessionRuntimeFilter) {
        let previous = selected
        SessionListFiltering.toggle(value, all: .all, in: &selected)
        guard selected != previous else { return }
        HapticFeedback.shared.emit(.selection)
    }

}

/// Project quick-filter row: the stable snapshot choices scroll horizontally
/// while More stays fixed outside the scroller as a 44-point trailing
/// control opening the searchable complete list. A selected no-project
/// choice and all selected out-of-snapshot projects keep visible toggle chips.
struct SessionProjectFilterRow: View {
    @Binding var selected: Set<SessionProjectFilter>
    /// Stable per-host snapshot order from `SessionListFiltering`.
    let choices: [SessionProjectOption]
    /// Selected projects outside the snapshot, in stable path order.
    let selectedOutside: [SessionProjectOption]
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: SessionFilterStyle.moreGap) {
            SessionFilterScrollView {
                HStack(spacing: SessionFilterStyle.chipSpacing) {
                    SessionFilterChip(selected: selected.isEmpty) {
                        Text("sessions.filter.all")
                    } action: {
                        select(.all)
                    }
                    .accessibilityLabel(Text("sessions.filter.all"))
                    if selected.contains(.noProject) {
                        SessionFilterChip(selected: true) {
                            Text("sessions.filter.project.none")
                        } action: {
                            select(.noProject)
                        }
                        .accessibilityLabel(Text("sessions.filter.project.none"))
                    }
                    ForEach(selectedOutside, id: \.path) { outside in
                        SessionFilterChip(selected: true) {
                            projectChipText(for: outside)
                        } action: {
                            select(.project(path: outside.path))
                        }
                        .accessibilityLabel(Text(outside.label))
                    }
                    ForEach(choices, id: \.path) { option in
                        let isSelected = selected.contains(.project(path: option.path))
                        SessionFilterChip(selected: isSelected) {
                            projectChipText(for: option)
                        } action: {
                            select(.project(path: option.path))
                        }
                        .accessibilityLabel(Text(option.label))
                    }
                }
            }
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 1))
            .accessibilityLabel(Text("sessions.filter.more"))
        }
        .padding(.horizontal, SessionListLayout.rowHorizontal)
        #if DEBUG
        .task(id: choices) {
            if ProcessInfo.processInfo.arguments.contains("-CorralInspectSelectedFilters"),
                 selected.isEmpty, let first = choices.first {
                selected = [.project(path: first.path)]
            } else if ProcessInfo.processInfo.arguments.contains("-CorralInspectMultiFilters"),
                      selected.isEmpty, choices.count >= 2 {
                selected = Set(choices.prefix(2).map { .project(path: $0.path) })
            }
        }
        #endif
    }

    @ViewBuilder
    private func projectChipText(for option: SessionProjectOption) -> some View {
        if option.label == "~" {
            Text("sessions.project.home")
        } else {
            Text(option.label)
        }
    }
    private func select(_ value: SessionProjectFilter) {
        let previous = selected
        SessionListFiltering.toggle(value, all: .all, in: &selected)
        guard selected != previous else { return }
        HapticFeedback.shared.emit(.selection)
    }

}

/// Searchable complete project list behind the More entry: All, every project
/// with sessions on this host (short name plus full path for duplicates),
/// and the no-project bucket when such sessions exist.
struct SessionProjectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let options: [SessionProjectOption]
    let hasNoProject: Bool
    @Binding var selected: Set<SessionProjectFilter>

    private var visibleOptions: [SessionProjectOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.label.lowercased().contains(needle) || $0.path.lowercased().contains(needle)
        }
    }

    private var showNoProject: Bool {
        guard hasNoProject else { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let label = String(localized: String.LocalizationValue("sessions.filter.project.none"))
        return label.lowercased().contains(needle)
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    select(.all)
                } label: {
                    pickerRow(
                        title: Text("sessions.filter.all"),
                        detail: nil,
                        isSelected: selected.isEmpty
                    )
                }
                ForEach(visibleOptions, id: \.path) { option in
                    Button {
                        select(.project(path: option.path))
                    } label: {
                        pickerRow(
                            title: option.label == "~"
                                ? Text("sessions.project.home")
                                : Text(option.label),
                            detail: option.path,
                            isSelected: selected.contains(.project(path: option.path))
                        )
                    }
                }
                if showNoProject {
                    Button {
                        select(.noProject)
                    } label: {
                        pickerRow(
                            title: Text("sessions.filter.project.none"),
                            detail: nil,
                            isSelected: selected.contains(.noProject)
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: Text("sessions.filter.project.search"))
            .navigationTitle("sessions.filter.project.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
        .tint(.primary)
    }

    private func select(_ value: SessionProjectFilter) {
        let previous = selected
        SessionListFiltering.toggle(value, all: .all, in: &selected)
        guard selected != previous else { return }
        HapticFeedback.shared.emit(.selection)
    }

    private func pickerRow(
        title: Text,
        detail: String?,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xs) {
                title
                    .font(.body)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(Typography.sessionPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.sm)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: TouchTarget.minimum)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Fade only edges with offscreen content. The alpha mask also confines chips
/// to the viewport, so page padding belongs outside this view in both rows.
private struct SessionFilterScrollView<Content: View>: View {
    @Namespace private var coordinateSpace
    @State private var contentFrame: CGRect = .zero
    @State private var viewportWidth: CGFloat = 0
    @ViewBuilder let content: () -> Content

    private var hiddenOnLeft: Bool { contentFrame.minX < -0.5 }
    private var hiddenOnRight: Bool { contentFrame.maxX > viewportWidth + 0.5 }

    var body: some View {
        let space = coordinateSpace
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .onGeometryChange(for: CGRect.self) { geometry in
                        geometry.frame(in: .named(space))
                    } action: { frame in
                        contentFrame = frame
                    }
                    .id("filter-content")
            }
            .coordinateSpace(name: space)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                viewportWidth = width
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [hiddenOnLeft ? .clear : .white, .white],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: SessionFilterStyle.edgeFadeWidth)
                    Rectangle().fill(.white)
                    LinearGradient(
                        colors: [.white, hiddenOnRight ? .clear : .white],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: SessionFilterStyle.edgeFadeWidth)
                }
            }
            #if DEBUG
            .task {
                // Inspect the same installed app at scroll boundaries without a
                // second test app. These launch options do not exist in Release.
                let arguments = ProcessInfo.processInfo.arguments
                let anchor: UnitPoint
                if arguments.contains("-CorralInspectFilterEnd") {
                    anchor = .trailing
                } else if arguments.contains("-CorralInspectFilterMiddle") {
                    anchor = .center
                } else {
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                proxy.scrollTo("filter-content", anchor: anchor)
            }
            #endif
        }
        .fixedSize(horizontal: false, vertical: true)
    }

}

/// Native capsule buttons distinguish selection with a quiet accent tint.
/// Neither state reserves a trailing icon slot; both remain content-sized.
private struct SessionFilterChip<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        button
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(selected ? Palette.accent : Color.secondary)
        .frame(minHeight: TouchTarget.minimum)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: SessionFilterStyle.chipContentSpacing) {
                content()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 20, minHeight: 24)
            .contentShape(Rectangle())
        }
    }
}

/// Both filter rows share the same compact chip geometry and typography.
private enum SessionFilterStyle {
    static let chipSpacing: CGFloat = 6
    static let chipContentSpacing: CGFloat = 6
    static let moreGap: CGFloat = 4
    static let edgeFadeWidth: CGFloat = 24
}

#endif
