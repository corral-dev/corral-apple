@testable import Corral
import XCTest

final class TerminalColorSchemeTests: XCTestCase {
    private func relativeLuminance(_ rgb: TerminalColorScheme.RGB) -> Double {
        func linearize(_ channel: UInt8) -> Double {
            let s = Double(channel) / 255.0
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgb.red) + 0.7152 * linearize(rgb.green) + 0.0722 * linearize(rgb.blue)
    }

    private func contrastRatio(_ a: TerminalColorScheme.RGB, _ b: TerminalColorScheme.RGB) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        let (hi, lo) = l1 >= l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    func testPalettesHaveSixteenAnsiColoursAndExpectedBackgroundHex() {
        XCTAssertEqual(TerminalColorScheme.dark.ansi.count, 16)
        XCTAssertEqual(TerminalColorScheme.light.ansi.count, 16)
        XCTAssertEqual(TerminalColorScheme.dark.theme.background, "#14171f")
        XCTAssertEqual(TerminalColorScheme.light.theme.background, "#ffffff")
    }

    func testLightGrayscaleRampSeparatesMonotonically() {
        let light = TerminalColorScheme.light
        let stops = [
            light.foreground,
            light.ansi[0],
            light.ansi[8],
            light.ansi[7],
            light.ansi[15],
            light.background,
        ].map(relativeLuminance)
        for index in 1..<stops.count {
            XCTAssertGreaterThan(stops[index], stops[index - 1], "Light grayscale step \(index) must increase in luminance")
        }
    }

    func testDarkGrayscaleRampSeparatesMonotonically() {
        let dark = TerminalColorScheme.dark
        let stops = [
            dark.background,
            dark.ansi[0],
            dark.ansi[8],
            dark.ansi[7],
            dark.foreground,
            dark.ansi[15],
        ].map(relativeLuminance)
        for index in 1..<stops.count {
            XCTAssertGreaterThan(stops[index], stops[index - 1], "Dark grayscale step \(index) must increase in luminance")
        }
    }

    func testLightBrightChromaticColoursOutshineNormalVariants() {
        let light = TerminalColorScheme.light
        for offset in 1...6 {
            XCTAssertGreaterThan(
                relativeLuminance(light.ansi[offset + 8]),
                relativeLuminance(light.ansi[offset]),
                "ANSI bright slot \(offset + 8) should be brighter than \(offset) in light mode"
            )
        }
    }

