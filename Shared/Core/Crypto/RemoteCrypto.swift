import CryptoKit
import Foundation

/// 与 Python `corral.remote.crypto` 完全互通的端到端加密层。
///
/// 选用 X25519 + HKDF-SHA256 + ChaCha20-Poly1305，是因为 iOS/macOS 的 CryptoKit
/// 原生支持这三样，不需要在 App 里塞第三方密码库（NaCl 的 XSalsa20 在 CryptoKit 里没有对应物）。
enum RemoteCryptoError: Error, Sendable {
    case invalidKeyLength
    case invalidPublicKey(String)
    case channel(String)
    case push(String)
}

// MARK: - 常量（与 Python 侧 info 字符串逐字节一致）

nonisolated enum RemoteCryptoConstants {
    static let infoD2H = Data("corral/remote/v2 d2h".utf8)
    static let infoH2D = Data("corral/remote/v2 h2d".utf8)
    static let infoPush = Data("corral/remote/v2 push".utf8)
    static let routeContext = Data("corral/relay/v2 route".utf8)
    static let keyLength = 32
    static let nonceLength = 12
    static let publicKeyLength = 32
    static let maxCounter: UInt64 = .max
}

// MARK: - 密钥工具

nonisolated enum RemoteCryptoKeys {
    /// 生成新的 X25519 长期私钥（32 字节原始格式）。
    static func generatePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    /// 从 32 字节私钥导出公钥。
    static func publicKey(from privateKey: Data) throws -> Data {
        guard privateKey.count == RemoteCryptoConstants.publicKeyLength else {
            throw RemoteCryptoError.invalidKeyLength
        }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        return key.publicKey.rawRepresentation
    }

    /// X25519 原始共享秘密，与 Python `private.exchange(peer)` 一致。
    static func diffieHellman(privateKey: Data, peerPublic: Data) throws -> Data {
        try validatePublic(peerPublic, label: "对端公钥")
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        let secret = try priv.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    static func validatePublic(_ value: Data, label: String) throws {
        guard value.count == RemoteCryptoConstants.publicKeyLength else {
            throw RemoteCryptoError.invalidPublicKey("\(label)长度不合法")
        }
    }

    /// 与 Python `routing_id_from_x25519` 一致：SHA256(context‖pub)[:16] 的小写无 padding base32。
    static func routingID(fromX25519 publicKey: Data) throws -> String {
        try validatePublic(publicKey, label: "开发机长期公钥")
        var hasher = SHA256()
        hasher.update(data: RemoteCryptoConstants.routeContext)
        hasher.update(data: publicKey)
        let digest = hasher.finalize()
        let truncated = Data(digest.prefix(16))
        return base32LowerNoPad(truncated)
    }

    private static func base32LowerNoPad(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bits: UInt32 = 0
        var bitCount = 0
        var output = ""
        for byte in data {
            bits = (bits << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((bits >> bitCount) & 0x1F)
                output.append(alphabet[index])
            }
        }
        if bitCount > 0 {
            let index = Int((bits << (5 - bitCount)) & 0x1F)
            output.append(alphabet[index])
        }
        return output
    }
}

// MARK: - HKDF-SHA256（自实现，与 Python `_hkdf` 逐步对齐，避免 CryptoKit 内置 HKDF 参数差异）

nonisolated enum RemoteHKDF {
    /// Python: `prk = hmac.new(salt, ikm, sha256).digest()` 然后标准 HKDF-Expand。
    static func derive(
        ikm: Data,
        salt: Data,
        info: Data,
        length: Int = RemoteCryptoConstants.keyLength
    ) -> Data {
        let prkKey = SymmetricKey(data: salt)
        let prk = Data(HMAC<SHA256>.authenticationCode(for: ikm, using: prkKey))

        var output = Data()
        var block = Data()
        var counter: UInt8 = 1
        let prkSymmetric = SymmetricKey(data: prk)

        while output.count < length {
            var message = block
            message.append(info)
            message.append(counter)
            block = Data(HMAC<SHA256>.authenticationCode(for: message, using: prkSymmetric))
            output.append(block)
            counter += 1
        }
        return output.prefix(length)
    }
}

// MARK: - 加密通道

/// 已完成握手的双向加密通道。非线程安全，调用方需串行化（RemoteClient 在 MainActor 上保证这一点）。
nonisolated final class SecureChannel: @unchecked Sendable {
    let peerStaticPublic: Data
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    init(sendKey: Data, recvKey: Data, peerStaticPublic: Data) {
        self.sendKey = SymmetricKey(data: sendKey)
        self.recvKey = SymmetricKey(data: recvKey)
        self.peerStaticPublic = peerStaticPublic
    }

    /// 随机数 = 4 字节零 ‖ 8 字节大端计数器；线上只传后 8 字节。
    private func nonce(for counter: UInt64) throws -> ChaChaPoly.Nonce {
        guard counter <= RemoteCryptoConstants.maxCounter else {
            throw RemoteCryptoError.channel("加密通道随机数已耗尽")
        }
        var bytes = Data(count: 4)
        bytes.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// 加密一帧：counter(8 BE) ‖ ciphertext‖tag。
    func encrypt(_ plaintext: Data) throws -> Data {
        let nonce = try nonce(for: sendCounter)
        let sealed = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        var frame = withUnsafeBytes(of: sendCounter.bigEndian) { Data($0) }
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        sendCounter += 1
        return frame
    }

    /// 解密一帧；计数器必须严格递增，乱序或重放一律拒绝。
    func decrypt(_ frame: Data) throws -> Data {
        guard frame.count >= 8 + 16 else {
            throw RemoteCryptoError.channel("密文帧过短")
        }
        let counter = frame.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        guard counter == recvCounter else {
            throw RemoteCryptoError.channel("加密帧顺序异常")
        }
        recvCounter += 1
        let nonce = try nonce(for: counter)
        let ciphertext = frame.dropFirst(8).dropLast(16)
        let tag = frame.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: recvKey)
        } catch {
            throw RemoteCryptoError.channel("密文校验失败")
        }
    }
}

