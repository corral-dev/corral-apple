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

Network retries (2026-10-13, Mac 0.3.89/0.3.90): stapling failed with `stapler` error 68 (CloudKit TLS `-1200` on the direct path; the router sends Apple domains direct and `stapler` ignores proxy variables), and a GitHub ZIP upload through the local proxy was reset mid-body. The publisher's `run_network` now retries staple/validate, public pushes, uploads and the latest flag up to six times with 20/40/60/80/100-second waits; commands that honor proxy variables alternate between the local proxy and the router's path, and upload retries replace a partial asset with `--clobber`. Each attempt keeps its own numbered log. Evidence: the stalled 0.3.89 publication resumed from a script-only delivery commit (`7dc6bec` on its pinned clone, accepted by the delivery-file rule) and completed: ZIP, DMG and appcast uploaded, the anonymous feed reports 0.3.89 and the Homebrew Cask moved to 0.3.89. General mechanism: shared distribution guide (maintainer reference, not distributed). Regressions: `scripts/test_mac_release.py` (`test_stapler_retries_*`, `test_upload_retry_alternates_*`, `test_network_retry_budget_is_bounded`).

Pinned-clone pushes (observed 2026-10-12, Mac 0.3.82): publication pushes the clone's `main` together with the tag. If other agents advance the private `main` after the clone was made, that push is rejected (`fetch first`) after the tag lands. Fetch in the clone, keep `HEAD` detached at the release commit, point only `main` at `origin/main` (`git branch -f main origin/main`), and resume with `--publish-prepared`; the receipt keeps `sourceCommit` separate from `deliveryCommit`. Check `HEAD` after any fetch: the local Git wrapper fast-forwarded the detached clone to `origin/main` during that fetch. Environment improvement (not implemented): push only the tag plus a fast-forward check instead of the clone's `main`.

Public source export details that are easy to miss:

- The sanitized public `project.yml` is a complete replacement file kept with the private export recipe, so its iPhone and Mac version lines do not follow the private file. It stayed at Mac 0.3.70 through the 0.3.71 and 0.3.73 releases. Update its four version values in every release. Environment improvement (not implemented): derive them from the private `project.yml` during export.
- The export privacy preflight rejects any recipe private value that survives a document's own replacements. A private install-shelf address written into the Mac design document blocked the 0.3.74 export; refer to it as "the private install shelf" in exported documents.

## Publication privacy verification

Prepared release recovery (2026-10-12): a pinned checkout must not try to push an older `main` over newer concurrent commits when the prepared source is already published. Fetch remote `main` and verify that it contains the exact prepared `sourceCommit`; in that case push only the immutable release tag. If that source is not yet remote, require local `main` to contain it before pushing the branch and tag normally. Never force a branch/tag, discard concurrent commits, or treat an unpublished source as delivered. Mac 0.3.82 encountered this after documentation and another task advanced remote `main`; Git ancestry distinguishes successful source publication from an actual missing source.

The fresh public history excludes private signing identifiers, maintainer service endpoints, private planning and original private Git history. A whole-tree credential scan found no secrets. Exact leak-gate fingerprints cover only individually reviewed synthetic LAN fixtures, protocol-format examples, documentation paths/anchors and shell expressions. No file-wide or credential-rule exemption was added. Recheck changed findings before extending the list.

## Homebrew distribution

Owner requirement (2026-10-12): the native Mac client supports Homebrew installation and updates through `x0c/tap/corral-mac`, separate from the `x0c/tap/corral` host CLI. Reuse the existing official universal Developer ID-signed, notarized DMG. Pin its release version and SHA-256; keep macOS 26 as the minimum. Retain Sparkle updates and declare `auto_updates true`. Every successful official Mac publication must synchronize the Cask only after anonymous artifact verification, reject rollback and refuse a changed checksum for an already published version.

First installation uses `brew install --cask x0c/tap/corral-mac`. If the official DMG app is already installed but not registered with Homebrew, use `brew install --cask --adopt x0c/tap/corral-mac`. Once registered, updates use `brew update` followed by `brew upgrade --cask x0c/tap/corral-mac`. Custom application locations need the same `--appdir` during registration. Quit Corral before deliberately replacing an older DMG installation with `brew install --cask --force x0c/tap/corral-mac`; do not do this when the actual app is newer than the tap version, and never combine `--adopt` with `--force`.

