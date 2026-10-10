import AppKit
import Observation
import SwiftUI

/// Only the presented native surface owns a conversation subscription.
@MainActor
@Observable
final class MacPaneLifetime {
    private(set) var isPresented = false
    @ObservationIgnored private weak var store: ConversationStore?
    @ObservationIgnored private var suspension: Task<Void, Never>?
    @ObservationIgnored private var lease = 0

    func bind(_ store: ConversationStore) { self.store = store }

    func present() -> Int {
        lease &+= 1
        isPresented = true
        return lease
    }

    func suspend(lease: Int) {
        guard self.lease == lease, isPresented else { return }
        isPresented = false
        guard let store else { return }
        let previous = suspension
        suspension = Task {
            await previous?.value
            await store.stop()
        }
    }

    func waitForSuspension() async {
        await suspension?.value
    }

    var canRetain: Bool {
        guard let store else { return true }
        return store.messages.count <= ConversationHistoryBudget.maxOfficialMessagesPerSession
            && store.messages.reduce(0, { $0 + ($1.text?.utf8.count ?? 0) }) <= 2 * 1024 * 1024
    }

    #if DEBUG
    var inspectionStore: ConversationStore? { store }
    #endif
}

private struct MacPaneLifetimeKey: EnvironmentKey {
    static let defaultValue: MacPaneLifetime? = nil
}

extension EnvironmentValues {
    var macPaneLifetime: MacPaneLifetime? {
        get { self[MacPaneLifetimeKey.self] }
        set { self[MacPaneLifetimeKey.self] = newValue }
    }
}

/// Reuse complete native chat surfaces rather than rebuilding a SwiftUI/TextKit
/// tree for each sidebar selection. Dormant surfaces stay mounted but hidden;
/// presentation suspension stops their RPC watch and retires their responder.
@MainActor
final class MacPaneSurfaceCache {
    static let maxDormant = 4

    final class Entry {
        let lifetime = MacPaneLifetime()
        let view = NSHostingView(rootView: AnyView(EmptyView()))
        var lease = 0
        var recency = 0
        var keepDormant = true

        init() {
            view.sizingOptions = []
            view.autoresizingMask = [.width, .height]
        }
    }

    private var entries: [String: Entry] = [:]
    private var serial = 0

    func entry(for key: String) -> Entry {
        if let entry = entries[key] { return entry }
        let entry = Entry()
        entries[key] = entry
        return entry
    }

    func present(_ entry: Entry) {
        serial &+= 1
        entry.recency = serial
        entry.lease = entry.lifetime.present()
        entry.view.isHidden = false
    }

    func suspend(_ entry: Entry, key: String, lease: Int, keepingMounted: Bool = false) {
        guard entry.lease == lease else { return }
        // NSWindow does not own its first responder. Retire it while the whole
        // native surface is alive, before its text/field editor can leave.
        if let window = entry.view.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: entry.view) {
            window.makeFirstResponder(nil)
        }
        entry.lifetime.suspend(lease: lease)
        entry.view.isHidden = true
        if keepingMounted { return }
        entry.view.removeFromSuperview()
        if entries[key] === entry { entries[key] = nil }
        entry.view.rootView = AnyView(EmptyView())
    }

    func retainedKeys(visible: [String], previous: [String], eligible: (String) -> Bool) -> [String] {
        let dormant = previous.filter {
            !visible.contains($0) && eligible($0) && entries[$0]?.lifetime.canRetain != false
        }.prefix(Self.maxDormant)
        return visible + dormant
    }

    func reset() {
        for (key, entry) in entries {
            entry.keepDormant = false
            suspend(entry, key: key, lease: entry.lease)
        }
        entries.removeAll()
    }

    #if DEBUG
    func isMounted(_ key: String) -> Bool {
        entries[key]?.view.window != nil && entries[key]?.lifetime.isPresented == true
    }
    var dormantCount: Int { entries.values.filter { !$0.lifetime.isPresented }.count }
    func store(for key: String) -> ConversationStore? { entries[key]?.lifetime.inspectionStore }
    #endif
}

