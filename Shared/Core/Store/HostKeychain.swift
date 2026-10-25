import Foundation
import Security

nonisolated enum HostKeychainError: Error, Sendable {
    case invalidKeyLength
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
}

/// Keychain 共享读写：设备私钥与开发机公钥，供主 App 与通知服务扩展共用。
///
/// access group 必须写死团队前缀——`$(AppIdentifierPrefix)` 只在 entitlements / Info.plist
/// 里由 Xcode 展开，Swift 源码里写这串会被当成字面量，两边永远对不上。
nonisolated enum HostKeychain {
    /// 与 entitlements 里 `$(AppIdentifierPrefix)com.x0c.corral` 展开后一致。
    static let accessGroup = "SHZQ3MWP3B.com.x0c.corral"
    static let deviceService = "sh.corral.device.identity"
    static let deviceAccount = "x25519"
    static let hostService = "sh.corral.host.public"
    static let notificationSoundService = "sh.corral.notification.sound"
    static let notificationSoundAccount = "preset"

    static func readDevicePrivateKey() throws -> Data? {
        let data = try readGeneric(service: deviceService, account: deviceAccount)
        guard data == nil || data?.count == 32 else {
            throw HostKeychainError.invalidKeyLength
        }
        return data
    }

    static func saveDevicePrivateKey(_ key: Data) throws {
        guard key.count == 32 else { throw HostKeychainError.invalidKeyLength }
        try saveGeneric(service: deviceService, account: deviceAccount, data: key)
    }

    static func saveHostPublicKey(hostID: String, publicKey: Data) throws {
        guard publicKey.count == 32 else { throw HostKeychainError.invalidKeyLength }
        try saveGeneric(service: hostService, account: hostID, data: publicKey)
    }

    static func readHostPublicKey(hostID: String) throws -> Data? {
        try readGeneric(service: hostService, account: hostID)
    }

    /// Device-local preference, not a secret: Keychain is the only store the
    /// notification extension shares with the app (no App Group).
    static func readNotificationSound() -> String? {
        (try? readGeneric(service: notificationSoundService, account: notificationSoundAccount))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    static func saveNotificationSound(_ value: String) throws {
        try saveGeneric(service: notificationSoundService, account: notificationSoundAccount, data: Data(value.utf8))
    }

    static func removeHostPublicKey(hostID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: hostService,
            kSecAttrAccount as String: hostID,
        ]
        SecItemDelete(scoped(query) as CFDictionary)
    }

    private static func readGeneric(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(scoped(query) as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw HostKeychainError.keychainReadFailed(status)
        }
        return data
    }

    private static func saveGeneric(service: String, account: String, data: Data) throws {
        let query = scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ])
        let attributes = writeAttributes(data)
        var status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw HostKeychainError.keychainWriteFailed(status)
        }
    }

    /// iOS shares items with the notification extension through the team access
    /// group. The Mac app has no extension: its items live in the login keychain,
    /// partitioned to the app's own Developer ID signature (no access group or
    /// data-protection entitlement, which would require a provisioning profile).
    private static func scoped(_ query: [String: Any]) -> [String: Any] {
        #if os(iOS)
        var query = query
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
        #else
        return query
        #endif
    }

    private static func writeAttributes(_ data: Data) -> [String: Any] {
        #if os(iOS)
        // AfterFirstUnlock：锁屏后推送扩展仍要能解开加密壳。
        return [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        #else
        // Mac has no extension, but an explicit class keeps sleep/wake and
        // locked-keychain behavior consistent with iOS instead of depending
        // on the login-keychain default.
        return [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        #endif
    }
}
