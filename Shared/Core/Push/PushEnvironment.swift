import Foundation

/// APNs environment derived from the actual code signature, never from build configuration.
///
/// The `aps-environment` entitlement is set by Xcode from the app's provisioning
/// profile, which routinely disagrees with the build configuration (a Release build
/// signed with a development profile carries `development`). Reporting the wrong
/// environment in `push.register` makes the provider target the wrong APNs endpoint
/// and the notification is silently lost, so an unknown value maps to `nil` and the
/// caller must skip the upload instead of guessing.
enum PushEnvironment: String, Sendable {
    case sandbox
    case production

    /// Maps a raw `aps-environment` entitlement value to the `push.register` wire value.
    /// `development` -> `sandbox`, `production` -> `production`; anything else -> `nil`.
    nonisolated static func fromApsEnvironment(_ rawValue: String?) -> PushEnvironment? {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development":
            return .sandbox
        case "production":
            return .production
        default:
            return nil
        }
    }

    /// Extracts the plist dictionary from a `.mobileprovision` (CMS-wrapped) blob.
    /// Returns `nil` when the blob has no plist section or the plist does not parse.
    nonisolated static func provisioningPlist(fromMobileProvision data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        let openTag = Array("<plist".utf8)
        let closeTag = Array("</plist>".utf8)
        guard let openRange = bytes.firstRange(of: openTag),
              let closeRange = bytes.firstRange(of: closeTag, startingAt: openRange.upperBound),
              closeRange.upperBound <= bytes.count else { return nil }
        let plistData = Data(bytes[openRange.lowerBound..<closeRange.upperBound])
        return (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
    }

    /// Reads the raw `aps-environment` value from a `.mobileprovision` blob.
    nonisolated static func apsEnvironmentValue(fromMobileProvision data: Data) -> String? {
        guard let plist = provisioningPlist(fromMobileProvision: data),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else { return nil }
        return value
    }

    /// Environment of the currently running app, from its own signed provisioning profile.
    /// `nil` (no profile, e.g. TestFlight/App Store packaging without one, or an
    /// unrecognized value) means the caller must skip `push.register`, not guess.
    nonisolated static func current(bundle: Bundle = .main) -> PushEnvironment? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return fromApsEnvironment(apsEnvironmentValue(fromMobileProvision: data))
    }
}

private extension Array where Element == UInt8 {
    nonisolated func firstRange(of needle: [UInt8], startingAt start: Int = 0) -> Range<Int>? {
        guard !needle.isEmpty, start < count else { return nil }
        var i = start
        while i + needle.count <= count {
            if self[i..<(i + needle.count)].elementsEqual(needle) {
                return i..<(i + needle.count)
            }
            i += 1
        }
        return nil
    }
}