/// NSHostingView is Apple's public SwiftUI/AppKit embedding boundary. The
/// outer SwiftUI split still owns placement, dividers and pane motion.
struct MacPaneSurface: NSViewRepresentable {
    @Environment(AppModel.self) private var appModel
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.macVisiblePaneKeys) private var visibleKeys
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.font) private var font
    @Environment(\.controlSize) private var controlSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: SessionSummary
    let metadataStore: SessionListStore?
    var allowsClose = true
    var autoFocusComposer = false
    var isPresented = true

    final class Coordinator {
        let cache: MacPaneSurfaceCache
        let key: String
        let entry: MacPaneSurfaceCache.Entry
        var lease = 0

        init(cache: MacPaneSurfaceCache, key: String) {
            self.cache = cache
            self.key = key
            entry = cache.entry(for: key)
        }
    }

    final class Mount: NSView {
        weak var workspace: MacWorkspace?
        weak var lifetime: MacPaneLifetime?
        var key = ""

        override func layout() {
            super.layout()
            // A separate NSHostingView has its own SwiftUI global coordinate
            // space. Publish the native window coordinates for pane focus.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifetime?.isPresented == true, let content = self.window?.contentView,
                      let workspace = self.workspace else { return }
                let native = self.convert(self.bounds, to: content)
                let frame = CGRect(x: native.minX,
                                   y: content.isFlipped ? native.minY : content.bounds.height - native.maxY,
                                   width: native.width, height: native.height)
                if workspace.paneFrames[self.key] != frame { workspace.paneFrames[self.key] = frame }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cache: workspace.paneSurfaces, key: session.key)
    }

    func makeNSView(context: Context) -> NSView {
        let mount = Mount()
        mount.workspace = workspace
        mount.key = session.key
        mount.lifetime = context.coordinator.entry.lifetime
        let entry = context.coordinator.entry
        entry.view.removeFromSuperview()
        mount.addSubview(entry.view)
        entry.view.frame = mount.bounds
        update(context.coordinator)
        return mount
    }

    func updateNSView(_ mount: NSView, context: Context) {
        update(context.coordinator)
        if !isPresented { workspace.paneFrames[session.key] = nil }
        mount.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ mount: NSView, coordinator: Coordinator) {
        if coordinator.entry.lease == coordinator.lease, let mount = mount as? Mount {
            mount.workspace?.paneFrames[coordinator.key] = nil
        }
        coordinator.cache.suspend(coordinator.entry, key: coordinator.key, lease: coordinator.lease)
    }

    private func update(_ coordinator: Coordinator) {
        let entry = coordinator.entry
        if isPresented, !entry.lifetime.isPresented {
            coordinator.cache.present(entry)
            coordinator.lease = entry.lease
        } else if !isPresented, entry.lifetime.isPresented {
            coordinator.cache.suspend(entry, key: coordinator.key, lease: coordinator.lease, keepingMounted: true)
        }
        // Terminals are never kept offscreen: disposal retires their sizing vote.
        entry.keepDormant = workspace.mode(for: session.key) == .chat
        entry.view.rootView = AnyView(
            MacPaneView(session: session, metadataStore: metadataStore,
                        allowsClose: allowsClose, autoFocusComposer: autoFocusComposer)
                .environment(appModel)
                .environment(workspace)
                .environment(\.macPaneLifetime, entry.lifetime)
                .environment(\.macVisiblePaneKeys, visibleKeys)
                .environment(\.interfaceScale, interfaceScale)
                .environment(\.colorScheme, colorScheme)
                .environment(\.locale, locale)
                .environment(\.calendar, calendar)
                .environment(\.timeZone, timeZone)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.font, font)
                .environment(\.controlSize, controlSize)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .disabled(!isPresented)
                .accessibilityHidden(!isPresented)
        )
    }
}
