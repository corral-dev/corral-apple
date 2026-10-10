import AppKit
import SwiftUI

@main
struct Probe {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("zoom.json")
        let zoom = MacInterfaceZoom(fileURL: url)
        precondition(zoom.percentage == 100)
        for _ in 0..<100 { zoom.increase() }
        precondition(zoom.percentage == 150 && !zoom.canIncrease)
        precondition(MacInterfaceZoom(fileURL: url).percentage == 150)
        for _ in 0..<100 { zoom.decrease() }
        precondition(zoom.percentage == 80 && !zoom.canDecrease)
        zoom.reset()
        precondition(MacInterfaceZoom(fileURL: url).percentage == 100)
        zoom.setPercentage(Int.max)
        precondition(zoom.percentage == 150)
        zoom.setPercentage(Int.min)
        precondition(zoom.percentage == 80)
        zoom.setPercentage(126)
        precondition(zoom.percentage == 130)
        try Data("corrupt".utf8).write(to: url)
        precondition(MacInterfaceZoom(fileURL: url).percentage == 100)
        try JSONEncoder().encode(-500).write(to: url)
        precondition(MacInterfaceZoom(fileURL: url).percentage == 80)
        let parent = directory.appendingPathComponent("file-not-directory")
        try Data().write(to: parent)
        let unwritable = MacInterfaceZoom(fileURL: parent.appendingPathComponent("zoom.json"))
        unwritable.increase()
        precondition(unwritable.percentage == 110 && unwritable.persistenceFailed)
        try FileManager.default.removeItem(at: parent)
        unwritable.setPercentage(110)
        precondition(!unwritable.persistenceFailed)
        precondition(MacInterfaceZoom(fileURL: parent.appendingPathComponent("zoom.json")).percentage == 110)
        print("PASS zoom bounds, normalization, persistent restart, corrupt fallback and save-failure recovery")

        let context = EnvironmentValues().fontResolutionContext
        let font = Font.body.monospaced().weight(.semibold).italic()
        let base = font.resolve(in: context)
        let scaled = font.scaled(by: 1.5).resolve(in: context)
        precondition(abs(scaled.pointSize / base.pointSize - 1.5) < 0.01)
        precondition(base.isMonospaced && scaled.isMonospaced && base.isItalic && scaled.isItalic)
        print("PASS native font scaling preserves monospaced/italic traits")

        let chrome = ControlCapture()
        let chromeHost = NSHostingView(rootView: ControlReader(capture: chrome)
            .modifier(MacZoomScope(zoom: zoom)))
        for percentage in [80, 100, 120, 150] {
            zoom.setPercentage(percentage)
            _ = measure(chromeHost)
            precondition(chrome.size == .regular && chrome.font == nil)
        }
        print("PASS scene scope preserves contextual native font/control size at 80/100/120/150%")

        // The same mounted native host observes changes: no replacement tree or
        // render transform. Measured size must grow with font and design insets.
        let capture = ControlCapture()
        let host = NSHostingView(rootView: Text("English 中文 zoom")
            .interfaceFont(.body).interfacePadding(10).fixedSize()
            .background(ControlReader(capture: capture))
            .modifier(MacZoomContent())
            .modifier(MacZoomScope(zoom: zoom)))
        zoom.reset()
        let small = measure(host)
        precondition(capture.size == .regular)
        zoom.setPercentage(150)
        let large = measure(host)
        precondition(capture.size == .large)
        precondition(large.width > small.width * 1.35 && large.height > small.height * 1.35)
        zoom.setPercentage(80)
        let compact = measure(host)
        precondition(capture.size == .small)
        precondition(compact.width < small.width * 0.9 && compact.height < small.height * 0.9)
        print("PASS mounted native layout reflows at 80/100/150%, size \(compact) / \(small) / \(large)")
        print("PASS scope supplies discrete native control sizes at 80/100/150%")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: window.contentLayoutRect)
        let message = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        message.string = "Selected 中文 text"
        message.isEditable = false
        message.setSelectedRange(NSRange(location: 0, length: 8))
        root.addSubview(message)
        let other = NSTextView(frame: NSRect(x: 0, y: 200, width: 400, height: 100))
        root.addSubview(other)
        window.contentView = root
        let snapshot = MacZoomFocusSnapshot(window: window, textView: message)
        window.makeFirstResponder(window)
        snapshot.restoreAfterLayout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(window.firstResponder === message)
        window.makeFirstResponder(other)
        snapshot.restoreAfterLayout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(window.firstResponder === other)
        print("PASS selected native focus recovers after layout and never steals another control's focus")
    }

    @MainActor
    static func measure<V: View>(_ host: NSHostingView<V>) -> CGSize {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}

@MainActor
final class ControlCapture {
    var size: ControlSize = .mini
    var font: Font?
}

private struct ControlReader: View {
    @Environment(\.controlSize) private var size
    @Environment(\.font) private var font
    let capture: ControlCapture
    var body: some View {
        Color.clear
            .onChange(of: size, initial: true) { _, next in capture.size = next }
            .onChange(of: font, initial: true) { _, next in capture.font = next }
    }
}
