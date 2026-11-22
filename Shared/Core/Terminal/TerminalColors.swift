import Foundation

/// Terminal colours for one appearance, shared by the Mac and iPhone
/// emulators: background, foreground and the 16 ANSI colours tuned for that
/// background (sRGB, 0–255). Agent TUIs and shells pick their own palette from
/// the background the host reports.
nonisolated struct TerminalColorScheme: Sendable {
    typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    let background: RGB
    let foreground: RGB
    let ansi: [RGB]

    static let dark = TerminalColorScheme(
        background: (20, 23, 31),
        foreground: (232, 235, 240),
        ansi: [
            (32, 37, 48), (242, 82, 82), (62, 214, 114), (245, 200, 66),
            (74, 148, 255), (212, 116, 255), (46, 212, 224), (206, 212, 222),
            (114, 122, 138), (255, 117, 117), (104, 240, 152), (255, 222, 107),
            (122, 179, 255), (232, 158, 255), (107, 238, 247), (255, 255, 255),
        ]
    )

    static let light = TerminalColorScheme(
        background: (255, 255, 255),
        foreground: (24, 28, 34),
        ansi: [
            (31, 36, 44), (209, 47, 47), (22, 138, 62), (178, 114, 0),
            (26, 102, 224), (158, 66, 212), (10, 132, 148), (207, 214, 223),
            (110, 119, 133), (235, 68, 68), (30, 168, 79), (209, 138, 0),
            (48, 128, 250), (184, 88, 238), (16, 158, 176), (242, 244, 248),
        ]
    )

    /// `#rrggbb` pair reported to the host (`terminal.theme`).
    var theme: TerminalTheme {
        TerminalTheme(background: Self.hex(background), foreground: Self.hex(foreground))
    }

    private static func hex(_ rgb: RGB) -> String {
        String(format: "#%02x%02x%02x", rgb.red, rgb.green, rgb.blue)
    }
}