Corral's built-in updater remains enabled. On current Homebrew, this versioned single-app Cask's `auto_updates true` supports reading the real bundle version; a newer app can coexist with an older Homebrew installation record. That difference alone is not a failure. Older Homebrew versions and unreadable/other artifact schemes may behave differently; the general mechanism and diagnostic limits belong to the shared macOS distribution guide (maintainer reference, not distributed). Public guidance uses the [Homebrew FAQ](https://docs.brew.sh/FAQ#how-does-brew-upgrade-handle-apps-that-update-themselves) and [manual](https://docs.brew.sh/Manpage#install-options-formulacask-).

Existing-App incident (2026-10-12): the owner supplied an installation log for Cask 0.3.79 ending in `It seems there is already an App at '/Applications/Corral.app'`. Subsequent read-only inspection found the actual app at 0.3.80 (84), Homebrew registration/Cask at 0.3.79 and `outdated: false`. This establishes readable newer-bundle handling in the current installation. It does not prove Sparkle performed that replacement, identify the original argv or explain why that earlier operation entered installation. Preserve this as an unresolved historical operation until the exact command and matching registration state are known; do not prescribe a forced 0.3.79 installation over 0.3.80.


The Cask installs only `Corral.app`; it must not remove `~/.config/corral-mac/`, preferences or Keychain entries during installation, upgrades or uninstall, and has no `zap` stanza. Keep bundle/signing identity unchanged so existing pairing and preferences remain usable. Source builds remain a separate route.

References: [Homebrew install/adopt/force](https://docs.brew.sh/Manpage#install-options-formulacask-), [self-updating Casks](https://docs.brew.sh/FAQ#how-does-brew-upgrade-handle-apps-that-update-themselves), and the inspected [Ghostty Cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/g/ghostty.rb) for signed DMG, native app artifact, Sparkle livecheck and `auto_updates`. Reuse those declarations; omit its completions, manpages and data-removing `zap` because Corral does not require them.

Homebrew acceptance (2026-10-12): the real Cask adopted an existing official 0.3.78 (82) bundle, upgraded it to 0.3.79 (83), and force-replaced a separate older DMG installation with 0.3.79. The temporary application directories were uninstalled through Homebrew. The installed `/Applications/Corral.app` was then adopted as 0.3.79 (83); its executable hash stayed unchanged, the notarization ticket validated, all 108 pre-existing client data files remained, and the relaunched installed client recovered its paired local connection with the data channel attached. Homebrew reports the correct application target and `outdated: false`. Final Cask style and online audit pass, including DMG SHA-256 and Sparkle livecheck. Seventeen maintainer release regressions pass on the system Python and Python 3.13/3.14; the Homebrew channel itself changes no Swift source or application build input, so it reuses the existing reproducible official release. Receipts and full operation logs are in `~/.config/corral/development/homebrew-mac-20261012/`.

Environment diagnostic assessment:

- The shared tap's generated `agentsync.rb` emits a `postflight` deprecation notice on this Homebrew version. Corral's Cask has no such hook; its installation succeeds. Follow-up belongs to AgentSync's GoReleaser source before Homebrew removes that API, outside this client task.
- Untrusted unrelated taps are ignored by Homebrew. The fully qualified Corral installation trusts only this Cask, as documented in [Tap Trust](https://docs.brew.sh/Tap-Trust). No unrelated tap trust was changed.
- The same-DMG mount contention, beta `hdiutil` deprecation and Gatekeeper override interpretation are maintained in the shared distribution acceptance pitfalls (maintainer reference, not distributed). Local evidence: concurrent 0.3.78 audit/install failed with `Resource busy`; serial installation passed. The intermediate 0.3.78 audit rejected its version against the 0.3.79 feed, while final 0.3.79 audit passed. `spctl` reported `override=security disabled`; signatures and stapled tickets passed independently, without claiming enforcement on another Mac or changing security settings.

## Official Mac updates

The official Developer ID-signed Mac download is available in [Mac releases](https://github.com/corral-dev/corral-apple/releases/latest). It checks hourly by default, automatically downloads signed updates and installs at quit; Check for Updates offers immediate installation and relaunch. Update preferences live in Settings. Self-builds retain the builder's own identity and do not opt into replacement by official binaries.

## Generated signing configuration

Public exports replace the private Keychain access-group literal with an adapter that reads the build-expanded `CorralKeychainAccessGroup` property. Both the app and notification extension must declare that property through `project.yml`, using `$(AppIdentifierPrefix)$(CORRAL_KEYCHAIN_GROUP)`, and declare the same group in their entitlements. Verify both generated property lists and the built entitlements after XcodeGen; private-source literal behavior does not describe the sanitized public adapter.

A public-source merge may advance `main` after preparation while retaining exactly the same full Git tree. Resume may push that descendant main, but the release tag and assets remain bound to the original prepared public commit. Verify both ancestry and full tree identity; any changed file still invalidates the prepared public identity. Never rewrite a published tag or retarget prepared application bytes to resolve publication contention.
