# Public client builds

The public Apple repository is `corral-dev/corral-apple`. It contains both clients and their shared code, with a fresh current-source history. The original private repository is not its Git parent and its maintainer-only history is not distributed.

## Requirements

- Mac: macOS 26 or later, a current Xcode with the macOS 26 SDK, and XcodeGen. Homebrew can install XcodeGen. Xcode itself comes from Apple.
- iPhone: iOS 17 or later, Xcode, a paired physical device, your own development team and unique application/extension bundle identifiers. Push capabilities require an Apple Developer membership and matching APNs setup.
- Host: the Corral CLI with remote dependencies, running on the machine that owns the agent sessions. Clients do not install or launch agent runtimes locally.

## Mac

```bash
git clone https://github.com/corral-dev/corral-apple.git
cd corral-apple
bash scripts/build-public-client.sh mac
```

The build helper preserves complete compiler output and produces your own local application. The public self-build configuration omits the maintainer update feed, signing account and direct-download updater condition. Configure `CORRAL_APP_DIR` when using the installer to choose the installation directory. Do not overwrite an official `/Applications/Corral.app` as part of public-source verification.

## iPhone

Generate the project with `xcodegen generate`, open `Corral.xcodeproj`, select your own team and change all application/test/extension bundle identifiers consistently. The notification extension and main application must share the same team-prefixed Keychain group. Build for your paired physical device; no simulator is required for delivery.

Do not commit personal team IDs, provisioning profiles, API-key IDs, issuer IDs, signing keys or device identifiers. Build tools must receive them through local configuration or environment/build settings. If you use App Store Connect authentication, keep the private `.p8` key outside the repository and pass its path locally.

Self-hosted APNs must use the same app identity and environment as the client. Without APNs, opening the app still allows live communication with the host; notifications require separate configuration.

## Verification

```bash
swift test
python3 scripts/check_localizations.py
```

These checks cover portable client logic and localization. They do not establish camera permissions, real-device pairing, UI appearance or push delivery. Compile both application targets for shared-code changes and verify the affected behavior on the real target.

## Publication boundary

Public snapshots preserve SwiftUI views, client shells and visual resources byte-for-byte. Configuration, maintainer scripts and documentation are separately reviewed for personal signing information, private update/relay endpoints, local paths and private planning. The non-UI Keychain adapter reads its shared access group from a build-expanded Info.plist value in both the iPhone application and notification extension. Public signing uses the builder's own prefix and common group; it never embeds the maintainer's team identifier in Swift. The original private signing configuration and installed clients are not changed by this publication export.

The signing relationship follows Apple's [Keychain sharing documentation](https://developer.apple.com/documentation/xcode/configuring-keychain-sharing): Xcode expands `$(AppIdentifierPrefix)` in the entitlements. Use the same expanded prefix and group in each target's Info.plist; do not put an unresolved build variable in Swift code. Verify generated entitlements and property lists before signing a physical-device build.

Private tags, build caches, credentials, original Git history and private business planning do not enter the public repository.

Current-publication visual limit: the environment did not permit a fresh desktop window capture. Earlier unverified phone preview images are not presented as current application screenshots. Public-source and build verification must be reported separately from visual acceptance.
