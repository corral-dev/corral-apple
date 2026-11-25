import XCTest

nonisolated final class SessionSearchEmptyStateUITests: XCTestCase {
    @MainActor
    func testBottomSearchEmptyStateClearsSearchBarAndKeyboard() throws {
        let app = XCUIApplication()
        let keyB64 = Data(repeating: 1, count: 32).base64EncodedString()
        let encodedKey = keyB64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyB64
        app.launchEnvironment = [
            "CORRAL_INSPECTION_PAIRING_URL": "corral://pair?v=2&n=SimHost&k=\(encodedKey)&c=test"
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-CorralInspectSessions", "-CorralInspectBottomBarSearch"]
        app.launch()
        defer { app.terminate() }

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 15), "Search field should appear")
        if !searchField.hasFocus { searchField.tap() }
        searchField.typeText("zzzzz")

        let kb = app.keyboards.firstMatch
        XCTAssertTrue(kb.waitForExistence(timeout: 5), "Software keyboard should appear")
        XCTAssertLessThan(kb.frame.minY, app.frame.maxY, "Software keyboard must be on-screen")

        let noResults = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'No Results'")).firstMatch
        let retry = app.buttons["Retry"].firstMatch
        let settled = noResults.waitForExistence(timeout: 8) || retry.waitForExistence(timeout: 2)
        XCTAssertTrue(settled, "Expected either No Results or Retry state")

        let contentElement = noResults.exists ? noResults : retry
        XCTAssertLessThan(contentElement.frame.maxY, searchField.frame.minY, "Empty state must sit cleanly above the bottom search bar")
        XCTAssertLessThan(contentElement.frame.maxY, kb.frame.minY, "Empty state must sit cleanly above the keyboard")

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "corral-search-empty-fixed"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
