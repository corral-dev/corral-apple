@testable import Corral
import Foundation
import XCTest

final class CorralIDTests: XCTestCase {
    func testGoldenVectorsMatchPythonStatelessHash() {
        let cases: [(String, String, String)] = [
            ("claude", "631fad3d-fc68-43cf-9342-7b0f33af7a65", "ccm7k4bh"),
            ("codex", "01a1f6f7-9984-7d01-b4be-448733344368", "cxqfmcyc"),
            ("opencode", "ses_e1b32bb81ffeQnwYXQn4f81uS0", "oc59w4me"),
            ("cursor", "6a994179-fc25-4eb6-aa19-bf2ff2495e29", "cuckt8av"),
            ("pi", "7463b1e8", "pix5t1pk"),
            ("antigravity", "631fad3d-fc68-43cf-9342-7b0f33af7a65", "agcyqkzn"),
        ]
        for (runtime, sessionID, expected) in cases {
            XCTAssertEqual(CorralID.derive(runtime: runtime, sessionID: sessionID), expected)
        }
    }

    func testEmptyAndShellReturnEmpty() {
        XCTAssertEqual(CorralID.derive(runtime: "shell", sessionID: "sh-1"), "")
        XCTAssertEqual(CorralID.derive(runtime: "claude", sessionID: ""), "")
        XCTAssertEqual(CorralID.derive(runtime: nil, sessionID: "abc"), "")
    }

    func testServerSuppliedEmptySuppressesFallbackWhileNilFallsBack() throws {
        let provisional = try RemoteJSONDecoder.decode(
            SessionSummary.self,
            from: [
                "key": "claude:tmp-1",
                "runtime": "claude",
                "id": "tmp-1",
                "corral_id": "",
            ] as [String: Any]
        )
        XCTAssertEqual(provisional.corralID, "")
        XCTAssertEqual(provisional.resolvedCorralID, "")

        let legacy = try RemoteJSONDecoder.decode(
            SessionSummary.self,
            from: [
                "key": "claude:631fad3d-fc68-43cf-9342-7b0f33af7a65",
                "runtime": "claude",
                "id": "631fad3d-fc68-43cf-9342-7b0f33af7a65",
            ] as [String: Any]
        )
        XCTAssertNil(legacy.corralID)
        XCTAssertEqual(legacy.resolvedCorralID, "ccm7k4bh")
    }

    func testSearchMatchesCorralIDAndCrockfordAliases() {
        let session = SessionSummary(
            key: "pi:7463b1e8",
            runtime: "pi",
            sessionID: "7463b1e8",
            title: "Unrelated title"
        )
        XCTAssertEqual(session.resolvedCorralID, "pix5t1pk")
        XCTAssertTrue(session.matches(query: "PIX5T1PK"))
        XCTAssertTrue(session.matches(query: "pi-x5tlpk"))
        XCTAssertFalse(session.matches(query: "ccm7k4bh"))
    }
}
