import SwiftUI
import UIKit
import XCTest
@testable import Corral

@MainActor
final class RuntimeLogoTests: XCTestCase {
    func testKnownRuntimesHaveOfficialLogoAssets() {
        let expected: [(String, String)] = [
            ("claude", "RuntimeClaude"),
            ("codex", "RuntimeCodex"),
            ("cursor", "RuntimeCursor"),
            ("kimi", "RuntimeKimi"),
            ("opencode", "RuntimeOpenCode"),
            ("pi", "RuntimePi"),
        ]
        for (id, name) in expected {
            XCTAssertEqual(Palette.runtimeLogoName(id), name)
            XCTAssertNotNil(
                UIImage(named: name),
                "\(id) 的官方标识应打进应用资源包"
            )
        }
    }

    func testUnknownRuntimeFallsBackWithoutInventedLogo() {
        XCTAssertNil(Palette.runtimeLogoName("unknown-agent"))
        XCTAssertEqual(Palette.runtimeSymbol("unknown-agent"), "terminal.fill")
    }

    func testRuntimeDisplayNamesAreBrandLabels() {
        XCTAssertEqual(Palette.runtimeDisplayName("claude"), "Claude")
        XCTAssertEqual(Palette.runtimeDisplayName("CURSOR"), "Cursor")
        XCTAssertEqual(Palette.runtimeDisplayName("opencode"), "OpenCode")
        XCTAssertEqual(Palette.runtimeDisplayName(""), "")
        XCTAssertEqual(Palette.runtimeDisplayName("custom-bot"), "custom-bot")
    }

    func testPiUsesSameYellowAsDesktop() {
        XCTAssertEqual(Palette.runtime("pi"), Palette.pi)
    }
}
