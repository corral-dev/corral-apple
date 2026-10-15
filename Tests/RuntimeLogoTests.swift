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

    /// 机主规则 2026-10-15：用户可见的助手标识一律黑白化，不搞特殊。
    /// 每个活跃助手的浅色底图应为近黑单色、深色底图应为近白单色，
    /// 且不得含有橙色像素（Claude 的陶土橙已下线）。Kimi dormant 不可见，不在此列。
    func testActiveRuntimeLogosAreMonochrome() {
        let active: [(id: String, name: String)] = [
            ("claude", "RuntimeClaude"),
            ("codex", "RuntimeCodex"),
            ("cursor", "RuntimeCursor"),
            ("opencode", "RuntimeOpenCode"),
            ("pi", "RuntimePi"),
        ]
        for (id, name) in active {
            for style in [UIUserInterfaceStyle.light, .dark] {
                guard
                    let image = UIImage(
                        named: name, in: nil,
                        compatibleWith: UITraitCollection(userInterfaceStyle: style)
                    ),
                    let cg = image.cgImage
                else {
                    XCTFail("\(id) 缺少 \(style == .light ? "浅色" : "深色")标识图")
                    continue
                }
                let stats = Self.pixelStats(cg)
                XCTAssertLessThanOrEqual(stats.spread, 16, "\(id) 标识应为黑白单色")
                XCTAssertEqual(stats.orange, 0, "\(id) 标识不得含有橙色像素")
            }
        }
    }

    /// 采样不透明像素：最大通道差（单色程度）与橙色像素数。
    private static func pixelStats(_ cg: CGImage) -> (spread: Int, orange: Int) {
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var spread = 0, orange = 0
        var i = 0
        while i < data.count {
            if data[i + 3] > 128 {
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                spread = max(spread, abs(r - g), abs(g - b), abs(r - b))
                if r > 150 && (80...170).contains(g) && b < 130 { orange += 1 }
            }
            i += 16
        }
        return (spread, orange)
    }
}
