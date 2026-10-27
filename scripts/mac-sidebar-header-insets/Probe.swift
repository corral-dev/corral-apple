import AppKit
import SwiftUI

struct BoundsMarker: NSViewRepresentable {
    static var views: [String: NSView] = [:]
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Self.views[name] = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Self.views[name] = view
    }
}

private struct Sidebar: View {
    let cases = [("Pinned", 8), ("Today", 42), ("Friday", 128)]

    var body: some View {
        List {
            ForEach(cases, id: \.0) { title, count in
                Section(isExpanded: .constant(true)) {
                    Text("Session time")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(BoundsMarker(name: "row-\(title)"))
                        .listRowInsets(.vertical, 0)
                } header: {
                    Button {} label: {
                        ProductionHeader(section: HeaderSection(title: title, items: Array(0..<count)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

@main
struct Probe {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 352, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Corral sidebar header inset probe"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var measurements: [[String: Any]] = []
        var failures: [String] = []
        for dark in [false, true] {
            for scale in [1.0, 1.5, 2.0] {
                for width in [260.0, 352.0, 520.0] {
                    BoundsMarker.views = [:]
                    window.setContentSize(NSSize(width: width, height: 500))
                    window.contentView = NSHostingView(rootView: Sidebar()
                        .environment(\.interfaceScale, scale)
                        .preferredColorScheme(dark ? .dark : .light))
                    window.orderBack(nil)
                    let deadline = Date().addingTimeInterval(1)
                    repeat {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                        window.contentView?.layoutSubtreeIfNeeded()
                    } while BoundsMarker.views.count < 6 && Date() < deadline
                    for title in ["Pinned", "Today", "Friday"] {
                        guard let count = BoundsMarker.views["count-\(title)"], count.window === window,
                              let row = BoundsMarker.views["row-\(title)"], row.window === window else {
                            failures.append("Missing mounted bounds: \(title), width=\(width), scale=\(scale)")
                            continue
                        }
                        let countRight = count.convert(count.bounds, to: nil).maxX
                        let rowRight = row.convert(row.bounds, to: nil).maxX
                        let delta = countRight - rowRight
                        measurements.append(["title": title, "width": width, "scale": scale,
                                             "dark": dark, "countRight": countRight,
                                             "rowRight": rowRight, "delta": delta])
                        if abs(delta) > 1 {
                            failures.append("Misaligned \(title): delta=\(delta), width=\(width), scale=\(scale), dark=\(dark)")
                        }
                    }
                }
            }
        }
        let report: [String: Any] = ["measurements": measurements, "failures": failures,
                                     "passed": failures.isEmpty && measurements.count == 54]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !failures.isEmpty || measurements.count != 54 { exit(1) }
    }
}
