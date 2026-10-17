import AppKit
import Observation
import SwiftUI

/// Only the presented native surface owns a conversation subscription.
@MainActor
@Observable
final class MacPaneLifetime {
    private(set) var isPresented = false
    @ObservationIgnored private weak var store: ConversationStore?
    @ObservationIgnored private var terminalStart: (@MainActor () -> Void)?
    @ObservationIgnored private var terminalStop: (@MainActor () -> Void)?
    @ObservationIgnored private var suspension: Task<Void, Never>?
    @ObservationIgnored private var lease = 0

    func bind(_ store: ConversationStore) { self.store = store }
    func bindTerminal(start: @escaping @MainActor () -> Void,
                      stop: @escaping @MainActor () -> Void) {
        terminalStart = start
        terminalStop = stop
    }

    func present(isTerminal: Bool = false) -> Int {
        lease &+= 1
        isPresented = true
        if isTerminal { terminalStart?() }
        return lease
    }

    func suspend(lease: Int) {
        guard self.lease == lease, isPresented else { return }
        isPresented = false
        terminalStop?()
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

/// Bounded native hosts retain exact reading/composer state. Dormant hosts
/// remain hidden at their measured size and suspend their subscriptions.
@MainActor
final class MacPaneSurfaceCache {
    static let maxDormant = 4

    final class Entry {
        let lifetime = MacPaneLifetime()
        let view = MacPaneHostingView(rootView: AnyView(EmptyView()))
        var configuration: MacPaneSurface.Configuration?
        var lease = 0
        /// Conversation data retained with the native pane, including when
        /// a lazy row retires without a new history read.
        /// Bounded by `retainedKeys` (visible + at most `maxDormant` eligible);
        /// eviction and host reset release them with the entry.
        var store: ConversationStore?
        /// The conversation's native text network (glyphs, views,
        /// measurements), owned here instead of by a view so teardown keeps
        /// it. Released with the entry.
        var document: MacConversationTextDocument?
        /// Last measured window frame, restored while the next layout pass
        /// measures the rebuilt pane (click-to-focus stays accurate).
        var lastFrame: CGRect?
        var bodySize: CGSize = .zero

        init() {
            view.sizingOptions = []
            view.autoresizingMask = [.width, .height]
        }

        /// Retained document for a session, created on first presentation.
        func textDocument() -> MacConversationTextDocument {
            if let document { return document }
            let created = MacConversationTextDocument()
            document = created
            return created
        }
    }
    private var entries: [String: Entry] = [:]

    func entry(for key: String) -> Entry {
        if let entry = entries[key] { return entry }
        let entry = Entry()
        entries[key] = entry
        return entry
    }

    func existingEntry(for key: String) -> Entry? { entries[key] }

    func present(_ entry: Entry, isTerminal: Bool = false) {
        entry.lease = entry.lifetime.present(isTerminal: isTerminal)
    }

    func suspend(_ entry: Entry, key: String, lease: Int, keepingMounted: Bool = false) {
        guard entry.lease == lease else { return }
        if let window = entry.view.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: entry.view) {
            window.makeFirstResponder(nil)
        }
        entry.lifetime.suspend(lease: lease)
        entry.view.isHidden = true
        if !keepingMounted {
            entry.view.removeFromSuperview()
            entry.view.rootView = AnyView(EmptyView())
            entry.configuration = nil
            entry.store = nil
            entry.document = nil
            if entries[key] === entry { entries[key] = nil }
        }
    }

    /// Drop a retained dormant entry and release its conversation data.
    func evict(_ key: String) {
        guard let entry = entries[key] else { return }
        suspend(entry, key: key, lease: entry.lease)
    }

    func retainedKeys(visible: [String], previous: [String], eligible: (String) -> Bool) -> [String] {
        let dormant = previous.filter {
            !visible.contains($0) && eligible($0) && entries[$0]?.lifetime.canRetain != false
        }.prefix(Self.maxDormant)
        return visible + dormant
    }

    func reset() {
        for (key, entry) in entries { suspend(entry, key: key, lease: entry.lease) }
        entries.removeAll()
    }

    static func retireResponder(in frame: CGRect?) {
        guard let frame, let window = NSApp.windows.first(where: { $0.title == "Corral" && $0.isVisible }),
              let content = window.contentView, let responder = window.firstResponder as? NSView else { return }
        let point = responder.convert(CGPoint(x: responder.bounds.midX, y: responder.bounds.midY), to: content)
        let global = CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
        if frame.contains(global) { window.makeFirstResponder(nil) }
    }

    #if DEBUG
    func isMounted(_ key: String) -> Bool { entries[key]?.lifetime.isPresented == true }
    var dormantCount: Int { entries.values.filter { !$0.lifetime.isPresented }.count }
    func store(for key: String) -> ConversationStore? { entries[key]?.lifetime.inspectionStore }
    #endif
}

/// A dormant pane keeps its hosting root for an instant return, but laying
/// out what nobody can see cost about a third of each warm switch (measured
/// 2026-10-11). Layout is deferred while hidden and runs once on reveal.
class MacPaneHostingView: NSHostingView<AnyView> {
    private var deferredLayout = false

    override func layout() {
        if isHidden {
            deferredLayout = true
            return
        }
        super.layout()
    }

