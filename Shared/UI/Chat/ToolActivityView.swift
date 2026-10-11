import SwiftUI

/// Compact summary capsule that opens tool details in a native popover on the
/// Mac and a large dismissible detail sheet on iPhone.
/// Consecutive tool-only turns merge into one card; bodies load on demand.
struct ToolActivityView: View, Equatable {
    let tools: [ToolCall]
    let sourceSeqs: [Int]
    let runtimeID: String?
    var store: ConversationStore? = nil
    /// Explicit style inputs instead of environment (see MessageBubbleView):
    /// row equality must cover every dynamic input.
    var interfaceScale: CGFloat = 1
    var sessionTextScale: CGFloat = SessionTextSize.default.scale
    var colorScheme: ColorScheme = .light

    /// `store` is compared by identity: content changes arrive through `tools`.
    /// A replaced store (reconnect) must re-resolve even for identical tools.
    static func == (lhs: ToolActivityView, rhs: ToolActivityView) -> Bool {
        lhs.tools == rhs.tools
            && lhs.sourceSeqs == rhs.sourceSeqs
            && lhs.runtimeID == rhs.runtimeID
            && lhs.store.map(ObjectIdentifier.init) == rhs.store.map(ObjectIdentifier.init)
            && lhs.interfaceScale == rhs.interfaceScale
            && lhs.sessionTextScale == rhs.sessionTextScale
            && lhs.colorScheme == rhs.colorScheme
    }

    @State private var showDetail = false
    @State private var detailTools: [ToolCall]
    @State private var isLoadingDetail = false
    @State private var detailError: String?

    init(
        tools: [ToolCall],
        sourceSeqs: [Int],
        runtimeID: String?,
        store: ConversationStore? = nil,
        interfaceScale: CGFloat = 1,
        sessionTextScale: CGFloat = SessionTextSize.default.scale,
        colorScheme: ColorScheme = .light
    ) {
        self.tools = tools
        self.sourceSeqs = sourceSeqs
        self.runtimeID = runtimeID
        self.store = store
        self.interfaceScale = interfaceScale
        self.sessionTextScale = sessionTextScale
        self.colorScheme = colorScheme
        _detailTools = State(initialValue: tools)
    }

    var body: some View {
        #if DEBUG
        let _ = SwitchBodyCounters.toolBodies &+= 1
        #endif
        #if os(macOS)
        popoverBody
        #else
        sheetBody
        #endif
    }

    #if os(macOS)
    /// The capsule never changes size and the conversation never changes height:
    /// details float above it, and an outside click or Esc closes them.
    private var popoverBody: some View {
        HStack(spacing: 0) {
            Button {
                showDetail.toggle()
            } label: {
                summaryCapsule(isOpen: showDetail)
            }
            .buttonStyle(.borderless)
            // Hierarchical label styles must resolve from neutral ink, not the app accent.
            .tint(Color(nsColor: .labelColor))
            .accessibilityHint(Text("chat.agent_activity.open_hint"))
            // Bodies start loading on hover so the popover opens at its final size.
            .onHover { hovering in
                if hovering { Task { await loadDetailsIfNeeded() } }
            }
            // A fixed-width popover beside the capsule only grows vertically around
            // it; above/below placement flips edges when the height changes.
            .popover(isPresented: $showDetail, arrowEdge: .trailing) {
                detailPopover
                    .environment(\.sessionTextScale, sessionTextScale)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: tools) { _, newTools in
            if !showDetail {
                detailTools = newTools
            }
        }
        #if DEBUG
        .task { await openForInspectionIfRequested() }
        #endif
    }

    private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.itemSpacing * interfaceScale) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                Text("chat.agent_activity")
                    .interfaceFont(.headline)
                Text("chat.tools_count \(detailTools.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .interfacePadding(.horizontal, Space.base)
            .interfacePadding(.vertical, Space.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoadingDetail && detailTools.allSatisfy(\.needsDetailFetch) {
                        ProgressView()
                            .interfaceControlSize(.small)
                            .interfaceFrame(maxWidth: .infinity)
                            .interfacePadding(.vertical, Space.base)
                    }
                    if let detailError, !detailError.isEmpty {
                        Text(detailError)
                            .sessionFont(.toolMeta)
                            .foregroundStyle(.secondary)
                            .interfacePadding(.top, Space.md)
                    }
                    ForEach(Array(detailTools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { Divider() }
                        ToolCardView(tool: tool, isGrouped: true)
                            .interfacePadding(.vertical, Space.md)
                    }
                }
                .nativeOverlayScrollers()
                .interfacePadding(.horizontal, Space.base)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The scroll view's ideal height is its content: short groups hug their
            // rows from the first frame and long ones scroll inside the cap.
            .interfaceFrame(maxHeight: Metrics.popoverMaxHeight)
        }
        .interfaceFrame(width: Metrics.popoverWidth)
        .task { await loadDetailsIfNeeded() }
    }

