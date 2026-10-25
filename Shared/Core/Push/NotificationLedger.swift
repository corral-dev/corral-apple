import Foundation
import CryptoKit

/// Stable local request identities; APNs and desktop delivery have separate ledgers.
nonisolated enum SessionNotificationKind: String, Codable, Sendable {
    case waiting, completed, aborted, transient

    @MainActor func identity(hostID: String, session: SessionSummary) -> String? {
        guard ActiveRuntimeVisibility.isListVisible(session) else { return nil }
        if self == .completed && session.completionID.isEmpty { return nil }
        let anchor = self == .waiting || session.completionID.isEmpty
            ? String(session.mtime) : session.completionID
        guard !hostID.isEmpty, !session.key.isEmpty, !anchor.isEmpty else { return nil }
        let data = Data([hostID, session.key, rawValue, anchor].map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct NotificationLedger: Codable, Sendable {
    private(set) var accepted: [String: Double] = [:]

    func contains(_ id: String) -> Bool { accepted[id] != nil }

    mutating func record(_ id: String, now: Double = Date().timeIntervalSince1970) {
        accepted[id] = now
        if accepted.count > 4096 {
            for key in accepted.keys.sorted(by: { accepted[$0]! < accepted[$1]! }).prefix(accepted.count - 4096) {
                accepted[key] = nil
            }
        }
    }
}
