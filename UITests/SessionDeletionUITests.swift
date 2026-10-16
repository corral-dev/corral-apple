import XCTest

nonisolated final class SessionDeletionUITests: XCTestCase {
    @MainActor private func runScenario(dark: Bool, scrolled: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CorralInspectDeletion", dark ? "-CorralInspectDark" : "-CorralInspectLight", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        if scrolled {
            app.swipeUp()
            app.swipeUp()
        }
        let number = scrolled ? 17 : 3
        let row = app.cells.containing(.staticText, identifier: "Session \(number)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let title = app.staticTexts["Delete this session?"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        capture(app, name: "opened")
        Thread.sleep(forTimeInterval: 4)
        capture(app, name: "after-four-seconds")
        XCTAssertTrue(title.exists, "Confirmation retracted during eight live row updates")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.15)).tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 2))
        XCTAssertTrue(row.exists, "Dismissal must not delete the source session")
        let next = app.cells.containing(.staticText, identifier: "Session \(number + 1)").firstMatch
        next.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(title.exists)
        capture(app, name: "different-row-reopened")
        // Confirm against the fictional list only. There is no history/host API.
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 2))
        XCTAssertTrue(next.waitForNonExistence(timeout: 2))
        XCTAssertTrue(row.exists, "Confirmation must delete only its own fictional row")
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testLightRowKeepsConfirmationOpenAndDeletesOnlyConfirmedFixture() throws {
        try runScenario(dark: false, scrolled: false)
    }
    @MainActor func testDarkScrolledRowKeepsConfirmationOpenAndReopens() throws {
        try runScenario(dark: true, scrolled: true)
    }
}
