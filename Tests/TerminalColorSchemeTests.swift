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
}
