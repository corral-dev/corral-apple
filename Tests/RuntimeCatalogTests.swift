import Foundation
@testable import Corral
import XCTest

@MainActor
final class RuntimeCatalogTests: XCTestCase {
    private let payload: [String: Any] = ["runtimes": [
        ["id": "claude", "name": "Claude", "available": true],
        ["id": "pi"], ["id": "cursor", "available": false],
        ["id": "kimi"], ["id": "unapproved"],
    ]]

    func testFailureEndsLoadingAndRetryRecovers() async {
        let catalog = RuntimeCatalog()
        let owner = NSObject()
        await catalog.load(for: owner) {
            throw RemoteCallError(code: "unavailable", message: "Catalog worker busy", hint: "")
        }
        XCTAssertFalse(catalog.isLoading)
        XCTAssertFalse(catalog.isLoaded)
        XCTAssertEqual(catalog.errorMessage, "Catalog worker busy")
        await catalog.load(for: owner, retry: true) {
            XCTAssertTrue(catalog.isLoading)
            XCTAssertNil(catalog.errorMessage)
            return payload
        }
        XCTAssertTrue(catalog.isLoaded)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertNil(catalog.errorMessage)
        XCTAssertEqual(catalog.runtimes.map(\.id), ["claude", "pi", "cursor"])
        XCTAssertFalse(catalog.runtimes[2].isUsable)
    }

    func testEmptySuccessIsNotFailureAndDoesNotRefetch() async {
        let catalog = RuntimeCatalog()
        let owner = NSObject()
        await catalog.load(for: owner) { ["runtimes": []] as [String: Any] }
        XCTAssertTrue(catalog.isLoaded)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertNil(catalog.errorMessage)
        await catalog.load(for: owner) {
            XCTFail("A successful empty catalog is already loaded")
            return payload
        }
        XCTAssertTrue(catalog.runtimes.isEmpty)
    }

    func testMalformedResponseEndsLoadingWithAnError() async {
        for payload: [String: Any] in [[:], ["runtimes": "wrong"], ["runtimes": [["name": "No ID"]]]] {
            let catalog = RuntimeCatalog()
            await catalog.load(for: NSObject()) { payload }
            XCTAssertFalse(catalog.isLoaded)
            XCTAssertFalse(catalog.isLoading)
            XCTAssertNotNil(catalog.errorMessage)
        }
    }

    func testConcurrentStartupAndRetryUseOneFlight() async {
        let catalog = RuntimeCatalog()
        let owner = NSObject()
        let started = expectation(description: "catalog request started")
        var release: CheckedContinuation<Void, Never>?
        let first = Task {
            await catalog.load(for: owner) {
                await withCheckedContinuation { release = $0; started.fulfill() }
                return payload
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await catalog.load(for: owner, retry: true) {
            XCTFail("Retry must not duplicate the outstanding request")
            return payload
        }
        release?.resume()
        await first.value
        XCTAssertTrue(catalog.isLoaded)
        XCTAssertFalse(catalog.isLoading)
    }

    func testReplacementRejectsLateSuccessAndFailure() async {
        for fails in [false, true] {
            let catalog = RuntimeCatalog()
            let oldOwner = NSObject()
            let newOwner = NSObject()
            let started = expectation(description: "old request started")
            var release: CheckedContinuation<Void, Never>?
            let old = Task {
                await catalog.load(for: oldOwner) {
                    await withCheckedContinuation { release = $0; started.fulfill() }
                    if fails { throw URLError(.timedOut) }
                    return payload
                }
            }
            await fulfillment(of: [started], timeout: 2)
            await catalog.load(for: newOwner) { ["runtimes": [["id": "codex"]]] }
            release?.resume()
            await old.value
            XCTAssertEqual(catalog.runtimes.map(\.id), ["codex"])
            XCTAssertTrue(catalog.isLoaded)
            XCTAssertFalse(catalog.isLoading)
            XCTAssertNil(catalog.errorMessage)
        }
    }

    func testCancelledPredecessorCannotClearReconnectedRequest() async {
        let catalog = RuntimeCatalog()
        let owner = NSObject()
        let started = expectation(description: "request started before disconnect")
        var release: CheckedContinuation<Void, Never>?
        let old = Task {
            await catalog.load(for: owner) {
                await withCheckedContinuation { release = $0; started.fulfill() }
                return payload
            }
        }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        catalog.reset()
        await catalog.load(for: owner) { ["runtimes": [["id": "opencode"]]] }
        release?.resume()
        await old.value
        XCTAssertEqual(catalog.runtimes.map(\.id), ["opencode"])
        XCTAssertTrue(catalog.isLoaded)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertNil(catalog.errorMessage)
    }
}
