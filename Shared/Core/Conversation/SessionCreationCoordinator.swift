import Foundation

enum SessionCreationError: LocalizedError {
    case unconfirmed(PendingSessionCreation, String)

    var errorDescription: String? {
        switch self {
        case let .unconfirmed(_, detail): detail
        }
    }
}

/// One durable operation across reconnect/retry. A transport error never mints a new ID.
enum SessionCreationCoordinator {
    static func create(
        hostID: String, runtimeID: String, cwd: String, supportsReceipts: Bool,
        call: (String, [String: Any]) async throws -> Any
    ) async throws -> SessionSummary {
        var params: [String: Any] = ["runtime": runtimeID]
        if !cwd.isEmpty { params["cwd"] = cwd }
        let record = supportsReceipts
            ? try PendingSessionCreationStore.begin(hostID: hostID, runtimeID: runtimeID, cwd: cwd) : nil
        if let record { params["command_id"] = record.commandID }
        var payload: Any
        if let record, Date().timeIntervalSince(record.createdAt) >= 7 * 24 * 60 * 60 {
            // Receipt retention expiry is not evidence that creation never ran.
            payload = try await call(WireProtocol.mCommandStatus, ["command_id": record.commandID])
        } else {
            payload = try await call(WireProtocol.mSessionNew, params)
        }
        let deadline = Date().addingTimeInterval(35)
        while true {
            guard let dict = payload as? [String: Any] else { throw RemoteClient.ConnectionError.invalidResponse }
            let result = dict["result"] as? [String: Any]
            if let raw = dict["session"] ?? result?["session"] {
                let session = try RemoteJSONDecoder.decode(SessionSummary.self, from: raw)
                if let record { try PendingSessionCreationStore.remove(record) }
                return session
            }
            guard let record else { throw RemoteClient.ConnectionError.invalidResponse }
            let status = CommandStatusResponse.statusString(from: payload) ?? "unknown"
            let detail = CommandStatusResponse.receipt(from: payload)?.detail
            if status == "rejected" {
                try PendingSessionCreationStore.remove(record)
                throw CommandDeliveryError.rejected(detail ?? String(localized: "chat.delivery.no_reason"))
            }
            if status != "accepted" && status != "dispatching" || Date() >= deadline {
                throw SessionCreationError.unconfirmed(
                    record, detail ?? String(localized: "session.new.unconfirmed")
                )
            }
            try await Task.sleep(for: .seconds(1))
            payload = try await call(WireProtocol.mCommandStatus, ["command_id": record.commandID])
        }
    }
}
