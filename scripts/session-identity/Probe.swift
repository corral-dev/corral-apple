import AppKit
import SwiftUI

@main
struct SessionIdentityProbe {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for dark in [false, true] {
            for (width, height, scale) in [(320.0, 480.0, 1.0), (390, 620, 1), (390, 260, 1),
                                            (280, 600, 1.5), (800, 760, 1), (1600, 1000, 1)] {
                let empty = render(title: "No title icon 123", width: width, height: height, scale: scale, dark: dark)
                let marked = render(title: "🎨 Session", width: width, height: height, scale: scale, dark: dark)
                var changed: [CGPoint] = []
                for y in 0..<empty.pixelsHigh {
                    for x in 0..<empty.pixelsWide where differs(empty, marked, x: x, y: y) {
                        changed.append(CGPoint(x: x, y: y))
                    }
                }
                require(!changed.isEmpty, "icon paints at \(width)x\(height), dark=\(dark)")
                let xs = changed.map(\.x), ys = changed.map(\.y)
                let bounds = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                                    width: (xs.max() ?? 0) - (xs.min() ?? 0) + 1,
                                    height: (ys.max() ?? 0) - (ys.min() ?? 0) + 1)
                require(bounds.minX > width * 0.55, "decoration stays in trailing part of pane")
                require(bounds.width <= width * 0.36 && bounds.height <= height * 0.36,
                        "decoration never dominates either dimension")
                require(bounds.maxX <= width - 12 && bounds.maxY <= height - 12,
                        "icon keeps edge clearance")
                let foreground = render(title: "🎨 Session", width: width, height: height,
                                        scale: scale, dark: dark, foreground: true)
                let plainForeground = render(title: "Plain", width: width, height: height,
                                             scale: scale, dark: dark, foreground: true)
                // The foreground covers the identity mark in the same region;
                // its opaque pixels must be identical with and without the mark.
                for y in Int(height - 100)..<Int(height - 30) {
                    for x in Int(width - 100)..<Int(width - 30) {
                        require(!differs(foreground, plainForeground, x: x, y: y),
                                "foreground ink/surface is never covered by decoration")
                    }
                }
            }
        }
        print("PASS light/dark phone, keyboard-height, narrow split, desktop and zoom proportions; opaque foreground unchanged")
    }

    private static func render(title: String, width: Double, height: Double, scale: Double,
                               dark: Bool, foreground: Bool = false) -> NSBitmapImageRep {
        let view = Color.clear
            .overlay(alignment: .bottomTrailing) {
                if foreground { Rectangle().fill(.red).frame(width: 90, height: 90).padding(20) }
            }
            .frame(width: width, height: height)
            .background { SessionIdentityBackground(title: title) }
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.interfaceScale, scale)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { preconditionFailure("native raster missing") }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func differs(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        var a = [Int](repeating: 0, count: 4), b = a
        lhs.getPixel(&a, atX: x, y: y)
        rhs.getPixel(&b, atX: x, y: y)
        return zip(a, b).contains { abs($0 - $1) > 1 }
    }

    private static func require(_ value: Bool, _ message: String) {
        guard value else { preconditionFailure(message) }
    }
}
