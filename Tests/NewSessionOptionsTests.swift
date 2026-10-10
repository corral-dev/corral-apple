import XCTest
@testable import Corral

@MainActor
final class NewSessionOptionsTests: XCTestCase {
    private let runtimes: [String: Any] = ["runtimes": [
        ["id": "missing", "available": false], ["id": "claude", "available": true],
        ["id": "pi"],
    ]]
    private let projects: [String: Any] = ["projects": [
        ["path": "", "name": "No project"],
        ["cwd": "/workspace/example", "label": "Example"],
        ["path": "/workspace/other", "name": "Other"],
    ]]

    func testLoadingFailureCannotCreateInDefaultDirectoryAndRetryRecovers() async {
        let options = NewSessionOptions()
        await options.load { method in
            if method == WireProtocol.mRuntimesList { return runtimes }
            throw RemoteCallError(code: "internal_error", message: "Catalog failed", hint: "")
        }
        XCTAssertFalse(options.canCreate)
        XCTAssertEqual(options.errorMessage, "Catalog failed")
        XCTAssertFalse(options.isLoading)
        await options.load { method in
            XCTAssertTrue(options.isLoading)
            XCTAssertFalse(options.canCreate)
            return method == WireProtocol.mRuntimesList ? runtimes : projects
        }
        XCTAssertTrue(options.canCreate)
        XCTAssertNil(options.errorMessage)
        XCTAssertEqual(options.selectedRuntime, "claude")
        XCTAssertEqual(options.selectedProject, "/workspace/example")
    }

    func testExplicitNoProjectIsValidButMissingPathsAreNot() async {
        let options = NewSessionOptions()
        await options.load { method in
            method == WireProtocol.mRuntimesList ? runtimes : projects
        }
        options.selectedProject = ""
        XCTAssertTrue(options.canCreate)
        await options.load { method in
            method == WireProtocol.mRuntimesList ? runtimes : ["projects": [["name": "Malformed"]]]
        }
        XCTAssertFalse(options.canCreate)
        XCTAssertNotNil(options.errorMessage)
    }

    func testRetryPreservesValidSelectionsAndRejectsUnavailableAssistant() async {
        let options = NewSessionOptions()
        await options.load { method in method == WireProtocol.mRuntimesList ? runtimes : projects }
        options.selectedRuntime = "pi"
        options.selectedProject = "/workspace/other"
        await options.load { method in method == WireProtocol.mRuntimesList ? runtimes : projects }
        XCTAssertEqual(options.selectedRuntime, "pi")
        XCTAssertEqual(options.selectedProject, "/workspace/other")
        XCTAssertTrue(options.canCreate)
        options.selectedRuntime = "missing"
        XCTAssertFalse(options.canCreate)
    }

    func testEmptyOrMalformedCatalogCannotEnableCreate() async {
        for catalog: [String: Any] in [["projects": []], [:]] {
            let options = NewSessionOptions()
            await options.load { method in method == WireProtocol.mRuntimesList ? runtimes : catalog }
            XCTAssertFalse(options.isReady)
            XCTAssertFalse(options.canCreate)
            XCTAssertNotNil(options.errorMessage)
        }
    }

    func testDormantRuntimeExcludedFromCatalog() async {
        let catalog: [String: Any] = ["runtimes": [
            ["id": "kimi", "name": "Kimi", "available": true],
            ["id": "KIMI", "name": "Kimi", "available": true],
            ["id": "unapproved-agent", "name": "Unapproved", "available": true],
            ["id": "claude", "name": "Claude", "available": true],
        ]]
        let options = NewSessionOptions()
        await options.load { method in method == WireProtocol.mRuntimesList ? catalog : projects }
        XCTAssertTrue(options.isReady)
        // Strict allowlist: dormant and unknown ids never enter the catalog,
        // the first listed entry is active, and nothing unapproved is selected.
        XCTAssertEqual(options.runtimes.map(\.id), ["claude"])
        XCTAssertEqual(options.selectedRuntime, "claude")
        options.selectedRuntime = "unapproved-agent"
        XCTAssertFalse(options.canCreate)
        options.selectedRuntime = "kimi"
        XCTAssertFalse(options.canCreate)
    }

    func testUnapprovedAgentFirstNeverAutoSelects() async {
        // Exact acceptance shape: available unapproved id first, claude second.
        let catalog: [String: Any] = ["runtimes": [
            ["id": "unapproved-agent", "available": true],
            ["id": "claude", "available": true],
        ]]
        let options = NewSessionOptions()
        await options.load { method in
            if method == WireProtocol.mRuntimesList { return catalog }
            return ["projects": [["path": "/tmp/acceptance"]]]
        }
        XCTAssertEqual(options.runtimes.map(\.id), ["claude"])
        XCTAssertFalse(options.selectedRuntime == "unapproved-agent" && options.canCreate)
        XCTAssertEqual(options.selectedRuntime, "claude")
        XCTAssertTrue(options.canCreate)
    }

    func testDormantIdentityMatrix() {
        // Dormant by runtime, regardless of key.
        XCTAssertTrue(ActiveRuntimeVisibility.isDormant(runtime: "kimi", key: "other:key"))
        XCTAssertTrue(ActiveRuntimeVisibility.isDormant(runtime: "KIMI", key: nil))
        // Dormant by canonical key prefix even when runtime metadata is absent.
        XCTAssertTrue(ActiveRuntimeVisibility.isDormant(runtime: nil, key: "kimi:missing-runtime"))
        XCTAssertTrue(ActiveRuntimeVisibility.isDormant(runtime: "", key: "KIMI:old"))
        XCTAssertTrue(ActiveRuntimeVisibility.isDormant(runtime: "claude", key: "kimi:renamed"))
        // Active, unknown, and missing identities stay visible.
        XCTAssertFalse(ActiveRuntimeVisibility.isDormant(runtime: "claude", key: "claude:a"))
        XCTAssertFalse(ActiveRuntimeVisibility.isDormant(runtime: "next-agent", key: "next:f"))
        XCTAssertFalse(ActiveRuntimeVisibility.isDormant(runtime: nil, key: "noruntime:g"))
        XCTAssertFalse(ActiveRuntimeVisibility.isDormant(runtime: nil, key: nil))
        XCTAssertFalse(ActiveRuntimeVisibility.isDormant(runtime: "", key: ""))
    }

    func testProjectSearchMatchesNameOrPathIgnoringCase() {
        let entries = [
            ProjectEntry(path: "", name: "No project"),
            ProjectEntry(path: "/work/NeatWebApp", name: nil),
            ProjectEntry(path: "/work/LingoWeave/backend", name: "LingoWeave/backend"),
        ]
        XCTAssertEqual(ProjectEntry.matching(entries, query: "  ").count, 3)
        XCTAssertEqual(ProjectEntry.matching(entries, query: "neat").map(\.path), ["/work/NeatWebApp"])
        XCTAssertEqual(ProjectEntry.matching(entries, query: "WORK/lingo").map(\.path), ["/work/LingoWeave/backend"])
        XCTAssertEqual(ProjectEntry.matching(entries, query: "no proj").map(\.path), [""])
        XCTAssertTrue(ProjectEntry.matching(entries, query: "zzz").isEmpty)
        XCTAssertEqual(entries[1].displayName, "NeatWebApp")
    }
}
