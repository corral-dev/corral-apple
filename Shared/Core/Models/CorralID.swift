import CryptoKit
import Foundation

/// Stateless short Corral session ID (`<2-char runtime prefix><6-char Crockford Base32>`).
/// Matches `cli/src/corral/corral_id.py` byte-for-byte so clients work identically offline.
nonisolated enum CorralID {
    static let alphabet: [Character] = Array("0123456789abcdefghjkmnpqrstvwxyz")

    private static let runtimePrefixes: [String: String] = [
        "claude": "cc",
        "codex": "cx",
        "opencode": "oc",
        "cursor": "cu",
        "pi": "pi",
        "antigravity": "ag",
        "kimi": "km",
    ]

    static func runtimePrefix(_ runtimeID: String?) -> String {
        let rt = (runtimeID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = runtimePrefixes[rt] {
            return known
        }
        let cleaned = rt.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if cleaned.count >= 2 {
            return String(cleaned.prefix(2))
        }
        if cleaned.count == 1 {
            return cleaned + "x"
        }
        return "un"
    }

    static func derive(runtime runtimeID: String?, sessionID: String?) -> String {
        let rt = (runtimeID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sid = (sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rt.isEmpty, !sid.isEmpty, rt != "shell" else { return "" }

        let digest = SHA256.hash(data: Data("\(rt):\(sid)".utf8))
        var bytes = digest.makeIterator()
        guard let b0 = bytes.next(),
              let b1 = bytes.next(),
              let b2 = bytes.next(),
              let b3 = bytes.next() else {
            return ""
        }
        let top32 = (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
        let value = top32 >> 2

        var suffix = ""
        suffix.reserveCapacity(6)
        for shift in stride(from: 25, through: 0, by: -5) {
            let idx = Int((value >> UInt32(shift)) & 0x1F)
            suffix.append(alphabet[idx])
        }
        return runtimePrefix(rt) + suffix
    }

    static func forSession(_ session: SessionSummary) -> String {
        if let explicit = session.corralID {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return derive(runtime: session.runtime, sessionID: session.sessionID)
    }

    static func normalize(_ raw: String?) -> String {
        let text = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        guard text.count == 8 else { return text }
        let prefix = text.prefix(2)
        let suffix = text.dropFirst(2).map { ch -> Character in
            switch ch {
            case "i", "l": return "1"
            case "o": return "0"
            default: return ch
            }
        }
        return String(prefix) + String(suffix)
    }

    static func matches(_ session: SessionSummary, query: String) -> Bool {
        let cid = forSession(session)
        guard !cid.isEmpty else { return false }
        let norm = normalize(query)
        return !norm.isEmpty && cid == norm
    }
}
