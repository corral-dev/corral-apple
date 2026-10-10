import Foundation

/// Terminal colours for one appearance, shared by the Mac and iPhone
/// emulators: background, foreground and the 16 ANSI colours tuned for that
/// background (sRGB, 0–255). Agent TUIs and shells pick their own palette from
/// the background the host reports.
struct TerminalColorScheme: Sendable {
    typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    let background: RGB
    let foreground: RGB
    let ansi: [RGB]

    static let dark = TerminalColorScheme(
        background: (20, 23, 31),
        foreground: (224, 227, 232),
        ansi: [
            (31, 31, 36), (232, 92, 92), (115, 204, 115), (230, 199, 102),
            (102, 153, 242), (199, 128, 230), (102, 204, 217), (217, 219, 224),
            (115, 120, 133), (255, 122, 122), (140, 235, 140), (255, 224, 128),
            (140, 184, 255), (230, 158, 255), (140, 235, 242), (250, 250, 252),
        ]
    )

    static let light = TerminalColorScheme(
        background: (255, 255, 255),
        foreground: (31, 36, 41),
        ansi: [
            (36, 41, 47), (207, 34, 46), (17, 99, 41), (125, 78, 0),
            (9, 105, 218), (130, 80, 223), (27, 124, 131), (110, 119, 129),
            (87, 96, 106), (164, 14, 38), (26, 127, 55), (99, 60, 1),
            (33, 139, 255), (164, 117, 249), (49, 146, 170), (140, 149, 159),
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
