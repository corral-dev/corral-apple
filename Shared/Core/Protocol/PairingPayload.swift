import Foundation

/// 解析 `corral://pair?v=2&n=&k=&c=&r=&l=` 配对链接。
///
/// 二维码里不含任何私钥；路由标识由开发机 X25519 公钥派生，不再带 `h`。
nonisolated struct PairingPayload: Codable, Sendable, Equatable {
    let version: String
    let hostID: String
    let hostName: String
    /// 开发机 X25519 长期公钥（32 字节）。
    let hostPublicKey: Data
    let pairingCode: String
    let relayURL: String?
    /// 局域网直连提示，形如 `192.168.1.5:8737,10.0.0.3:8737`。
    let localHints: [String]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case hostID = "h"
        case hostName = "n"
        case hostPublicKeyHex = "k"
        case pairingCode = "c"
        case relayURL = "r"
        case localHints = "l"
    }

    init(
        version: String = "1",
        hostID: String,
        hostName: String,
        hostPublicKey: Data,
        pairingCode: String,
        relayURL: String? = nil,
        localHints: [String] = []
    ) {
        self.version = version
        self.hostID = hostID
        self.hostName = hostName
        self.hostPublicKey = hostPublicKey
        self.pairingCode = pairingCode
        self.relayURL = relayURL
        self.localHints = localHints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1"
        let storedHostID = try container.decode(String.self, forKey: .hostID)
        hostName = try container.decode(String.self, forKey: .hostName)
        pairingCode = try container.decode(String.self, forKey: .pairingCode)
        relayURL = try container.decodeIfPresent(String.self, forKey: .relayURL)

        let keyString = try container.decode(String.self, forKey: .hostPublicKeyHex)
        hostPublicKey = try Self.decodePublicKey(keyString)

        // Single source of truth: hostID is derived from the public key.
        // A stored `h` that disagrees means a stale/hand-edited payload: reject.
        let derived = try RemoteCryptoKeys.routingID(fromX25519: hostPublicKey)
        guard storedHostID == derived else { throw PairingParseError.hostIDMismatch }
        hostID = derived

        if let hints = try container.decodeIfPresent(String.self, forKey: .localHints), !hints.isEmpty {
            localHints = hints.split(separator: ",").map(String.init)
        } else {
            localHints = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(hostName, forKey: .hostName)
        try container.encode(pairingCode, forKey: .pairingCode)
        try container.encodeIfPresent(relayURL, forKey: .relayURL)
        try container.encode(Self.encodePublicKeyBase64URL(hostPublicKey), forKey: .hostPublicKeyHex)
        if !localHints.isEmpty {
            try container.encode(localHints.joined(separator: ","), forKey: .localHints)
        }
    }
}

nonisolated extension PairingPayload {
    /// 从 `corral://pair?...` URL 解析配对信息。
    static func parse(url: URL) throws -> PairingPayload {
        guard url.scheme?.lowercased() == "corral", url.host?.lowercased() == "pair" else {
            throw PairingParseError.invalidScheme
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else {
            throw PairingParseError.missingQuery
        }

        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        guard let hostName = value("n") else {
            throw PairingParseError.missingField("n")
        }
        guard let keyString = value("k"), !keyString.isEmpty else {
            throw PairingParseError.missingField("k")
        }
        guard let code = value("c"), !code.isEmpty else {
            throw PairingParseError.missingField("c")
        }

        let version = value("v") ?? "1"
        if version != "2" {
            throw PairingParseError.unsupportedVersion
        }
        let hostPublicKey = try decodePublicKey(keyString)
        let hostID = try RemoteCryptoKeys.routingID(fromX25519: hostPublicKey)
        // `h` is advisory only: if present it must match the derived routing ID.
        if let claimed = value("h"), !claimed.isEmpty, claimed != hostID {
            throw PairingParseError.hostIDMismatch
        }
        let relay = value("r")
        let hintsRaw = value("l") ?? ""
        let hints = hintsRaw.isEmpty ? [] : hintsRaw.split(separator: ",").map(String.init)

        return PairingPayload(
            version: version,
            hostID: hostID,
            hostName: hostName,
            hostPublicKey: hostPublicKey,
            pairingCode: code,
            relayURL: relay?.isEmpty == true ? nil : relay,
            localHints: hints
        )
    }

    /// 解析字符串形式的配对链接。
    static func parse(string: String) throws -> PairingPayload {
        guard let url = URL(string: string) else {
            throw PairingParseError.invalidURL
        }
        return try parse(url: url)
    }

    /// 优先局域网直连，否则走中继。
    var preferredWebSocketURL: URL? {
        if let hint = localHints.first {
            let trimmed = hint.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
                return URL(string: trimmed)
            }
            return URL(string: "ws://\(trimmed)")
        }
        guard let relayURL, !relayURL.isEmpty else { return nil }
        let base = relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL
        var components = URLComponents(string: "\(base)/v2/device")
        components?.queryItems = [URLQueryItem(name: "host", value: hostID)]
        return components?.url
    }

    /// k 参数：base64url 无 padding，与 Python `build_payload` 一致。
    static func decodePublicKey(_ value: String) throws -> Data {
        if let hex = try? decodeHex(value) {
            return hex
        }
        return try decodeBase64URL(value)
    }

    static func encodePublicKeyBase64URL(_ key: Data) -> String {
        key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeHex(_ value: String) throws -> Data {
        guard value.count == 64, let data = Data(hexString: value) else {
            throw PairingParseError.invalidPublicKey
        }
        return data
    }

    private static func decodeBase64URL(_ value: String) throws -> Data {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count == 32 else {
            throw PairingParseError.invalidPublicKey
        }
        return data
    }
}

nonisolated enum PairingParseError: Error, Sendable, LocalizedError {
    case invalidScheme
    case invalidURL
    case missingQuery
    case missingField(String)
    case invalidPublicKey
    case unsupportedVersion
    case hostIDMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            String(localized: "pairing.error.outdated_host")
        case .invalidScheme, .invalidURL, .missingQuery:
            String(localized: "pairing.error.unrecognized")
        case let .missingField(name):
            String(localized: "pairing.error.missing_field \(name)")
        case .invalidPublicKey, .hostIDMismatch:
            String(localized: "pairing.error.invalid_key")
        }
    }
}

private nonisolated extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard next <= hexString.endIndex,
                  let byte = UInt8(hexString[index ..< next], radix: 16)
            else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
