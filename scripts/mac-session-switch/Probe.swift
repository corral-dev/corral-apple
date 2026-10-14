import AppKit
import Observation
import SwiftUI

// The fixture substitutes only transport/product inputs, not the native cache.
@MainActor final class ConversationStore {
    var clientIdentity: ObjectIdentifier? { nil }
    var messages: [Message] = []
    var stops = 0
    var stopContinuation: CheckedContinuation<Void, Never>?
    var pause = false
    func stop() async {
        stops += 1
        if pause { await withCheckedContinuation { stopContinuation = $0 } }
    }
}
struct Message { var text: String? }
enum ConversationHistoryBudget { static let maxOfficialMessagesPerSession = 400 }
struct SessionSummary: Equatable { let key: String }
@MainActor final class SessionListStore {}
@MainActor @Observable final class AppModel {
    var clientIdentity: ObjectIdentifier? { nil }
}
@MainActor @Observable final class MacWorkspace {
    let paneSurfaces = MacPaneSurfaceCache()
    var paneFrames: [String: CGRect] = [:]
    var focusedKey: String?
    enum PaneMode { case chat, terminal }
    func mode(for key: String) -> PaneMode { .chat }
}
struct MacPaneView: View {
    let session: SessionSummary
    let metadataStore: SessionListStore?
    var allowsClose = true
    var autoFocusComposer = false
    var retainedStore: ConversationStore? = nil
    var retainedBodySize: CGSize = .zero
    var body: some View { Text(session.key) }
}
extension EnvironmentValues {
    @Entry var interfaceScale: CGFloat = 1
    @Entry var macVisiblePaneKeys: [String] = []
}

@main
struct Probe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let cache = MacPaneSurfaceCache()
        let a = cache.entry(for: "a")
        let store = ConversationStore()
        a.lifetime.bind(store)
        cache.present(a)
        let oldLease = a.lease
        cache.suspend(a, key: "a", lease: oldLease, keepingMounted: true)
        await a.lifetime.waitForSuspension()
        precondition(store.stops == 1)
        precondition(cache.entry(for: "a") === a)
        cache.present(a)
        cache.suspend(a, key: "a", lease: oldLease, keepingMounted: true)
        precondition(a.lifetime.isPresented, "old representable must not suspend a new mount")

        store.pause = true
        cache.suspend(a, key: "a", lease: a.lease, keepingMounted: true)
        for _ in 0..<100 where store.stopContinuation == nil { await Task.yield() }
        precondition(store.stopContinuation != nil)
        cache.present(a)
        var finished = false
        let resume = Task { await a.lifetime.waitForSuspension(); finished = true }
        await Task.yield()
        precondition(!finished, "watch must wait for outstanding unwatch")
        store.stopContinuation?.resume()
        await resume.value
        precondition(finished)
        store.pause = false

        var recent = ["a"]
        for index in 0..<12 {
            let key = "dormant-\(index)"
            let entry = cache.entry(for: key)
            cache.present(entry)
            cache.suspend(entry, key: key, lease: entry.lease, keepingMounted: true)
            let roster = cache.retainedKeys(visible: ["a"], previous: [key] + recent) { _ in true }
            for retired in recent where !roster.contains(retired) {
                let retiring = cache.entry(for: retired)
                cache.suspend(retiring, key: retired, lease: retiring.lease)
            }
            recent = roster
        }
        precondition(cache.dormantCount == MacPaneSurfaceCache.maxDormant)
        precondition(cache.entry(for: "a") === a, "visible entries cannot be evicted")

        let terminal = cache.entry(for: "terminal")
        var terminalStarts = 0
        var terminalStops = 0
        terminal.lifetime.bindTerminal(start: { terminalStarts += 1 },
                                       stop: { terminalStops += 1 })
        cache.present(terminal, isTerminal: true)
        precondition(terminalStarts == 1)
        cache.suspend(terminal, key: "terminal", lease: terminal.lease, keepingMounted: true)
        precondition(terminalStops == 1)
        cache.present(terminal, isTerminal: true)
        precondition(terminalStarts == 2, "a returning terminal resumes its stream")
        cache.suspend(terminal, key: "terminal", lease: terminal.lease, keepingMounted: true)
        cache.present(terminal, isTerminal: false)
        precondition(terminalStarts == 2, "a hidden terminal in chat mode stays stopped")
        cache.suspend(terminal, key: "terminal", lease: terminal.lease)
        precondition(cache.entry(for: "terminal") !== terminal)
        let big = cache.entry(for: "big")
        let bigStore = ConversationStore()
        bigStore.messages = [Message(text: String(repeating: "x", count: 2 * 1024 * 1024 + 1))]
        big.lifetime.bind(bigStore)
        cache.present(big)
        precondition(!cache.retainedKeys(visible: [], previous: ["big"]) { _ in true }.contains("big"))
        cache.suspend(big, key: "big", lease: big.lease)
        precondition(cache.entry(for: "big") !== big)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Corral"
        window.orderFront(nil)
        let responder = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(responder)
        window.makeFirstResponder(responder)
        MacPaneSurfaceCache.retireResponder(in: CGRect(x: 0, y: 0, width: 500, height: 300))
        precondition(window.firstResponder !== responder)
        window.orderOut(nil)
        cache.reset()
        await a.lifetime.waitForSuspension()
        precondition(!a.lifetime.isPresented)
        precondition(cache.entry(for: "a") !== a, "host switch must release every surface")
        await exerciseRetainedLayout()
        print("PASS native surfaces: reuse, stale lease, unwatch ordering, dormant bound, terminal/large release, responder retirement, host reset")
    }
}