    #if DEBUG
    /// Debug window inspection opens one group's popover without pointer input.
    private func openForInspectionIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-CorralInspectToolActivity"),
              let sequence = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_TOOL_SEQ"].flatMap(Int.init),
              sourceSeqs.contains(sequence) else { return }
        try? await Task.sleep(for: .seconds(2))
        showDetail = true
    }
    #endif
    #endif

    private var sheetBody: some View {
        Button {
            showDetail = true
        } label: {
            summaryLabel
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint(Text("chat.agent_activity.open_hint"))
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                Group {
                    if isLoadingDetail && detailTools.allSatisfy(\.needsDetailFetch) {
                        ProgressView()
                            .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
                                if let detailError, !detailError.isEmpty {
                                    Text(detailError)
                                        .sessionFont(.toolMeta)
                                        .foregroundStyle(.secondary)
                                        .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                                }
                                ForEach(detailTools) { tool in
                                    ToolCardView(tool: tool)
                                }
                            }
                            .interfacePadding(.horizontal, Space.base)
                            .interfacePadding(.vertical, Space.md)
                        }
                    }
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("chat.agent_activity")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .corralTrailing) {
                        Button {
                            showDetail = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .interfaceFont(.title2)
                                .foregroundStyle(.secondary)
                                .interfaceFrame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(Text("action.dismiss"))
                    }
                }
                .task(id: showDetail) {
                    guard showDetail else { return }
                    await loadDetailsIfNeeded()
                }
            }
            .environment(\.sessionTextScale, sessionTextScale)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled(false)
        }
        .onChange(of: tools) { _, newTools in
            if !showDetail {
                detailTools = newTools
            }
        }
    }

    private func loadDetailsIfNeeded() async {
        // Hover prefetch and popover presentation share one request.
        guard !isLoadingDetail else { return }
        detailError = nil
        guard let store else { return }
        let needsFetch = detailTools.contains(where: \.needsDetailFetch)
        guard needsFetch else { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        if let fetched = await store.fetchToolDetails(sourceSeqs: sourceSeqs), !fetched.isEmpty {
            detailTools = fetched
            if fetched.contains(where: \.needsDetailFetch) {
                detailError = String(localized: String.LocalizationValue("chat.tool.detail_unavailable"))
            }
        } else {
            detailError = String(localized: String.LocalizationValue("chat.tool.detail_unavailable"))
        }
    }

    /// Metadata hugs its content while messages fill the column, so a run of tool
    /// turns can never read as another wall of assistant bubbles.
    private var summaryLabel: some View {
        HStack(spacing: 0) {
            summaryCapsule(isOpen: false)
            Spacer(minLength: 0)
        }
        // Visual pill stays compact; on iPhone the row keeps a full 44pt target.
        .interfaceFrame(minHeight: Metrics.rowMinHeight)
        .contentShape(Rectangle())
    }

    private func summaryCapsule(isOpen: Bool) -> some View {
        HStack(spacing: Metrics.itemSpacing * interfaceScale) {
            summaryMetadata

            Image(systemName: "chevron.right")
                .interfaceFont(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .interfacePadding(.horizontal, Metrics.horizontalPadding)
        .interfacePadding(.vertical, Metrics.verticalPadding)
        .background(Palette.assistantBubble, in: Capsule(style: .continuous))
        .overlay {
            // The open popover's source stays visibly attached to it.
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isOpen ? 0.08 : 0))
                .allowsHitTesting(false)
        }
        .contentShape(Capsule(style: .continuous))
    }

    private var summaryMetadata: some View {
        HStack(spacing: Metrics.itemSpacing * interfaceScale) {
            Image(systemName: "wrench.and.screwdriver")
                .interfaceFont(.caption2)
                .foregroundStyle(.tertiary)
            Text("chat.agent_activity")
                .sessionFont(.toolMeta)
                .foregroundStyle(.secondary)
            Text("chat.tools_count \(tools.count)")
                .sessionFont(.toolMeta)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private enum Metrics {
        #if os(macOS)
        static let itemSpacing: CGFloat = 6
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 3
        static let rowMinHeight: CGFloat = 0
        static let popoverWidth: CGFloat = 600
        static let popoverMaxHeight: CGFloat = 560
        #else
        static let itemSpacing = Space.sm
        static let horizontalPadding = Space.md
        static let verticalPadding = Space.sm
        static let rowMinHeight = TouchTarget.minimum
        #endif
    }
}
