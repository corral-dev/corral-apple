import Foundation
import Observation
import XCTest
@testable import Corral

@MainActor
final class ClientPerformanceTests: XCTestCase {
    private func makeSessions(count: Int, baseTime: Double = 1_791_097_200) -> [SessionSummary] {
        (0..<count).map { idx in
            let attention: AttentionKind = idx.isMultiple(of: 10) ? .waiting : (idx.isMultiple(of: 5) ? .working : .none)
            let marker = attention == .waiting ? "waiting" : (attention == .working ? "working" : (idx.isMultiple(of: 7) ? "unread" : ""))
            return SessionSummary(
                key: "codex:perf-\(idx)",
                runtime: idx.isMultiple(of: 2) ? "codex" : "claude",
                title: "Session \(idx)",
                cwd: "/work/project-\(idx % 6)",
                mtime: baseTime - Double(idx) * 180,
                live: attention == .working,
                attention: attention,
                lastAgent: idx.isMultiple(of: 3) ? "**Bold** summary for session \(idx)" : "Plain summary \(idx)",
                pinned: idx < 3,
                marker: marker,
                needsAttention: attention != .none || !marker.isEmpty
            )
        }
    }

    // MARK: - 1. RemoteClient state-change event notifications & steady-state idempotency

    func testRemoteClientStateChangeHandlerIgnoresEqualWrites() {
        let client = RemoteClient(devicePrivateKey: Data(repeating: 1, count: 32))
        defer { client.disconnect() }
        var callbacks = 0
        let id = client.addStateChangeHandler {
            callbacks += 1
        }
        defer { client.removeStateChangeHandler(id) }

        client.setConnectionStateForTesting(.ready)
        client.controlConfirmed = true
        client.activeTransport = .local
        let afterInitial = callbacks
        XCTAssertEqual(afterInitial, 3)

        // Repeated equal writes must emit zero state-change callbacks.
        client.setConnectionStateForTesting(.ready)
        client.controlConfirmed = true
        client.activeTransport = .local
        XCTAssertEqual(callbacks, afterInitial)
    }

    // MARK: - 2. SessionListStore Observation & unchanged short-circuit

    func testSessionListStoreNoOpUnchangedAndEqualWindowDoNotInvalidate() {
        let store = SessionListStore()
        let sessions = makeSessions(count: 200)
        store.applyListResponse(SessionsListResponse(sessions: sessions, version: "v1", revision: 1))
        let epochAfterLoad = store.metadataEpoch
        let windowRevAfterLoad = store.windowRevision
        XCTAssertEqual(store.windowSessions.count, 200)
        XCTAssertEqual(store.waitingCount, 20)

        let invalidations = PerfObservationCounter()
        withObservationTracking {
            _ = store.sections
            _ = store.windowSessions
            _ = store.waitingCount
            _ = store.metadataEpoch
            _ = store.windowRevision
        } onChange: {
            invalidations.increment()
        }

        // Identical window reply should bump neither metadataEpoch nor windowRevision.
        store.applyListResponse(SessionsListResponse(sessions: sessions, version: "v1", revision: 2), persist: false)
        XCTAssertEqual(store.metadataEpoch, epochAfterLoad)
        XCTAssertEqual(store.windowRevision, windowRevAfterLoad)
        XCTAssertEqual(invalidations.value, 0)

        // Unchanged recheck response should short-circuit completely.
        store.applyListResponse(SessionsListResponse(sessions: [], version: "v1", unchanged: true, revision: 3), persist: false)
        XCTAssertEqual(store.metadataEpoch, epochAfterLoad)
        XCTAssertEqual(store.windowRevision, windowRevAfterLoad)
        XCTAssertEqual(invalidations.value, 0)
    }

    // MARK: - 3. Single-pass WireMessage & RemoteEvent decoding

