import Foundation

/// sRGB 8-bit triple for terminal surface colors and luminance calculations.
nonisolated struct TerminalRGB: Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ rgb: TerminalColorScheme.RGB) {
        self.red = rgb.red
        self.green = rgb.green
        self.blue = rgb.blue
    }

    /// Converts a 16-bit SwiftTerm color component (0...65535) to 8-bit sRGB.
    init(red16: UInt16, green16: UInt16, blue16: UInt16) {
        self.red = UInt8((UInt32(red16) * 255 + 32_767) / 65_535)
        self.green = UInt8((UInt32(green16) * 255 + 32_767) / 65_535)
        self.blue = UInt8((UInt32(blue16) * 255 + 32_767) / 65_535)
    }

    /// WCAG 2.1 relative luminance in `[0, 1]`.
    var relativeLuminance: Double {
        func linearize(_ channel: UInt8) -> Double {
            let s = Double(channel) / 255.0
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// True when light foreground chrome (`.dark` color scheme) achieves higher
    /// WCAG contrast against this background than dark ink (`sqrt(1.05 * 0.05) - 0.05`).
    var prefersDarkChrome: Bool {
        relativeLuminance < 0.1791
    }
}

/// Terminal colours for one appearance, shared by the Mac and iPhone
/// emulators: background, foreground and the 16 ANSI colours tuned for that
/// background (sRGB, 0–255). Agent TUIs and shells pick their own palette from
/// the background the host reports.
nonisolated struct TerminalColorScheme: Sendable {
    typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    let background: RGB
    let foreground: RGB
    let ansi: [RGB]

    static func forAppearance(isDark: Bool) -> TerminalColorScheme {
        isDark ? .dark : .light
    }

    var backgroundRGB: TerminalRGB { TerminalRGB(background) }
    var foregroundRGB: TerminalRGB { TerminalRGB(foreground) }

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

/// Resolves the dominant visible background color of a terminal viewport so mobile
/// surrounding chrome can match full-canvas TUI themes without flashing on localized diffs.
nonisolated enum TerminalSurfaceBackgroundResolver {
    nonisolated enum CellColor: Equatable, Sendable {
        case defaultColor
        case ansi256(UInt8)
        case trueColor(TerminalRGB)
    }

    nonisolated struct CellSample: Equatable, Sendable {
        let width: Int
        let foreground: CellColor
        let background: CellColor
        let isInverse: Bool
    }

    static func resolve(
        rows: [[CellSample]],
        columns: Int,
        defaultBackground: TerminalRGB,
        defaultForeground: TerminalRGB,
        palette: [TerminalRGB]
    ) -> TerminalRGB {
        guard !rows.isEmpty, columns > 0 else { return defaultBackground }

        var counts: [TerminalRGB: Int] = [:]
        var totalWeight = 0

        for row in rows {
            var rowWeight = 0
            for cell in row {
                // Skip wide-character continuation cells; the leading cell carries the column width.
                guard cell.width != 0 else { continue }
                let weight = max(1, cell.width)
                let resolved = effectiveBackground(
                    for: cell,
                    defaultBackground: defaultBackground,
                    defaultForeground: defaultForeground,
                    palette: palette
                )
                counts[resolved, default: 0] += weight
                rowWeight += weight
                totalWeight += weight
            }
            if rowWeight < columns {
                let trailing = columns - rowWeight
                counts[defaultBackground, default: 0] += trailing
                totalWeight += trailing
            }
        }

        guard totalWeight > 0, !counts.isEmpty else { return defaultBackground }

        var bestColor = defaultBackground
        var bestCount = 0
        for (color, count) in counts {
            if count > bestCount || (count == bestCount && color == defaultBackground) {
                bestColor = color
                bestCount = count
            }
        }

        // Require at least 50% viewport coverage; exact ties with default remain default.
        let defaultCount = counts[defaultBackground, default: 0]
        if bestColor != defaultBackground && bestCount == defaultCount {
            return defaultBackground
        }
        return bestCount * 2 >= totalWeight ? bestColor : defaultBackground
    }

    private static func effectiveBackground(
        for cell: CellSample,
        defaultBackground: TerminalRGB,
        defaultForeground: TerminalRGB,
        palette: [TerminalRGB]
    ) -> TerminalRGB {
        if cell.isInverse {
            return resolveColor(cell.foreground, fallback: defaultForeground, palette: palette)
        }
        return resolveColor(cell.background, fallback: defaultBackground, palette: palette)
    }

    private static func resolveColor(
        _ color: CellColor,
        fallback: TerminalRGB,
        palette: [TerminalRGB]
    ) -> TerminalRGB {
        switch color {
        case .defaultColor:
            fallback
        case .ansi256(let code):
            palette.indices.contains(Int(code)) ? palette[Int(code)] : fallback
        case .trueColor(let rgb):
            rgb
        }
    }
}
