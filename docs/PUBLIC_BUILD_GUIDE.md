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

Current-publication visual evidence: after console unlock, the installed Mac 0.3.70 main window was captured and inspected, with the local connection ready. Conversation, split-motion and phone acceptance are separate checks. Earlier unverified phone preview images are not presented as current application screenshots.

Anonymous release verification must retry an interrupted response body within the existing three-attempt GET budget and reject partial bytes. Python's [`IncompleteRead`](https://docs.python.org/3.14/library/http.client.html#http.client.IncompleteRead) is an `HTTPException`, so catching URL/connection errors alone misses this failure. Keep SHA-256 verification, immutable asset checks and accepted notarization identities; a failed verification must not recreate or overwrite an already published artifact. The bounded retry is a delivery reliability fix, not evidence of application performance.

Interrupted publication resumes idempotently through `--publish-prepared`: already-pushed refs, digest-identical assets and verified steps are skipped or re-checked, so broken-pipe uploads and feed-propagation delays (`Published feed differs from the signed artifact`, wait and resume) do not restart the pipeline. A clone pinned at the release commit isolates the delivery from working-copy churn, but its `origin` must be reset to the maintainer remote before pushing. In the shared multi-agent workspace this is required, not optional: publication re-checks that the working copy is clean when it reaches the publish phase, after notarization. On 2026-10-11 a run launched with `--repo .` on the live checkout stopped there because edits landed mid-run, and another agent's commit could equally change what the live checkout holds. Either publish from the pinned clone or leave the live checkout untouched until the run completes. Resuming with `--publish-prepared` accepts later commits only to delivery scripts, tests, docs and boards. Tag pushes fingerprint leak-gate findings per scan; reviewed example addresses go into `.leakignore` as `fp:` entries (or a path `rule:` for fixtures) and ride the export recipe's `replacement_file` so re-exports keep them — verify with a `--dry-run` push before resuming.

Public source export details that are easy to miss:

- The sanitized public `project.yml` is a complete replacement file kept with the private export recipe, so its iPhone and Mac version lines do not follow the private file. It stayed at Mac 0.3.70 through the 0.3.71 and 0.3.73 releases. Update its four version values in every release. Environment improvement (not implemented): derive them from the private `project.yml` during export.
- The export privacy preflight rejects any recipe private value that survives a document's own replacements. A private install-shelf address written into the Mac design document blocked the 0.3.74 export; refer to it as "the private install shelf" in exported documents.

## Publication privacy verification

The fresh public history excludes private signing identifiers, maintainer service endpoints, private planning and original private Git history. A whole-tree credential scan found no secrets. Exact leak-gate fingerprints cover only individually reviewed synthetic LAN fixtures, protocol-format examples, documentation paths/anchors and shell expressions. No file-wide or credential-rule exemption was added. Recheck changed findings before extending the list.

## Homebrew distribution

Owner requirement (2026-10-12): the native Mac client supports Homebrew installation and updates through `x0c/tap/corral-mac`, separate from the `x0c/tap/corral` host CLI. Reuse the existing official universal Developer ID-signed, notarized DMG. Pin its release version and SHA-256; keep macOS 26 as the minimum. Retain Sparkle updates and declare `auto_updates true`. Every successful official Mac publication must synchronize the Cask only after anonymous artifact verification, reject rollback and refuse a changed checksum for an already published version.

Install with `brew install --cask x0c/tap/corral-mac`. Existing official DMG installations can be registered with `--adopt`; Homebrew's self-updating-app handling keeps the existing bundle. To explicitly replace an older DMG installation with the tap version, quit Corral and use `brew install --cask --force x0c/tap/corral-mac`. Verify the tap version before forced replacement to avoid downgrading a newer installed app. Do not combine `--adopt` and `--force`. Then run `brew update` and `brew upgrade --cask x0c/tap/corral-mac` for updates. Custom application locations need the same `--appdir` during registration.

Maintainers can bootstrap or retry Cask publication independently with `python3 scripts/publish-mac-release.py --sync-homebrew-release mac-v<version>`. This checks the stable release metadata and anonymously downloads the immutable DMG before publishing. Normal Mac publication calls the same compare-and-swap path and records `homebrewCask` in its terminal receipt; an unchanged publication is a no-op. Credentials stay in the existing authenticated GitHub CLI.

The Cask installs only `Corral.app`; it must not remove `~/.config/corral-mac/`, preferences or Keychain entries during installation, upgrades or uninstall, and has no `zap` stanza. Keep bundle/signing identity unchanged so existing pairing and preferences remain usable. Source builds remain a separate route.

References: [Homebrew install/adopt/force](https://docs.brew.sh/Manpage#install-options-formulacask-), [self-updating Casks](https://docs.brew.sh/FAQ#how-does-brew-upgrade-handle-apps-that-update-themselves), and the inspected [Ghostty Cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/g/ghostty.rb) for signed DMG, native app artifact, Sparkle livecheck and `auto_updates`. Reuse those declarations; omit its completions, manpages and data-removing `zap` because Corral does not require them.

## Official Mac updates

The official Developer ID-signed Mac download is available in [Mac releases](https://github.com/corral-dev/corral-apple/releases/latest). It checks hourly by default, automatically downloads signed updates and installs at quit; Check for Updates offers immediate installation and relaunch. Update preferences live in Settings. Self-builds retain the builder's own identity and do not opt into replacement by official binaries.

## Generated signing configuration

XcodeGen generates the iPhone and notification-extension property lists from `project.yml`. Both `info.properties` mappings must declare `CorralKeychainAccessGroup: $(AppIdentifierPrefix)$(CORRAL_KEYCHAIN_GROUP)`. Keeping that key only in a pre-generated plist loses it during regeneration; the Keychain adapter then correctly refuses to access any group. Verify both generated property lists after running XcodeGen, and compare the built values with the matching entitlements before device signing.
