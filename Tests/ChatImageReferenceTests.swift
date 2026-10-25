import XCTest
@testable import Corral

final class ChatImageReferenceTests: XCTestCase {
    func testMarkdownImageIsExplicitWithAlt() {
        let refs = ChatImageReference.references(in: "Here: ![Login screen](docs/shots/login.png) done")
        XCTAssertEqual(refs.map(\.ref), ["docs/shots/login.png"])
        XCTAssertEqual(refs.first?.kind, .explicit)
        XCTAssertEqual(refs.first?.displayName, "Login screen")
    }

    func testAngleBracketMarkdownPathKeepsSpaces() {
        let refs = ChatImageReference.references(in: "![](<shots/my shot.jpg>)")
        XCTAssertEqual(refs.map(\.ref), ["shots/my shot.jpg"])
    }

    func testHtmlImage() {
        let refs = ChatImageReference.references(in: #"<img width="300" src="assets/icon.webp">"#)
        XCTAssertEqual(refs.map(\.ref), ["assets/icon.webp"])
        XCTAssertEqual(refs.first?.kind, .explicit)
    }

    func testBareMentionsInReadingOrder() {
        let text = "Saved to /tmp/out/result.PNG, compare with ~/Desktop/before.jpeg and ./after.gif."
        let refs = ChatImageReference.references(in: text)
        XCTAssertEqual(refs.map(\.ref), ["/tmp/out/result.PNG", "~/Desktop/before.jpeg", "./after.gif"])
        XCTAssertTrue(refs.allSatisfy { $0.kind == .mention })
    }

    func testUrlsAndFileLinks() {
        let text = "See https://example.com/a/b/chart.png?raw=1 (or file:///Users/me/c.heic)."
        let refs = ChatImageReference.references(in: text)
        XCTAssertEqual(refs.map(\.ref), ["https://example.com/a/b/chart.png?raw=1", "file:///Users/me/c.heic"])
    }

    func testNonImageUrlsAndPathsAreIgnored() {
        XCTAssertTrue(ChatImageReference.references(in: "Open https://example.com/page and src/main.swift").isEmpty)
        XCTAssertTrue(ChatImageReference.references(in: "no images here").isEmpty)
    }

    func testMarkdownTargetIsNotDuplicatedAsMention() {
        let refs = ChatImageReference.references(in: "![a](x/y.png) and again x/y.png")
        XCTAssertEqual(refs.map(\.ref), ["x/y.png"])
        XCTAssertEqual(refs.first?.kind, .explicit)
    }

    func testBareMentionsInsideFencedCodeAreIgnored() {
        let text = "Code:\n```swift\nImage(\"logo.png\")\n```\nResult: out/final.png"
        XCTAssertEqual(ChatImageReference.references(in: text).map(\.ref), ["out/final.png"])
    }

    func testUnicodeFencesPreserveOriginalImageTargets() {
        for unicode in ["中文", "😀", "e\u{301}", "👨‍👩‍👧‍👦"] {
            for newline in ["\n", "\r\n"] {
                let text = "Before: before.png\(newline)```swift\(newline)"
                    + "\(unicode) hidden.png\(newline)```\(newline)"
                    + "\(unicode) After: /tmp/result.png and ![shot](shots/after.jpg)"
                let refs = ChatImageReference.references(in: text)
                XCTAssertEqual(refs.map(\.ref), ["before.png", "/tmp/result.png", "shots/after.jpg"])
                XCTAssertEqual(refs.map(\.kind), [.mention, .mention, .explicit])
            }
        }
    }

    func testUnicodeUnterminatedAndMultipleFences() {
        let text = "```\n👨‍👩‍👧‍👦 hidden.png\n```\nfirst.jpg\n"
            + "```\n中文 hidden.gif\n```\nsecond.webp\n```\n😀 hidden.heic"
        XCTAssertEqual(ChatImageReference.references(in: text).map(\.ref), ["first.jpg", "second.webp"])
    }

    func testExplicitImageInsideUnicodeFenceKeepsExistingBehavior() {
        let text = "```\n中文 ![Preview](images/explicit.png) hidden.jpg\n```\nafter.gif"
        let refs = ChatImageReference.references(in: text)
        XCTAssertEqual(refs.map(\.ref), ["images/explicit.png", "after.gif"])
        XCTAssertEqual(refs.first?.kind, .explicit)
    }

    func testCapPerMessage() {
        let text = (1...10).map { "img\($0).png" }.joined(separator: " ")
        XCTAssertEqual(ChatImageReference.references(in: text).count, ChatImageReference.maxPerMessage)
    }

    func testInlineTierFollowsNetwork() {
        XCTAssertEqual(
            ChatImageTier.inline(isLocalRoute: true, isConstrained: false, isExpensive: false, recentThroughput: nil),
            .high
        )
        XCTAssertEqual(
            ChatImageTier.inline(isLocalRoute: false, isConstrained: false, isExpensive: false, recentThroughput: nil),
            .medium
        )
        XCTAssertEqual(
            ChatImageTier.inline(isLocalRoute: true, isConstrained: false, isExpensive: true, recentThroughput: nil),
            .medium
        )
        XCTAssertEqual(
            ChatImageTier.inline(isLocalRoute: true, isConstrained: true, isExpensive: false, recentThroughput: nil),
            .low
        )
        XCTAssertEqual(
            ChatImageTier.inline(isLocalRoute: true, isConstrained: false, isExpensive: false, recentThroughput: 50_000),
            .low
        )
        XCTAssertLessThan(ChatImageTier.low.maxPixels, ChatImageTier.medium.maxPixels)
        XCTAssertLessThan(ChatImageTier.high.maxPixels, ChatImageTier.full.maxPixels)
    }
}
