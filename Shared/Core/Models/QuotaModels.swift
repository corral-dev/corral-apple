import Foundation
import SubswapQuotaCore

nonisolated enum HostQuotaUnavailableReason: String, Codable, Sendable, Equatable {
    case subswapNotInstalled = "subswap_not_installed"
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

nonisolated struct HostQuotaResponse: Codable, Sendable, Equatable {
    var available: Bool
    var pending: Bool? = nil
    var reason: HostQuotaUnavailableReason? = nil
    var error: String? = nil
    var snapshot: SubswapSnapshot? = nil
    var fetchedAt: Double? = nil

    enum CodingKeys: String, CodingKey {
        case available
        case pending
        case reason
        case error
        case snapshot
        case fetchedAt = "fetched_at"
    }

    init(
        available: Bool,
        pending: Bool? = nil,
        reason: HostQuotaUnavailableReason? = nil,
        error: String? = nil,
        snapshot: SubswapSnapshot? = nil,
        fetchedAt: Double? = nil
    ) {
        self.available = available
        self.pending = pending
        self.reason = reason
        self.error = error
        self.snapshot = snapshot
        self.fetchedAt = fetchedAt
    }

    static func decode(from dictionary: [String: Any]) throws -> HostQuotaResponse {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try SnapshotCodec.decode(HostQuotaResponse.self, from: data)
    }

    static func decode(from payload: Any) throws -> HostQuotaResponse {
        guard let dictionary = payload as? [String: Any] else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(codingPath: [], debugDescription: "Expected dictionary for HostQuotaResponse")
            )
        }
        return try decode(from: dictionary)
    }
}

nonisolated struct CachedHostQuotas: Codable, Sendable, Equatable {
    var hostID: String
    var snapshot: SubswapSnapshot
    var savedAt: Date

    init(hostID: String, snapshot: SubswapSnapshot, savedAt: Date = .now) {
        self.hostID = hostID
        self.snapshot = snapshot
        self.savedAt = savedAt
    }
}

enum HostQuotaPresentationState: Equatable, Sendable {
    case loading
    case hostUnsupported
    case subswapNotInstalled
    case empty
    case failed(String)
    case ready(SubswapSnapshot)
}
