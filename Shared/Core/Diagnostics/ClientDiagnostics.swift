import Foundation
import os

/// Deliberately closed vocabulary: callers cannot accidentally log a payload or URL.
nonisolated enum ClientDiagnosticEvent: String, Codable, Sendable {
    case created, stateChanged, raceStarted, raceWon, raceFailed, raceCancelled, staleWinner
    case disconnected, socketTeardown, planeFailed, reconnectScheduled
    case dataAttached, dataAttachFailed, dataRetryScheduled, dataRetryExhausted
    case responseReceived, responseRejected, orphanResponse, malformedResponse, slowRequest
    /// One plane's bounded outgoing queue rejected a frame; the plane resets.
    case planeOverload
    /// A slow event subscriber lost events and receives a coalesced resync marker.
    case eventGap
}

nonisolated enum ClientDiagnosticFailure: String, Codable, Sendable {
    case receive, ping, idleTimeout
}

nonisolated struct ClientDiagnosticRecord: Codable, Sendable {
    let sequence: Int
    let timestamp: TimeInterval
    let event: ClientDiagnosticEvent
    let plane: String?
    let durationMs: Double?
    let errorCode: Int?
    let reason: ClientDiagnosticFailure?
}

nonisolated struct ClientDiagnosticState: Codable, Sendable {
    let connection: String
    let transport: String?
    let dataAttached: Bool
    let pendingRequests: Int
    let subscriptions: Int
    let reconnectAttempt: Int
    let dataRebindAttempt: Int
    let lastReceiveAge: Double?
}

nonisolated struct ClientDiagnosticReport: Codable, Sendable {
    let schemaVersion: Int
    let clientRun: String
    let platform: String
    let processID: Int32
    let version: String
    let build: String
    let updatedAt: TimeInterval
    let state: ClientDiagnosticState
    let totalEvents: Int
    let counters: [String: Int]
    let completedWaits: Int
    let maxWaitMs: Double
    let slowWaits: Int
    let events: [ClientDiagnosticRecord]
}

/// Main-actor bookkeeping only; encoding, atomic writes and retention run on a serial queue.
@MainActor final class ClientDiagnostics {
    let clientRun = UUID().uuidString
    private(set) var events: [ClientDiagnosticRecord] = []
    private(set) var counters: [String: Int] = [:]
    private var sequence = 0
    private var pendingStarts: [Int: ContinuousClock.Instant] = [:]
    private var completedWaits = 0
    private var maxWaitMs = 0.0
    private var slowWaits = 0
    private var lastWrite = ContinuousClock.now
    private let directory: URL?
    private let writer = DispatchQueue(label: "com.x0c.corral.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "com.x0c.corral", category: "client")
    private let clock = ContinuousClock()

    init(directory: URL? = nil) {
        // XCTest/SPM never writes to real user storage. Explicit temp destinations are testable.
        self.directory = directory ?? (Bundle.main.bundleIdentifier == "com.x0c.corral"
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? AppStorageLocation.appDirectory.appendingPathComponent("diagnostics", isDirectory: true) : nil)
    }

    func record(_ event: ClientDiagnosticEvent, plane: String? = nil,
                durationMs: Double? = nil, errorCode: Int? = nil, reason: ClientDiagnosticFailure? = nil) {
        sequence += 1
        counters[event.rawValue, default: 0] += 1
        // Successful responses are counters, not an unbounded per-frame trace.
        if event != .responseReceived {
            events.append(ClientDiagnosticRecord(sequence: sequence, timestamp: Date().timeIntervalSince1970,
                event: event, plane: plane, durationMs: durationMs, errorCode: errorCode, reason: reason))
            if events.count > 128 { events.removeFirst(events.count - 128) }
            let label = event.rawValue
            let code = errorCode ?? 0
            let duration = durationMs ?? 0
            if event == .planeFailed || event == .raceFailed || event == .dataAttachFailed {
                logger.error("run=\(self.clientRun, privacy: .public) event=\(label, privacy: .public) code=\(code) ms=\(duration)")
            } else {
                logger.info("run=\(self.clientRun, privacy: .public) event=\(label, privacy: .public) ms=\(duration)")
            }
        }
    }

    func trackPending(_ ids: Set<Int>) {
        let now = ContinuousClock.now
        for id in ids where pendingStarts[id] == nil { pendingStarts[id] = now }
        for id in Array(pendingStarts.keys) where !ids.contains(id) {
            guard let start = pendingStarts.removeValue(forKey: id) else { continue }
            let ms = start.duration(to: now).milliseconds
            completedWaits += 1
            maxWaitMs = max(maxWaitMs, ms)
            if ms >= 1_000 {
                slowWaits += 1
                record(.slowRequest, durationMs: ms)
            }
        }
    }

    private static var platform: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    func report(state: ClientDiagnosticState) -> ClientDiagnosticReport {
        ClientDiagnosticReport(schemaVersion: 1, clientRun: clientRun,
            platform: Self.platform,
            processID: ProcessInfo.processInfo.processIdentifier,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            updatedAt: Date().timeIntervalSince1970, state: state, totalEvents: sequence,
            counters: counters, completedWaits: completedWaits, maxWaitMs: maxWaitMs, slowWaits: slowWaits, events: events)
    }

    func persist(state: ClientDiagnosticState, force: Bool = false) {
        guard let directory else { return }
        let now = clock.now
        guard force || lastWrite.duration(to: now) >= .seconds(1) else { return }
        lastWrite = now
        let snapshot = report(state: state)
        writer.async {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let destination = directory.appendingPathComponent("client-\(snapshot.processID)-\(snapshot.clientRun).json")
                try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let reports = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.lastPathComponent.hasPrefix("client-") && $0.pathExtension == "json" }
                    .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for old in reports.dropFirst(16) { try? fm.removeItem(at: old) }
            } catch {
                // Telemetry must never change user operations or retry behavior.
                Logger(subsystem: "com.x0c.corral", category: "client").error("Diagnostic persistence failed")
            }
        }
    }
}

@MainActor extension RemoteClient {
    var diagnosticState: ClientDiagnosticState {
        ClientDiagnosticState(connection: state == .ready && !controlConfirmed ? "handshaking" : String(describing: state),
            transport: activeTransport.map { String(describing: $0) }, dataAttached: hasDataPlane && dataPlaneConfirmed,
            pendingRequests: pendingRequests.count,
            subscriptions: wildcardSubscribers.count + channelSubscribers.values.reduce(0) { $0 + $1.count },
            reconnectAttempt: reconnectAttempt, dataRebindAttempt: dataPlaneRebindAttempt,
            lastReceiveAge: lastReceiveAge)
    }

    func persistDiagnostics() {
        diagnostics.persist(state: diagnosticState)
    }

    func diagnose(_ event: ClientDiagnosticEvent, isControl: Bool? = nil,
                  durationMs: Double? = nil, error: (any Error)? = nil, reason: ClientDiagnosticFailure? = nil) {
        diagnostics.record(event, plane: isControl.map { $0 ? "control" : "data" },
                           durationMs: durationMs, errorCode: error.map { ($0 as NSError).code }, reason: reason)
        diagnostics.persist(state: diagnosticState, force: event == .created || event == .disconnected)
    }
}

nonisolated extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
