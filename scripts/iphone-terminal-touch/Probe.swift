import SwiftTerm
import UIKit

// Isolated transport only. The production UIKit terminal, gesture coordinator,
// selection service and wheel encoder are compiled unchanged into this probe.
struct TerminalGrid: Equatable { let cols: Int; let rows: Int }
struct TerminalTheme { let background: String; let foreground: String }
enum TerminalPromptOutcome { case landed, superseded, absent, failed }
@MainActor protocol TerminalStreamSink: AnyObject {
    func terminalReset(grid: TerminalGrid, data: Data)
    func terminalFeed(_ data: Data)
}
@MainActor final class RemoteTerminalStream {
    enum Phase { case live, connecting }
    var phase = Phase.live
    weak var sink: TerminalStreamSink?
    let input = Input()
    func updateTheme(_ theme: TerminalTheme) {}
    func updateFit(_ fit: TerminalGrid) {}
    final class Input {
        var bytes: [UInt8] = []
        func send(_ data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
        func paste(_ text: String) { bytes.append(contentsOf: text.utf8) }
    }
}

@MainActor final class ProbePan: UIPanGestureRecognizer {
    var phase = UIGestureRecognizer.State.began
    var offset = CGPoint.zero
    var point = CGPoint(x: 80, y: 100)
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { offset }
    override func location(in view: UIView?) -> CGPoint { point }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
}

@MainActor final class ProbePress: UILongPressGestureRecognizer {
    override var state: UIGestureRecognizer.State { get { .began } set {} }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 12, y: 5) }
}

@MainActor final class ProbeTap: UITapGestureRecognizer {
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 300, y: 400) }
}

