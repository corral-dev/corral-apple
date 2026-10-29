@testable import Corral
import XCTest

/// Focus reports are the emulator's, not the person's: they must not retire a prompt jump.
final class TerminalInputPassiveTests: XCTestCase {
    func testFocusReportsAreRecognised() {
        XCTAssertTrue(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[I".utf8))))
        XCTAssertTrue(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[O\u{1b}[I".utf8))))
    }

    func testTypingIsNotAFocusReport() {
        XCTAssertFalse(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[A".utf8))))
        XCTAssertFalse(TerminalInputSender.isFocusReport(ArraySlice(Array("abc".utf8))))
        XCTAssertFalse(TerminalInputSender.isFocusReport(ArraySlice(Array("\u{1b}[Ix".utf8))))
        XCTAssertFalse(TerminalInputSender.isFocusReport([]))
    }

    // MARK: - Raw stream recovery and retention (memory slice 2026-10-25)

    @MainActor
    func testGapMarkerDiscardsTheStaleBacklogAndRequestsASnapshot() async throws {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        let stream = RemoteTerminalStream(sessionKey: "codex:fixture", client: client)
        stream.start()
        defer { stream.stop() }
        stream.inspectionHandle(snapshot(seq: 1, bytes: 32))
        XCTAssertGreaterThan(stream.inspectionBacklogBytes, 0)
        XCTAssertEqual(stream.phase, .live)

        stream.inspectionHandle(["resync": true, "dropped": 7])
        XCTAssertEqual(stream.inspectionBacklogBytes, 0,
                       "A truncated stream must not be replayed as if it were complete")
        XCTAssertEqual(stream.phase, .connecting, "Missing bytes require a complete screen before returning live")
        XCTAssertTrue(stream.hasBeenLive, "Recovery retains the cached-screen presentation contract")
        let deadline = ContinuousClock.now + .seconds(8)
        while stream.phase == .connecting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if case .failed = stream.phase {} else {
            XCTFail("An unavailable transport must reach the bounded Retry state, not spin forever")
        }
        let requests = client.diagnostics.events.compactMap(\.terminal)
            .filter { $0.operation == .resync && $0.result == .started }
        XCTAssertEqual(requests.count, 2, "A transient failure retries, but never starts an unbounded RPC loop")
        stream.inspectionHandle(snapshot(seq: 4, bytes: 32))
        XCTAssertEqual(stream.phase, .live, "A late complete screen also repairs the exhausted recovery")
    }

    @MainActor
    func testUnattachedTerminalBacklogStaysWithinItsByteCeiling() {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        let stream = RemoteTerminalStream(sessionKey: "codex:fixture", client: client)
        let chunk = Data(repeating: 66, count: 256 * 1024).base64EncodedString()
        stream.inspectionHandle(["kind": "snapshot", "seq": 1, "cols": 80, "rows": 24, "data": chunk])
        var seq = 1
        for _ in 0..<40 {
            seq += 1
            stream.inspectionHandle(["kind": "output", "seq": seq, "data": chunk])
        }
        XCTAssertLessThanOrEqual(stream.inspectionBacklogBytes, RemoteTerminalStream.backlogByteLimit)
        XCTAssertTrue(stream.inspectionNeedsResync,
                      "The dropped tail is recovered from a fresh snapshot, not silently lost")
    }

    @MainActor
    func testAttachedTerminalReplaysSnapshotThenOutputInOrder() {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 0, count: 32))
        defer { client.disconnect() }
        let stream = RemoteTerminalStream(sessionKey: "codex:fixture", client: client)
        stream.inspectionHandle(snapshot(seq: 1, text: "AAAA"))
        stream.inspectionHandle(output(seq: 2, text: "BBBB"))
        stream.inspectionHandle(output(seq: 3, text: "CCCC"))

        let sink = RecordingTerminalSink()
        stream.sink = sink
        XCTAssertEqual(sink.resets.count, 1)
        XCTAssertEqual(sink.resets.first?.grid, TerminalGrid(cols: 80, rows: 24))
        XCTAssertEqual(sink.resets.first?.data, Data("AAAA".utf8))
        XCTAssertEqual(sink.feeds, [Data("BBBB".utf8), Data("CCCC".utf8)])
        XCTAssertEqual(stream.inspectionBacklogBytes, 0)
    }

    private func snapshot(seq: Int, bytes: Int) -> [String: Any] {
        snapshot(seq: seq, text: String(repeating: "A", count: bytes))
    }

    private func snapshot(seq: Int, text: String) -> [String: Any] {
        ["kind": "snapshot", "seq": seq, "cols": 80, "rows": 24,
         "data": Data(text.utf8).base64EncodedString()]
    }

    private func output(seq: Int, text: String) -> [String: Any] {
        ["kind": "output", "seq": seq, "data": Data(text.utf8).base64EncodedString()]
    }
}

@MainActor
private final class RecordingTerminalSink: TerminalStreamSink {
    var resets: [(grid: TerminalGrid, data: Data)] = []
    var feeds: [Data] = []

    func terminalReset(grid: TerminalGrid, data: Data) {
        resets.append((grid, data))
    }

    func terminalFeed(_ data: Data) {
        feeds.append(data)
    }

    func terminalRevealPrompt(_ query: String) -> Bool { false }
}