    override var isHidden: Bool {
        didSet {
            if !isHidden, deferredLayout {
                deferredLayout = false
                needsLayout = true
            }
        }
    }
}

/// Native hosting boundary with bounded dormant mounts. Equivalent inputs
/// keep the root intact; hidden mounts suspend watches and retire responders.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: SessionSummary
    let metadataStore: SessionListStore?
    var allowsClose = true
    var autoFocusComposer = false
    var isPresented = true
    struct Configuration: Equatable {
        let session: SessionSummary
        let client: ObjectIdentifier?
        let metadata: ObjectIdentifier?
        let allowsClose: Bool
        let autoFocusComposer: Bool
        let interfaceScale: CGFloat
        /// Excluded from equality: a pane add/remove must not rebuild every
        /// visible pane's root view. Pane content reads focus and the live
        /// pane roster from the workspace, so it needs no rebuilt root.
        let visibleKeys: [String]
        let colorScheme: ColorScheme
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
        let layoutDirection: LayoutDirection
        let font: Font?
        let controlSize: ControlSize
        let dynamicTypeSize: DynamicTypeSize
        let reduceMotion: Bool

        static func == (lhs: Configuration, rhs: Configuration) -> Bool {
            lhs.session == rhs.session
                && lhs.client == rhs.client
                && lhs.metadata == rhs.metadata
                && lhs.allowsClose == rhs.allowsClose
                && lhs.autoFocusComposer == rhs.autoFocusComposer
                && lhs.interfaceScale == rhs.interfaceScale
                && lhs.colorScheme == rhs.colorScheme
                && lhs.locale == rhs.locale
                && lhs.calendar == rhs.calendar
                && lhs.timeZone == rhs.timeZone
                && lhs.layoutDirection == rhs.layoutDirection
                && lhs.font == rhs.font
                && lhs.controlSize == rhs.controlSize
                && lhs.dynamicTypeSize == rhs.dynamicTypeSize
                && lhs.reduceMotion == rhs.reduceMotion
        }
    }

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
        weak var entry: MacPaneSurfaceCache.Entry?
        var key = ""

        /// Dormant mounts stay in the window at their last frame (often under
        /// the visible pane) and must never take its clicks. Doing this in
        /// AppKit instead of SwiftUI hit-testing modifiers keeps a switch
        /// from re-inserting every mounted host into the window.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let entry, entry.lifetime.isPresented, !entry.view.isHidden else { return nil }
            return super.hitTest(point)
        }

        override func layout() {
            super.layout()
            // Synchronous: click-to-focus reads paneFrames on the click event,
            // and a deferred write is always one layout behind during resizes.
            // AppKit layout runs outside SwiftUI body evaluation, so assigning
            // the observable here is safe.
            guard let entry = self.entry, entry.lifetime.isPresented,
                  entry.view.superview === self, let content = self.window?.contentView,
                  let workspace = self.workspace else { return }
            let native = self.convert(self.bounds, to: content)
            let frame = CGRect(x: native.minX,
                               y: content.isFlipped ? native.minY : content.bounds.height - native.maxY,
                               width: native.width, height: native.height)
            entry.lastFrame = frame
            if workspace.paneFrames[self.key] != frame { workspace.paneFrames[self.key] = frame }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cache: workspace.paneSurfaces, key: session.key)
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let entry = coordinator.entry
        let mount = Mount(frame: NSRect(origin: .zero, size: entry.view.bounds.size))
        mount.workspace = workspace
        mount.entry = entry
        mount.key = session.key
        // Never attach a width-tracking native text network to a zero frame.
        entry.view.removeFromSuperview()
        mount.addSubview(entry.view)
        update(coordinator)
        return mount
    }

    func updateNSView(_ mount: NSView, context: Context) {
        update(context.coordinator)
        if !isPresented { workspace.paneFrames[session.key] = nil }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ mount: NSView, coordinator: Coordinator) {
        guard coordinator.entry.lease == coordinator.lease,
              coordinator.entry.view.superview === mount else { return }
        (mount as? Mount)?.workspace?.paneFrames[coordinator.key] = nil
        coordinator.cache.suspend(coordinator.entry, key: coordinator.key,
                                  lease: coordinator.lease, keepingMounted: true)
    }

    private func update(_ coordinator: Coordinator) {
        let entry = coordinator.entry
        if isPresented, !entry.lifetime.isPresented {
            coordinator.cache.present(entry, isTerminal: workspace.mode(for: session.key) == .terminal)
            coordinator.lease = entry.lease
            entry.view.isHidden = false
        } else if !isPresented, entry.lifetime.isPresented {
            coordinator.cache.suspend(entry, key: session.key, lease: coordinator.lease, keepingMounted: true)
        }
        guard isPresented else { return }
        let configuration = Configuration(
            session: session, client: appModel.clientIdentity,
            metadata: metadataStore.map(ObjectIdentifier.init),
            allowsClose: allowsClose, autoFocusComposer: autoFocusComposer,
            interfaceScale: interfaceScale, visibleKeys: visibleKeys, colorScheme: colorScheme,
            locale: locale, calendar: calendar, timeZone: timeZone, layoutDirection: layoutDirection,
            font: font, controlSize: controlSize, dynamicTypeSize: dynamicTypeSize, reduceMotion: reduceMotion)
        guard entry.configuration != configuration else { return }
        entry.configuration = configuration
        entry.view.rootView = AnyView(MacPaneView(session: session, metadataStore: metadataStore,
                    allowsClose: allowsClose, autoFocusComposer: autoFocusComposer,
                    retainedStore: entry.store?.clientIdentity == appModel.clientIdentity ? entry.store : nil,
                    retainedBodySize: entry.bodySize)
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
            .environment(\.dynamicTypeSize, dynamicTypeSize))
    }
}