@main
final class ProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var checks: [String] = []

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Probe", sessionRole: session.role)
        configuration.delegateClass = ProbeScene.self
        return configuration
    }

    func start(in scene: UIWindowScene) {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        Task {
            do {
                try await runChecks()
                finish(ok: true, error: nil)
            } catch { finish(ok: false, error: String(describing: error)) }
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "TerminalTouchProbe", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]) }
        checks.append(message)
    }

    private func feed(_ view: ShellTerminalHost, _ text: String) { view.terminalFeed(Data(text.utf8)) }

    private func runChecks() async throws {
        let view = ShellTerminalHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.configure(presented: true, allowsInput: true, isAgent: true)
        let stream = RemoteTerminalStream()
        view.bind(stream)
        window?.rootViewController?.view.addSubview(view)
        view.resize(cols: 50, rows: 30)
        let pans = { (view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer } }
        guard let wheel = pans().first(where: { $0.delegate is TerminalTouchInteraction }),
              let touch = wheel.delegate as? TerminalTouchInteraction else {
            throw NSError(domain: "missing production wheel recognizer", code: 1)
        }
        try require(pans().count == 2, "default terminal has native history pan and one wheel pan")
        feed(view, "\u{1b}[?1002h\u{1b}[?1006h")
        try require(pans().count == 2, "mouse mode adds no button-drag recognizer")
        try require(!view.isFirstResponder && !view.hasActiveSelection, "entering agent terminal selects nothing and keeps keyboard closed")
        let drag = ProbePan()
        _ = touch.perform(NSSelectorFromString("scroll:"), with: drag)
        drag.phase = .changed
        drag.offset.y = 60
        _ = touch.perform(NSSelectorFromString("scroll:"), with: drag)
        let up = String(decoding: stream.input.bytes, as: UTF8.self)
        try require(up.contains("\u{1b}[<64;"), "downward finger movement sends real upward SGR wheels")
        try require(!up.contains("\u{1b}[A") && !up.contains("\u{1b}[B") && !up.contains("m"),
                    "scrolling sends no arrow keys or mouse release")
        try require(!view.isFirstResponder && !view.hasActiveSelection, "wheel scrolling neither selects text nor opens keyboard")
        stream.input.bytes = []
        drag.offset.y = 0
        _ = touch.perform(NSSelectorFromString("scroll:"), with: drag)
        try require(String(decoding: stream.input.bytes, as: UTF8.self).contains("\u{1b}[<65;"),
                    "upward finger movement sends downward wheels")
        drag.phase = .cancelled
        _ = touch.perform(NSSelectorFromString("scroll:"), with: drag)

        // Exercise SwiftTerm's real long-press hit recording and the added
        // target, without injecting pointer/touch events into the computer.
        feed(view, "\u{1b}[2J\u{1b}[HSelect this stable reply")
        stream.input.bytes = []
        let press = ProbePress()
        _ = view.perform(NSSelectorFromString("longPress:"), with: press)
        _ = touch.perform(NSSelectorFromString("selectText:"), with: press)
        try await Task.sleep(for: .milliseconds(30))
        try require(view.hasActiveSelection && view.selection.getSelectedText() == "Select",
                    "long press directly selects the native word")
        try require(!view.allowMouseReporting, "explicit selection takes precedence over agent mouse tracking")
        let selected = view.selection.getSelectedText()
        for tick in 0..<20 { feed(view, "\u{1b}[8;1Hstatus \(tick)\r\n") }
        try require(view.hasActiveSelection && view.selection.getSelectedText() == selected,
                    "selection survives unrelated streaming redraws")
        let cell = view.getOptimalFrameSize()
        let handle = ProbePan()
        handle.point = CGPoint(x: cell.width / 50 * 6, y: cell.height / 30 / 2)
        _ = view.perform(NSSelectorFromString("panSelectionHandler:"), with: handle)
        handle.phase = .changed
        handle.point.x = cell.width / 50 * 10
        _ = view.perform(NSSelectorFromString("panSelectionHandler:"), with: handle)
        try require(view.selection.getSelectedText() == "Select this",
                    "native handle extends range after output: \(view.selection.getSelectedText())")
        let savedPasteboard = UIPasteboard.general.items
        view.copy(nil)
        try require(UIPasteboard.general.string == "Select this", "native Copy contains the selected text")
        UIPasteboard.general.items = savedPasteboard
        try require(!view.hasActiveSelection && view.allowMouseReporting, "Copy restores default scrolling immediately")
        try require(stream.input.bytes.isEmpty, "selection and Copy never send agent input")

        _ = view.perform(NSSelectorFromString("longPress:"), with: press)
        _ = touch.perform(NSSelectorFromString("selectText:"), with: press)
        try await Task.sleep(for: .milliseconds(30))
        let tap = ProbeTap()
        view.addGestureRecognizer(tap)
        _ = view.perform(NSSelectorFromString("singleTap:"), with: tap)
        view.removeGestureRecognizer(tap)
        try require(!view.hasActiveSelection && view.allowMouseReporting, "tapping outside selection cancels locally")
        try require(stream.input.bytes.isEmpty, "selection cancellation sends no agent click")

        view.selectAll(nil)
        view.configure(presented: false, allowsInput: true, isAgent: true)
        try require(!view.hasActiveSelection && view.allowMouseReporting, "leaving terminal clears transient selection")
        view.configure(presented: true, allowsInput: false, isAgent: true)
        stream.input.bytes = []
        view.sendTouchScroll(lines: 3, at: CGPoint(x: 80, y: 80))
        try require(stream.input.bytes.isEmpty, "read-only terminal never forwards wheels")

        view.configure(presented: true, allowsInput: true, isAgent: true)
        feed(view, "\u{1b}[?1002l\u{1b}[?1006l\u{1b}[?1049h")
        view.sendTouchScroll(lines: 3, at: .zero)
        try require(stream.input.bytes.isEmpty, "alternate screen without mouse support never falls back to arrows")
        feed(view, "\u{1b}[?1049l\u{1b}[2J\u{1b}[H")
        for row in 0..<300 { feed(view, "history row \(row)\r\n") }
        view.scrollTo(row: 70)
        let top = view.getTerminal().getTopVisibleRow()
        feed(view, "later output\r\n")
        try require(view.getTerminal().getTopVisibleRow() == top, "reading history remains stable during new output")
        view.scroll(toPosition: 1)
        feed(view, "new live output\r\n")
        try require(view.scrollPosition == 1, "returning to bottom follows new output")
        try require(stream.input.bytes.isEmpty, "local history scrolling never writes agent input")

        view.configure(presented: true, allowsInput: true, isAgent: false)
        feed(view, "\u{1b}[?1000h\u{1b}[?1006h")
        view.sendTouchScroll(lines: 2, at: CGPoint(x: 80, y: 80))
        try require(String(decoding: stream.input.bytes, as: UTF8.self).contains("\u{1b}[<64;"),
                    "project terminal shares real-wheel routing")
        view.unbind()
    }

    private func finish(ok: Bool, error: String?) {
        var result: [String: Any] = ["ok": ok, "checks": checks, "count": checks.count]
        if let error { result["error"] = error }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("touch-result.json")
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination) }
        catch { print(error) }
        exit(ok ? 0 : 1)
    }
}

final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? ProbeApp else { return }
        app.start(in: scene)
    }
}
