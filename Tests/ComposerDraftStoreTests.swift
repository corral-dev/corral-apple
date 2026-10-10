import Foundation
@testable import Corral
import XCTest

@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-draft-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ComposerDraftStore.directoryOverride = scratch
    }

    override func tearDown() async throws {
        ComposerDraftStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    func testSaveLoadAndClearEmpty() {
        ComposerDraftStore.save(hostID: "h1", sessionKey: "claude:a", text: "还没发出去")
        XCTAssertEqual(ComposerDraftStore.load(hostID: "h1", sessionKey: "claude:a"), "还没发出去")

        ComposerDraftStore.save(hostID: "h1", sessionKey: "claude:a", text: "   ")
        XCTAssertNil(ComposerDraftStore.load(hostID: "h1", sessionKey: "claude:a"))
    }

    func testHostsDoNotShareDrafts() {
        ComposerDraftStore.save(hostID: "h1", sessionKey: "claude:a", text: "甲机")
        ComposerDraftStore.save(hostID: "h2", sessionKey: "claude:a", text: "乙机")
        XCTAssertEqual(ComposerDraftStore.load(hostID: "h1", sessionKey: "claude:a"), "甲机")
        XCTAssertEqual(ComposerDraftStore.load(hostID: "h2", sessionKey: "claude:a"), "乙机")

        ComposerDraftStore.removeAll(hostID: "h1")
        XCTAssertNil(ComposerDraftStore.load(hostID: "h1", sessionKey: "claude:a"))
        XCTAssertEqual(ComposerDraftStore.load(hostID: "h2", sessionKey: "claude:a"), "乙机")
    }
}