    func testSinglePassWireEnvelopeAndEventDecoding() async throws {
        let sessionsPayload = (0..<10).map { i in
            [
                "key": "claude:s\(i)",
                "runtime": "claude",
                "title": "Title \(i)",
                "mtime": 1_791_097_200.0 + Double(i),
            ] as [String: Any]
        }
        let resMessage = WireMessage.response(
            id: 42,
            data: ["sessions": sessionsPayload, "version": "v42", "unchanged": false]
        )
        let unpackedData = try WireMessage.unpackPayload(try WireMessage.pack(resMessage, compression: false))
        let compressedData = try WireMessage.unpackPayload(try WireMessage.pack(resMessage, compression: true))
        XCTAssertEqual(unpackedData, compressedData)

        let header = try JSONDecoder().decode(WireFrameEnvelopeHeader.self, from: compressedData)
        XCTAssertEqual(header.t, "res")
        XCTAssertEqual(header.id, 42)
        XCTAssertEqual(header.ok, true)

        let decodedList = try await RemoteJSONDecoder.decodeEnvelopeDataOffMain(
            SessionsListResponse.self, from: compressedData
        )
        XCTAssertEqual(decodedList.sessions.count, 10)
        XCTAssertEqual(decodedList.version, "v42")

        // Float-encoded IDs and omitted `d` must decode safely.
        let floatHeader = try JSONDecoder().decode(
            WireFrameEnvelopeHeader.self,
            from: Data(#"{"t":"res","id":7.0,"ok":true,"wire":{"compression":"deflate"}}"#.utf8)
        )
        XCTAssertEqual(floatHeader.id, 7)
        XCTAssertEqual(floatHeader.wireCompression, "deflate")
        let emptyPrompts = try await RemoteJSONDecoder.decodeEnvelopeDataOffMain(
            SessionUserPromptsResponse.self,
            from: Data(#"{"t":"res","id":8,"ok":true,"d":{"prompts":[],"generation":3.0}}"#.utf8)
        )
        XCTAssertEqual(emptyPrompts.generation, 3)

        // Wire RemoteEvent exposes O(1) wireByteSize matching raw envelope size and lazy `.data`.
        let evtMessage = WireMessage.event(channel: "sessions", data: ["unchanged": true, "version": "v9"])
        let evtRaw = try WireMessage.dumps(evtMessage)
        let event = RemoteEvent(channel: "sessions", rawEnvelopeData: evtRaw)
        XCTAssertEqual(event.wireByteSize, evtRaw.count)
        XCTAssertEqual(event.data["version"] as? String, "v9")
    }

    // MARK: - 4. Parity checks for optimized helpers

    func testHelperOptimizationParity() throws {
        // DesktopLayout O(1) first-group-wins lookup including after mutation.
        let g1 = DesktopGroup(id: "g1", name: "First", members: ["a", "b"])
        let g2 = DesktopGroup(id: "g2", name: "Second", members: ["b", "c"])
        var layout = DesktopLayout(revision: 1, groups: [g1, g2], pinnedSessions: [:])
        XCTAssertEqual(layout.group(containing: "a")?.id, "g1")
        XCTAssertEqual(layout.group(containing: "b")?.id, "g1")
        XCTAssertEqual(layout.group(containing: "c")?.id, "g2")
        XCTAssertNil(layout.group(containing: "missing"))
        layout.groups.append(DesktopGroup(id: "g3", name: "Third", members: ["d"]))
        XCTAssertEqual(layout.group(containing: "d")?.id, "g3")

        // SessionQuickFilter zero-allocation count parity.
        let sessions = makeSessions(count: 60)
        for filter in SessionQuickFilter.allCases {
            let expected = (filter == .all ? SessionQuickFilter.attention : filter).apply(sessions: sessions).count
            XCTAssertEqual(filter.count(sessions: sessions), expected)
        }

        // SessionPresentation.preview strips bold delimiters cleanly.
        let boldSession = SessionSummary(key: "codex:b", lastAgent: "检查**中文**和**bold**渲染", lastMessageRole: "assistant")
        let plainSession = SessionSummary(key: "codex:p", lastAgent: "Plain single line   text", lastMessageRole: "assistant")
        XCTAssertEqual(SessionPresentation.preview(for: boldSession), "检查中文和bold渲染")
        XCTAssertEqual(SessionPresentation.preview(for: plainSession), "Plain single line text")

        // ConversationTimePolicy relative yesterday formatting remains intact.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date()
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let label = ConversationTimePolicy.label(for: yesterday, now: now, locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: calendar.timeZone)
        XCTAssertTrue(label.contains("Yesterday"))
    }

    // MARK: - 5. Performance Benchmarks

    func testBenchmark200SessionProjectionAndReplaceWindow() throws {
        let sessions = makeSessions(count: 200)
        let store = SessionListStore()
        var order = DesktopSidebarProjection.StableOrder()
        let cache = DesktopSidebarProjection.Cache()
        let now = Date(timeIntervalSince1970: 1_791_097_200)
        let layout = DesktopLayout(
            revision: 1,
            groups: [DesktopGroup(id: "g1", name: "G", members: sessions.prefix(4).map(\.key))],
            pinnedSessions: [sessions[5].key: 100]
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            store.applyListResponse(SessionsListResponse(sessions: sessions, version: "v1"), persist: false)
            _ = cache.sections(
                hostID: "bench",
                sessions: store.windowSessions,
                sessionsRevision: store.windowRevision,
                layout: layout,
                filter: "",
                order: &order,
                now: now,
                calendar: .current
            )
        }
    }

    func testBenchmarkSinglePassSessionsDecode() throws {
        let raw = try WireMessage.dumps(WireMessage.response(
            id: 1,
            data: [
                "version": "v100",
                "unchanged": false,
                "sessions": (0..<200).map { i in
                    [
                        "key": "codex:bench-\(i)",
                        "runtime": "codex",
                        "title": "Benchmark Session \(i)",
                        "cwd": "/work/repo-\(i % 5)",
                        "mtime": 1_791_097_200.0 - Double(i) * 60,
                        "live": i < 3,
                        "attention": i < 5 ? "waiting" : "none",
                        "marker": i < 5 ? "waiting" : "",
                    ] as [String: Any]
                },
            ]
        ))

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let decoded = try? RemoteJSONDecoder.decodeEnvelopeData(SessionsListResponse.self, from: raw)
            XCTAssertEqual(decoded?.sessions.count, 200)
        }
    }
}

private final class PerfObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
