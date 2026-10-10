import Foundation
import UserNotifications

/// 推送通知服务扩展：解密封装载荷并改写标题正文。
///
/// 中继只转发密文；真实标题在本地用设备私钥 + 开发机公钥解开。
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttempt else {
            contentHandler(request.content)
            return
        }

        do {
            let payload = try decryptPayload(from: request.content.userInfo)
            if let title = payload["title"] as? String, !title.isEmpty {
                content.title = title
            }
            if let body = payload["body"] as? String, !body.isEmpty {
                content.body = body
            }
            if let key = payload["key"] as? String {
                content.userInfo["session_key"] = key
            }
            if let runtime = payload["runtime"] as? String {
                content.subtitle = runtime
            }
            // 把开发机标识留给主 App，方便快捷回复时选对连接。
            if let hostID = request.content.userInfo["host_id"] as? String {
                content.userInfo["host_id"] = hostID
            }
        } catch {
            // 解密失败时保留中继占位文案，绝不能把密文原文亮出去。
            content.body = String(localized: String.LocalizationValue("push.decrypt_failed"))
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }

    private func decryptPayload(from userInfo: [AnyHashable: Any]) throws -> [String: Any] {
        // 中继字段名是 corral（base64 密文）+ host_id（明文，仅用于取公钥）。
        guard let sealedBase64 = userInfo["corral"] as? String,
              let sealed = Data(base64Encoded: sealedBase64)
        else {
            throw RemoteCryptoError.push("缺少加密载荷")
        }

        let hostID = userInfo["host_id"] as? String ?? userInfo["host"] as? String ?? ""
        guard !hostID.isEmpty else {
            throw RemoteCryptoError.push("缺少开发机标识")
        }

        guard let deviceKey = try HostKeychain.readDevicePrivateKey() else {
            throw RemoteCryptoError.push("找不到设备私钥")
        }
        guard let hostKey = try HostKeychain.readHostPublicKey(hostID: hostID) else {
            throw RemoteCryptoError.push("找不到开发机公钥")
        }

        let plaintext = try RemotePushCrypto.openFromHost(
            deviceStaticPrivate: deviceKey,
            hostPublic: hostKey,
            sealed: sealed
        )
        let object = try JSONSerialization.jsonObject(with: plaintext)
        guard let dict = object as? [String: Any] else {
            throw RemoteCryptoError.push("推送明文格式错误")
        }
        return dict
    }
}
