import XCTest
@testable import Corral

final class HostConnectionTests: XCTestCase {
    func testStaysOnSameHostWhenAlreadyReady() {
        XCTAssertFalse(
            HostConnectionDecision.needsReconnect(
                connectedHostID: "suzhou",
                targetHostID: "suzhou",
                isReady: true
            )
        )
    }

    func testReconnectsWhenSwitchingHosts() {
        XCTAssertTrue(
            HostConnectionDecision.needsReconnect(
                connectedHostID: "suzhou",
                targetHostID: "mac",
                isReady: true
            )
        )
    }

    func testReconnectsWhenNotReadyEvenIfSelectedMatches() {
        // 旧实现先改选中项再判断，这里即使目标与「选中」相同，未就绪也必须建连。
        XCTAssertTrue(
            HostConnectionDecision.needsReconnect(
                connectedHostID: nil,
                targetHostID: "mac",
                isReady: false
            )
        )
    }

    func testReconnectsWhenReadyButConnectedHostUnknown() {
        XCTAssertTrue(
            HostConnectionDecision.needsReconnect(
                connectedHostID: nil,
                targetHostID: "mac",
                isReady: true
            )
        )
    }

    func testControlHelloParamsAskForDataPlane() {
        let params = WireProtocol.controlHelloParams(name: "iPhone")
        XCTAssertEqual(params["name"] as? String, "iPhone")
        XCTAssertEqual(params["want_data_plane"] as? Bool, true)
        XCTAssertEqual(params["want_command_receipts"] as? Bool, true)
        XCTAssertNil(params["plane"])
        XCTAssertNil(params["bind"])
    }

    func testDataHelloParamsShape() {
        let params = WireProtocol.dataHelloParams(bind: "token-1", name: "iPhone")
        XCTAssertEqual(params["plane"] as? String, WireProtocol.planeData)
        XCTAssertEqual(params["bind"] as? String, "token-1")
        XCTAssertEqual(params["name"] as? String, "iPhone")
        XCTAssertNil(params["want_data_plane"])
    }

    func testOldHelloPayloadDoesNotAttachDataPlane() {
        XCTAssertFalse(WireProtocol.shouldAttachDataPlane(dataBind: nil))
        XCTAssertFalse(WireProtocol.shouldAttachDataPlane(dataBind: ""))
        XCTAssertNil(WireProtocol.dataBind(fromHelloPayload: ["paired": true]))
        XCTAssertNil(WireProtocol.dataBind(fromHelloPayload: ["data_bind": ""]))
    }

    func testNewHelloPayloadExposesBindToken() {
        let payload: [String: Any] = [
            "paired": true,
            "data_bind": "abc123",
            "capabilities": ["planes": ["control", "data"]],
        ]
        XCTAssertEqual(WireProtocol.dataBind(fromHelloPayload: payload), "abc123")
        XCTAssertTrue(WireProtocol.shouldAttachDataPlane(dataBind: "abc123"))
    }

    func testHistoryAndScreenMethodsUseDataPlane() {
        XCTAssertTrue(WireProtocol.usesDataPlane(WireProtocol.mSessionMessages))
        XCTAssertTrue(WireProtocol.usesDataPlane(WireProtocol.mSessionGet))
        XCTAssertTrue(WireProtocol.usesDataPlane(WireProtocol.mSessionWatch))
        XCTAssertTrue(WireProtocol.usesDataPlane(WireProtocol.mScreenWatch))
        XCTAssertTrue(WireProtocol.usesDataPlane(WireProtocol.mScreenScroll))
        XCTAssertFalse(WireProtocol.usesDataPlane(WireProtocol.mHello))
        XCTAssertFalse(WireProtocol.usesDataPlane(WireProtocol.mInputText))
        XCTAssertFalse(WireProtocol.usesDataPlane(WireProtocol.mSessionsWatch))
        XCTAssertFalse(WireProtocol.usesDataPlane(WireProtocol.mScreenResize))
    }

    func testKeepaliveIntervalsLeaveHandshakeTimeoutsAlone() {
        XCTAssertEqual(RemoteKeepalive.pingInterval, 15)
        XCTAssertEqual(RemoteKeepalive.idleTimeout, 45)
        XCTAssertLessThan(RemoteKeepalive.pingInterval, RemoteKeepalive.idleTimeout)
        XCTAssertGreaterThan(RemoteKeepalive.idleTimeout, 8)
    }

    func testForegroundForceReconnectOnlyWhenReadyAndIdle() {
        XCTAssertTrue(ForegroundReconnectDecision.shouldForceReconnect(isReady: true, isIdle: true))
        XCTAssertFalse(ForegroundReconnectDecision.shouldForceReconnect(isReady: true, isIdle: false))
        XCTAssertFalse(ForegroundReconnectDecision.shouldForceReconnect(isReady: false, isIdle: true))
        XCTAssertFalse(ForegroundReconnectDecision.shouldForceReconnect(isReady: false, isIdle: false))
    }

    func testDataPlaneRebindRetriesWhileControlReady() {
        XCTAssertTrue(
            DataPlaneRebindPolicy.shouldRetry(attempt: 1, controlReady: true, dataPlaneAttached: false)
        )
        XCTAssertTrue(
            DataPlaneRebindPolicy.shouldRetry(attempt: 5, controlReady: true, dataPlaneAttached: false)
        )
        XCTAssertTrue(
            DataPlaneRebindPolicy.shouldRetry(attempt: 6, controlReady: true, dataPlaneAttached: false)
        )
        XCTAssertFalse(
            DataPlaneRebindPolicy.shouldRetry(attempt: 1, controlReady: false, dataPlaneAttached: false)
        )
        XCTAssertFalse(
            DataPlaneRebindPolicy.shouldRetry(attempt: 1, controlReady: true, dataPlaneAttached: true)
        )
        XCTAssertEqual(DataPlaneRebindPolicy.delay(forAttempt: 1), 1)
        XCTAssertEqual(DataPlaneRebindPolicy.delay(forAttempt: 2), 2)
        XCTAssertEqual(DataPlaneRebindPolicy.delay(forAttempt: 3), 4)
        XCTAssertEqual(DataPlaneRebindPolicy.delay(forAttempt: 5), 16)
    }
}