// MARK: - 握手

/// 设备侧握手状态：先造临时密钥，收到开发机临时公钥后与配对时保存的长期公钥一起推导通道。
nonisolated final class DeviceHandshake: @unchecked Sendable {
    let staticPrivate: Data
    let staticPublic: Data
    let ephemeralPrivate: Data
    let ephemeralPublic: Data

    init(staticPrivate: Data) throws {
        guard staticPrivate.count == RemoteCryptoConstants.publicKeyLength else {
            throw RemoteCryptoError.invalidKeyLength
        }
        self.staticPrivate = staticPrivate
        self.staticPublic = try RemoteCryptoKeys.publicKey(from: staticPrivate)
        self.ephemeralPrivate = RemoteCryptoKeys.generatePrivateKey()
        self.ephemeralPublic = try RemoteCryptoKeys.publicKey(from: ephemeralPrivate)
    }

    /// 设备 → 开发机：长期公钥 ‖ 临时公钥（共 64 字节）。
    var helloPayload: Data {
        staticPublic + ephemeralPublic
    }

    /// 收到开发机 FRAME_HELLO 载荷（仅 host 临时公钥）后完成握手。
    func complete(hostStatic: Data, hostEphemeral: Data) throws -> SecureChannel {
        try RemoteCryptoKeys.validatePublic(hostStatic, label: "开发机长期公钥")
        try RemoteCryptoKeys.validatePublic(hostEphemeral, label: "开发机临时公钥")

        let ikm =
            try RemoteCryptoKeys.diffieHellman(privateKey: ephemeralPrivate, peerPublic: hostEphemeral)
            + RemoteCryptoKeys.diffieHellman(privateKey: staticPrivate, peerPublic: hostStatic)
            + RemoteCryptoKeys.diffieHellman(privateKey: ephemeralPrivate, peerPublic: hostStatic)
            + RemoteCryptoKeys.diffieHellman(privateKey: staticPrivate, peerPublic: hostEphemeral)

        let salt = ephemeralPublic + hostEphemeral
        let d2h = RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoD2H)
        let h2d = RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoH2D)

        // 设备侧：发送用 d2h，接收用 h2d
        return SecureChannel(sendKey: d2h, recvKey: h2d, peerStaticPublic: hostStatic)
    }
}

// MARK: - 推送解封

nonisolated enum RemotePushCrypto {
    /// 设备侧解封开发机推送密文（salt‖nonce‖ciphertext‖tag）。
    static func openFromHost(
        deviceStaticPrivate: Data,
        hostPublic: Data,
        sealed: Data
    ) throws -> Data {
        guard sealed.count >= 16 + 12 + 16 else {
            throw RemoteCryptoError.push("推送密文过短")
        }
        let salt = sealed.prefix(16)
        let nonceData = sealed.dropFirst(16).prefix(12)
        let ciphertextAndTag = sealed.dropFirst(28)

        let ikm = try RemoteCryptoKeys.diffieHellman(privateKey: deviceStaticPrivate, peerPublic: hostPublic)
        let keyData = RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoPush)
        let key = SymmetricKey(data: keyData)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let tag = ciphertextAndTag.suffix(16)
        let ciphertext = ciphertextAndTag.dropLast(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw RemoteCryptoError.push("推送密文校验失败")
        }
    }

    /// 与 Python `seal_for_device` 对称，供测试验证互通。
    static func sealForDevice(
        hostStaticPrivate: Data,
        devicePublic: Data,
        plaintext: Data
    ) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        var nonceBytes = Data(count: 12)
        _ = nonceBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }

        let ikm = try RemoteCryptoKeys.diffieHellman(privateKey: hostStaticPrivate, peerPublic: devicePublic)
        let keyData = RemoteHKDF.derive(ikm: ikm, salt: salt, info: RemoteCryptoConstants.infoPush)
        let key = SymmetricKey(data: keyData)
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        var output = salt
        output.append(nonceBytes)
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }
}

// MARK: - 配对码（与 Python 侧恒定时间比对逻辑一致）

nonisolated enum PairingCode {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generate(length: Int = 16) -> String {
        String((0 ..< length).map { _ in alphabet.randomElement()! })
    }

    /// 忽略大小写、空格与分隔符；空串一律判不等（与 Python `codes_equal` 一致）。
    static func codesEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(normalizedCode(a).utf8)
        let right = Array(normalizedCode(b).utf8)
        guard !left.isEmpty, !right.isEmpty, left.count == right.count else { return false }
        var result: UInt8 = 0
        for index in 0 ..< left.count {
            result |= left[index] ^ right[index]
        }
        return result == 0
    }

    private static func normalizedCode(_ value: String) -> String {
        String(value.uppercased().filter { $0.isLetter || $0.isNumber })
    }
}
