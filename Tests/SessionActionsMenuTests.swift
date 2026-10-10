import Foundation
@testable import Corral
import XCTest

/// 会话页右上复制/接力菜单状态机单测：readonly 隐藏、unavailable 隐藏、
/// 离线禁用、新 session 解码。纯逻辑断言，不碰界面与真机。
@MainActor
final class SessionActionsMenuTests: XCTestCase {

    private func summary(key: String = "abc123", runtime: String? = "claude") -> SessionSummary {
        SessionSummary(key: key, runtime: runtime, title: "demo")
    }

    // MARK: - 只读配对隐藏整单

    func testReadonlyHidesWholeMenu() {
        XCTAssertFalse(SessionActionsMenu.isMenuVisible(access: "readonly"))
        XCTAssertFalse(SessionActionsMenu.isMenuVisible(access: " readonly "))
        XCTAssertFalse(SessionActionsMenu.isMenuVisible(access: "ReadOnly"))
    }

    func testFullAndLegacyMissingAccessShowMenu() {
        XCTAssertTrue(SessionActionsMenu.isMenuVisible(access: "full"))
        XCTAssertTrue(SessionActionsMenu.isMenuVisible(access: ""))
        // 旧开发机 hello 无 access 字段（nil）：按 full 处理，显示菜单。
        XCTAssertTrue(SessionActionsMenu.isMenuVisible(access: nil))
    }

    func testHelloAccessDecodesAndDetectsReadonly() throws {
        let readonly = try RemoteJSONDecoder.decode(
            HelloResponse.self,
            from: ["paired": true, "access": "readonly"] as [String: Any]
        )
        XCTAssertEqual(readonly.access, "readonly")
        XCTAssertTrue(readonly.isReadonlyPairing)
        XCTAssertFalse(SessionActionsMenu.isMenuVisible(access: readonly.access))

        let legacy = try RemoteJSONDecoder.decode(
            HelloResponse.self,
            from: ["paired": true] as [String: Any]
        )
        XCTAssertNil(legacy.access)
        XCTAssertFalse(legacy.isReadonlyPairing)
        XCTAssertTrue(SessionActionsMenu.isMenuVisible(access: legacy.access))
    }

    // MARK: - unavailable 隐藏该行（不是置灰）

    func testUnavailableRuntimeHiddenNotGreyed() {
        let runtimes = [
            RuntimeEntry(id: "claude", name: "Claude", available: true),
            RuntimeEntry(id: "kimi", name: "Kimi", available: false),
            RuntimeEntry(id: "pi", name: "Pi", available: nil),
        ]
        let targets = SessionActionsMenu.handoffTargets(from: runtimes)
        XCTAssertEqual(targets.map(\.id), ["claude", "pi"])
    }

    func testMissingAvailableDecodesNilAndStaysUsable() throws {
        let entry = try RemoteJSONDecoder.decode(
            RuntimeEntry.self,
            from: ["id": "codex", "name": "Codex"] as [String: Any]
        )
        XCTAssertNil(entry.available)
        XCTAssertTrue(entry.isUsable)
        XCTAssertEqual(SessionActionsMenu.handoffTargets(from: [entry]).count, 1)
    }

    func testExplicitFalseDecodesUnavailable() throws {
        let entry = try RemoteJSONDecoder.decode(
            RuntimeEntry.self,
            from: ["id": "kimi", "name": "Kimi", "available": false] as [String: Any]
        )
        XCTAssertEqual(entry.available, false)
        XCTAssertFalse(entry.isUsable)
        XCTAssertTrue(SessionActionsMenu.handoffTargets(from: [entry]).isEmpty)
    }

    // MARK: - 离线禁用

    func testOfflineDisablesMenu() {
        XCTAssertFalse(SessionActionsMenu.isMenuEnabled(clientReady: false))
        XCTAssertTrue(SessionActionsMenu.isMenuEnabled(clientReady: true))
    }

    // MARK: - 新 session 解码

    func testDecodeNewSessionFromCopyPayload() throws {
        let payload: [String: Any] = [
            "session": [
                "key": "new-key-1",
                "runtime": "claude",
                "title": "copied",
            ] as [String: Any],
        ]
        let created = try SessionActionsMenu.decodeNewSession(from: payload)
        XCTAssertEqual(created.key, "new-key-1")
        XCTAssertEqual(created.runtime, "claude")
    }

    func testDecodeNewSessionMissingSessionThrows() {
        XCTAssertThrowsError(
            try SessionActionsMenu.decodeNewSession(from: ["ok": true] as [String: Any])
        )
    }

    // MARK: - 失败透服务端 message，缺 message 走 error.unknown

    func testFailureMessagePassesThroughServerMessage() {
        let remote = RemoteCallError(code: "unavailable", message: "助手不可用", hint: "")
        XCTAssertEqual(SessionActionsMenu.failureMessage(for: remote), "助手不可用")
    }

    func testFailureMessageFallsBackToUnknown() {
        struct Plain: Error {}
        XCTAssertEqual(
            SessionActionsMenu.failureMessage(for: Plain()),
            String(localized: "error.unknown")
        )
    }

    // MARK: - RPC 参数约定（与 CLI session.copy 并行实现锁定）

    func testCopyAndHandoffParams() {
        XCTAssertEqual(
            SessionActionsMenu.copyParams(sourceKey: "k1") as? [String: String],
            ["key": "k1"]
        )
        let handoff = SessionActionsMenu.handoffParams(sourceKey: "k1", targetRuntimeID: "kimi")
        XCTAssertEqual(handoff["key"] as? String, "k1")
        XCTAssertEqual(handoff["runtime"] as? String, "kimi")
    }

    func testKimiTargetNeedsNotice() {
        XCTAssertTrue(SessionActionsMenu.needsKimiNotice(runtimeID: "kimi"))
        XCTAssertTrue(SessionActionsMenu.needsKimiNotice(runtimeID: "Kimi"))
        XCTAssertFalse(SessionActionsMenu.needsKimiNotice(runtimeID: "claude"))
    }

    // MARK: - 方法常量

    func testSessionCopyMethodName() {
        XCTAssertEqual(WireProtocol.mSessionCopy, "session.copy")
        XCTAssertEqual(WireProtocol.mSessionHandoff, "session.handoff")
    }
}