    func testDarkChromaticColoursMeetReadableContrastAgainstBackground() {
        let dark = TerminalColorScheme.dark
        for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(dark.ansi[index], dark.background),
                4.2,
                "Dark ANSI \(index) contrast dropped below 4.2:1"
            )
        }
    }

    func testApplyingTerminalThemeAttachesLaunchAndControlHelloOnly() {
        let theme = TerminalColorScheme.light.theme

        let controlHello = WireProtocol.applyingTerminalTheme(theme, to: ["name": "Mac"], method: WireProtocol.mHello)
        XCTAssertEqual(controlHello["background"] as? String, "#ffffff")
        XCTAssertEqual(controlHello["foreground"] as? String, "#181c22")

        let dataHello = WireProtocol.applyingTerminalTheme(
            theme, to: ["plane": WireProtocol.planeData, "bind": "b", "name": "Mac"], method: WireProtocol.mHello
        )
        XCTAssertNil(dataHello["background"])

        for method in [
            WireProtocol.mSessionNew,
            WireProtocol.mSessionResume,
            WireProtocol.mSessionRestart,
            WireProtocol.mSessionCopy,
            WireProtocol.mSessionHandoff,
            WireProtocol.mShellOpen,
        ] {
            let enriched = WireProtocol.applyingTerminalTheme(theme, to: ["key": "pi:1"], method: method)
            XCTAssertEqual(enriched["background"] as? String, "#ffffff", method)
            XCTAssertEqual(enriched["foreground"] as? String, "#181c22", method)
        }

        let explicit = WireProtocol.applyingTerminalTheme(
            theme, to: ["key": "pi:1", "background": "#14171f"], method: WireProtocol.mSessionNew
        )
        XCTAssertEqual(explicit["background"] as? String, "#14171f")

        let unrelated = WireProtocol.applyingTerminalTheme(theme, to: ["key": "pi:1"], method: WireProtocol.mInputText)
        XCTAssertNil(unrelated["background"])
    }

    func testTerminalRGB16BitConversionAndChromePolarity() {
        XCTAssertEqual(TerminalRGB(red16: 0, green16: 0, blue16: 0), TerminalRGB(red: 0, green: 0, blue: 0))
        XCTAssertEqual(TerminalRGB(red16: 5140, green16: 5911, blue16: 7967), TerminalRGB(red: 20, green: 23, blue: 31))
        XCTAssertEqual(TerminalRGB(red16: 5139, green16: 5911, blue16: 7967), TerminalRGB(red: 20, green: 23, blue: 31))
        XCTAssertEqual(TerminalRGB(red16: 65535, green16: 65535, blue16: 65535), TerminalRGB(red: 255, green: 255, blue: 255))

        XCTAssertTrue(TerminalColorScheme.dark.backgroundRGB.prefersDarkChrome)
        XCTAssertTrue(TerminalRGB(red: 40, green: 42, blue: 54).prefersDarkChrome)
        XCTAssertFalse(TerminalColorScheme.light.backgroundRGB.prefersDarkChrome)
        XCTAssertFalse(TerminalRGB(red: 253, green: 246, blue: 227).prefersDarkChrome)
        XCTAssertTrue(TerminalRGB(red: 110, green: 110, blue: 110).prefersDarkChrome)
        XCTAssertFalse(TerminalRGB(red: 120, green: 120, blue: 120).prefersDarkChrome)
    }

    func testSurfaceBackgroundResolverHandlesDefaultsSGRInverseWideAndTies() {
        let defaultBg = TerminalColorScheme.dark.backgroundRGB
        let defaultFg = TerminalColorScheme.dark.foregroundRGB
        let palette = (0..<256).map { index in
            TerminalRGB(red: UInt8(index), green: UInt8(index / 2), blue: UInt8(255 - index))
        }
        let defaultCell = TerminalSurfaceBackgroundResolver.CellSample(
            width: 1,
            foreground: .defaultColor,
            background: .defaultColor,
            isInverse: false
        )

        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: [],
                columns: 80,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            defaultBg
        )

        // Default background + 15% diff highlight strip stays on defaultBackground.
        let diffColor = TerminalRGB(red: 34, green: 80, blue: 48)
        let diffRow = Array(
            repeating: TerminalSurfaceBackgroundResolver.CellSample(
                width: 1, foreground: .defaultColor, background: .trueColor(diffColor), isInverse: false
            ),
            count: 20
        )
        let defaultRow = Array(repeating: defaultCell, count: 20)
        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: Array(repeating: diffRow, count: 3) + Array(repeating: defaultRow, count: 17),
                columns: 20,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            defaultBg
        )

        // Full-canvas SGR truecolor theme (80%) beats bottom status bar and default fallback.
        let catppuccin = TerminalRGB(red: 30, green: 30, blue: 46)
        let status = TerminalRGB(red: 69, green: 71, blue: 90)
        let themedRow = Array(
            repeating: TerminalSurfaceBackgroundResolver.CellSample(
                width: 1, foreground: .defaultColor, background: .trueColor(catppuccin), isInverse: false
            ),
            count: 20
        )
        let statusRow = Array(
            repeating: TerminalSurfaceBackgroundResolver.CellSample(
                width: 1, foreground: .defaultColor, background: .trueColor(status), isInverse: false
            ),
            count: 20
        )
        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: Array(repeating: themedRow, count: 8) + Array(repeating: statusRow, count: 2),
                columns: 20,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            catppuccin
        )

        // SGR ansi256 background resolves through the palette.
        let ansiRow = Array(
            repeating: TerminalSurfaceBackgroundResolver.CellSample(
                width: 1, foreground: .defaultColor, background: .ansi256(234), isInverse: false
            ),
            count: 10
        )
        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: Array(repeating: ansiRow, count: 6) + Array(repeating: Array(defaultRow.prefix(10)), count: 4),
                columns: 10,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            palette[234]
        )

        // Inverse-video cells use foreground color as visible background.
        let inverseRow = Array(
            repeating: TerminalSurfaceBackgroundResolver.CellSample(
                width: 1, foreground: .defaultColor, background: .defaultColor, isInverse: true
            ),
            count: 10
        )
        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: Array(repeating: inverseRow, count: 6) + Array(repeating: Array(defaultRow.prefix(10)), count: 4),
                columns: 10,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            defaultFg
        )

        // Wide glyphs (width 2 + width 0 continuation) weight properly as 2 columns.
        let wideLeading = TerminalSurfaceBackgroundResolver.CellSample(
            width: 2, foreground: .defaultColor, background: .trueColor(catppuccin), isInverse: false
        )
        let wideContinuation = TerminalSurfaceBackgroundResolver.CellSample(
            width: 0, foreground: .defaultColor, background: .trueColor(status), isInverse: false
        )
        let wideRow = [wideLeading, wideContinuation, wideLeading, wideContinuation, wideLeading, wideContinuation]
        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: [wideRow],
                columns: 6,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            catppuccin
        )

        // Split mosaic with no >= 50% winner falls back to defaultBackground.
        let colorA = TerminalRGB(red: 40, green: 40, blue: 60)
        let colorB = TerminalRGB(red: 60, green: 40, blue: 40)
        let colorC = TerminalRGB(red: 40, green: 60, blue: 40)
        let rowA = Array(repeating: TerminalSurfaceBackgroundResolver.CellSample(
            width: 1, foreground: .defaultColor, background: .trueColor(colorA), isInverse: false
        ), count: 10)
        let rowB = Array(repeating: TerminalSurfaceBackgroundResolver.CellSample(
            width: 1, foreground: .defaultColor, background: .trueColor(colorB), isInverse: false
        ), count: 10)
        let rowC = Array(repeating: TerminalSurfaceBackgroundResolver.CellSample(
            width: 1, foreground: .defaultColor, background: .trueColor(colorC), isInverse: false
        ), count: 10)
        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: [rowA, rowA, rowA, rowB, rowB, rowB, rowC, rowC, rowC, rowC],
                columns: 10,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            defaultBg
        )

        // Exact 50%/50% tie involving defaultBackground favors defaultBackground.
        XCTAssertEqual(
            TerminalSurfaceBackgroundResolver.resolve(
                rows: Array(repeating: Array(themedRow.prefix(10)), count: 5)
                    + Array(repeating: Array(defaultRow.prefix(10)), count: 5),
                columns: 10,
                defaultBackground: defaultBg,
                defaultForeground: defaultFg,
                palette: palette
            ),
            defaultBg
        )
    }
}
