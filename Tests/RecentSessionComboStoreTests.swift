import Foundation
@testable import Corral
import XCTest

@MainActor
final class RecentSessionComboStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-combos-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        RecentSessionComboStore.directoryOverride = scratch
    }

    override func tearDown() async throws {
        RecentSessionComboStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testRecordLoadsMostRecentFirst() {
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "pi", runtimeName: "Pi",
            projectPath: "/a", projectName: "a"
        )
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "claude", runtimeName: "Claude",
            projectPath: "/b", projectName: "b"
        )
        let combos = RecentSessionComboStore.load(hostID: "h1")
        XCTAssertEqual(combos.count, 2)
        XCTAssertEqual(combos[0].runtimeID, "claude")
        XCTAssertEqual(combos[1].runtimeID, "pi")
        XCTAssertEqual(combos[0].title, "Claude · b")
    }

    func testRerecordBumpsToFrontWithoutDuplicates() {
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "pi", runtimeName: "Pi",
            projectPath: "/a", projectName: "a"
        )
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "claude", runtimeName: "Claude",
            projectPath: "/b", projectName: "b"
        )
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "pi", runtimeName: "Pi",
            projectPath: "/a", projectName: "a"
        )
        let combos = RecentSessionComboStore.load(hostID: "h1")
        XCTAssertEqual(combos.count, 2)
        XCTAssertEqual(combos[0].runtimeID, "pi")
        XCTAssertEqual(combos[1].runtimeID, "claude")
    }

    func testCombosAreCappedAtMax() {
        for i in 0 ..< (RecentSessionComboStore.maxCombos + 3) {
            RecentSessionComboStore.record(
                hostID: "h1", runtimeID: "r\(i)", runtimeName: nil,
                projectPath: "/p\(i)", projectName: nil
            )
        }
        let combos = RecentSessionComboStore.load(hostID: "h1")
        XCTAssertEqual(combos.count, RecentSessionComboStore.maxCombos)
        XCTAssertEqual(combos[0].runtimeID, "r\(RecentSessionComboStore.maxCombos + 2)")
    }

    func testHostsDoNotShareCombos() {
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "pi", runtimeName: "Pi",
            projectPath: "/a", projectName: "a"
        )
        RecentSessionComboStore.record(
            hostID: "h2", runtimeID: "claude", runtimeName: "Claude",
            projectPath: "/b", projectName: "b"
        )
        XCTAssertEqual(RecentSessionComboStore.load(hostID: "h1").count, 1)
        XCTAssertEqual(RecentSessionComboStore.load(hostID: "h2").count, 1)

        RecentSessionComboStore.removeAll(hostID: "h1")
        XCTAssertTrue(RecentSessionComboStore.load(hostID: "h1").isEmpty)
        XCTAssertEqual(RecentSessionComboStore.load(hostID: "h2").count, 1)
    }

    func testEmptyHostIDLoadsNothing() {
        RecentSessionComboStore.record(
            hostID: "", runtimeID: "pi", runtimeName: "Pi",
            projectPath: "/a", projectName: "a"
        )
        XCTAssertTrue(RecentSessionComboStore.load(hostID: "").isEmpty)
    }

    func testTitleFallsBackToIDs() {
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "mybot", runtimeName: nil,
            projectPath: "/x/yproj", projectName: nil
        )
        let combos = RecentSessionComboStore.load(hostID: "h1")
        XCTAssertEqual(combos.count, 1)
        XCTAssertEqual(combos[0].title, "mybot · yproj")
    }

    func testRemoveDeletesOneComboOnly() {
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "pi", runtimeName: "Pi",
            projectPath: "/a", projectName: "a"
        )
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "claude", runtimeName: "Claude",
            projectPath: "/b", projectName: "b"
        )
        var combos = RecentSessionComboStore.load(hostID: "h1")
        XCTAssertEqual(combos.count, 2)
        RecentSessionComboStore.remove(hostID: "h1", comboID: combos[0].id)
        combos = RecentSessionComboStore.load(hostID: "h1")
        XCTAssertEqual(combos.count, 1)
        XCTAssertEqual(combos[0].runtimeID, "pi")
    }

    func testRemoveUnknownIDIsNoop() {
        RecentSessionComboStore.record(
            hostID: "h1", runtimeID: "pi", runtimeName: "Pi",
            projectPath: "/a", projectName: "a"
        )
        RecentSessionComboStore.remove(hostID: "h1", comboID: "nope\u{1f}/x")
        XCTAssertEqual(RecentSessionComboStore.load(hostID: "h1").count, 1)
        RecentSessionComboStore.remove(hostID: "", comboID: "x")
        RecentSessionComboStore.remove(hostID: "h1", comboID: "")
        XCTAssertEqual(RecentSessionComboStore.load(hostID: "h1").count, 1)
    }
}
