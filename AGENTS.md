# Corral Apple client (public source)

iPhone + native Mac session-handoff app: scan-pair with the development machine, browse and reply to sessions, locally-decrypted push. Both ends share the code and resources under `Shared/`. The in-session terminal view on iPhone stays behind a feature flag (see constraint 9); the Mac client ships a terminal view where each pane switches between chat and the agent's native interface.

Product overview and cross-component rules live in the terminal repository: `https://github.com/corral-dev/corral` (SessKit session-semantics ownership, five-runtime allowlist, dormant compatibility). This file keeps Apple-client-only engineering rules.

## Apple documentation

Read the documents whose described content is relevant before deciding or editing.

- [Task routing](docs/AGENT_TASK_ROUTING_GUIDE.md): Detailed domain preconditions, symptom routes and exceptions.
- [Session header design](docs/design/SESSION_HEADER_DESIGN.md): read before completing the adopted conversation-header redesign.
- [Haptic feedback design](docs/design/HAPTIC_FEEDBACK_DESIGN.md): Implemented user-action and outcome feedback, quiet reading/streaming rules, foreground deduplication, default behavior without settings, evidence-gated arrival/completion cues.
- [iPad and Mac client adaptation](docs/design/MULTIPLATFORM_CLIENT_DESIGN.md): Product positioning and core selling points of the native Apple client (performance, many agents, developer-first, split panes, chat/terminal switching) and its open-source state.
- [Public client builds](docs/PUBLIC_BUILD_GUIDE.md): Public-source history, platform requirements, local signing, installation and verification limits. Read it before changing signing, bundle identifiers, the Keychain group or update configuration.
- [Privacy](PRIVACY.md): Session authorization, client caches, Keychain, encrypted transport and relay metadata.
- [Contributing](CONTRIBUTING.md): Client checks and contributor agreement; software licensing, brand policy and third-party notices.
- [Native macOS client design](docs/design/MACOS_CLIENT_DESIGN.md): Native Mac architecture, desktop behavior, terminal, direct-download/store distribution boundaries, software updates and acceptance.
- [Project terminal design](docs/design/PROJECT_TERMINAL_DESIGN.md): Host-side project shells as Mac split panes and an iPhone full-screen terminal, `shell.*` wire, latest-viewer sizing and acceptance.
- [Remote protocol](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md): Pairing, encrypted remote protocol, delivery, relay boundaries and remote acceptance.
- [`docs/EDITHERE_CLOSED_LOOP_GUIDE.md`](docs/EDITHERE_CLOSED_LOOP_GUIDE.md): EditHere-to-Corral UI annotation handoff, request handling and end-to-end acceptance.
- [`docs/UI_DESIGN_KNOWLEDGE_BASE.md`](docs/UI_DESIGN_KNOWLEDGE_BASE.md): Apple client layout, native controls, messages, composer and row contracts.
- [`docs/design/MOBILE_UI_REWORK_BRIEF.md`](docs/design/MOBILE_UI_REWORK_BRIEF.md): Mobile visual review and screen acceptance.
- [`docs/design/IOS_OPTIMIZATION_PROGRAM.md`](docs/design/IOS_OPTIMIZATION_PROGRAM.md): End-to-end client performance and read-only diagnostic entry.
- [`docs/PERFORMANCE_KNOWLEDGE_BASE.md`](docs/PERFORMANCE_KNOWLEDGE_BASE.md): Performance, caching, load, offline data and profiling.
- [`docs/troubleshooting/TROUBLESHOOTING_INDEX.md`](docs/troubleshooting/TROUBLESHOOTING_INDEX.md): Symptom-specific device, connection, conversation and rendering investigations.
- [project.yml](project.yml): Read the XcodeGen spec before changing targets, signing or extension embedding.
- [scripts/ios_sim.sh](scripts/ios_sim.sh): Simulator / device build, test, install and launch.
- [scripts/build-public-client.sh](scripts/build-public-client.sh): One-command public-source Mac build.

## Engineering notes

| Item | Convention |
|---|---|
| Minimum OS | iOS 17; Mac client macOS 26 |
| Language | Swift 6, default `MainActor`; NSE / XCTest targets explicitly `nonisolated` |
| UI state | `@Observable`; Combine `ObservableObject` is prohibited |
| Dependencies | SwiftTerm (MIT, pinned release) powers the Mac agent terminal and both clients' project terminal. Sparkle (MIT, pinned release) is linked only by the direct-download Mac target for software updates. Encryption uses CryptoKit. |
| Bundle | `com.example.corral` (same for iPhone and Mac) / NSE `com.example.corral.nse`. These are documented example identifiers: keep them unless you have a reason to change; no contributor is required to invent their own. |
| Mac signing | Local signing with the builder's own identity. The public project ships no team, no signing identity and no provisioning defaults; Xcode resolves them from the local environment. |
| Keychain group | `$(AppIdentifierPrefix)$(CORRAL_KEYCHAIN_GROUP)` in every iOS/NSE entitlement and in each Info.plist as `CorralKeychainAccessGroup`. Default group suffix `com.example.corral` comes from `Configuration/Base.xcconfig` and can be overridden locally. Swift never embeds a team prefix; a missing or unresolved group fails closed and touches nothing. |
| Mac local files | `~/.config/corral-mac/` (`AppStorageLocation`); iOS stays in Application Support, no migration |
| Git remote | `https://github.com/corral-dev/corral-apple` |

Agent development entry: `python3 scripts/client_diag.py doctor` checks local prerequisites; `status --active`, `events --run <clientRun>` and `verify` read real client evidence without UI automation or credentials. Missing/stale reports are not healthy clients. Build and delivery keep using the documented Xcode scripts; see the [diagnostic contract](docs/design/IOS_OPTIMIZATION_PROGRAM.md#agent-diagnostic-entry).

## Build and device (physical-first, simulator optional)

**Never drive the local pointer to tap the simulator or a physical device.** Startup, capturing an existing window and unit tests are allowed; bringing a window to the foreground and tapping, simulated clicks and drag gestures are prohibited. Steps needing a human tap are left to the user.

**After a user-visible change, install it on the paired iPhone.** Committing source only, running unit tests only, or installing only on the simulator does not count as done. After install, read back the market version and build number on the phone and confirm the just-built revision is active. No simulator run is ever mandatory: every acceptance below is satisfiable with a physical device, and an unsigned generic-device build (`CONFIGURATION=Release DESTINATION="generic/platform=iOS"`, no signing identity required) always proves compilation.

**If the device cannot take the install right now** (unavailable, locked, no route, off-network): do not just write "install later" and stop. Leave installation to the device owner with written steps; report the signed artifact location and the installed version separately.

```bash
# Simulator is optional (keep exactly one Booted device; two runtimes side by side wedge simctl)
SIM_NAME="iPhone 17" scripts/ios_sim.sh build
SIM_NAME="iPhone 17" scripts/ios_sim.sh test

# Paired iPhone: always go through the generic-device package, never target a phone as a direct xcodebuild destination
CONFIGURATION=Release DESTINATION="generic/platform=iOS" scripts/ios_sim.sh run
```

Targeting a phone directly with `platform=iOS,id=<UDID>` / `platform=iOS,name=<device>` can report `Timed out waiting for all destinations` and `The developer disk image could not be mounted on this device`. The root cause is usually an SDK older than the phone OS, not pairing. Background: [`docs/troubleshooting/2026-08-29-xcode26-ios27-device-install.md`](docs/troubleshooting/2026-08-29-xcode26-ios27-device-install.md).

Device signing notes:

- Push capability requires an Apple Developer membership and a dedicated profile for the app identifier; a wildcard profile is not enough.
- Build tools take signing inputs exclusively from the local environment (`BUNDLE_ID`, `DEVICE_NAME`/`DEVICE_ID`, `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID`; see `scripts/ios_sim.sh`). Never commit team IDs, key IDs, issuer IDs, signing keys, profiles or device identifiers. Keep any App Store Connect `.p8` key outside the repository.
- The simulator has no APNs; push and the notification extension must be verified on a physical device.

## Mac client build and run

```bash
xcodegen generate
xcodebuild -project Corral.xcodeproj -scheme CorralMac -configuration Debug -destination 'platform=macOS' -derivedDataPath .derivedData-mac -skipPackagePluginValidation build
open -n -g "$PWD/.derivedData-mac/Build/Products/Debug/Corral.app"
```

One-command public build: `bash scripts/build-public-client.sh mac`. It preserves complete compiler output and produces a local application without maintainer update feed, signing account or direct-download updater condition.

- SwiftTerm ships a build plugin; command-line builds must pass `-skipPackagePluginValidation` or they stall on plugin trust. If the first build reports a missing Metal toolchain, run `xcodebuild -downloadComponent MetalToolchain`.
- Design (desktop-first: TUI-style split panes and shared session groups, chat/terminal switching), per-round scope and Debug acceptance launch arguments: [Native macOS client design](docs/design/MACOS_CLIENT_DESIGN.md#desktop-first-redesign-owner-requirement-2026-10-04-round-2). Same pointer rule: open the screen with launch arguments, then verify with a window capture.

## Hard constraints (product behavior)

1. **The phone never resizes a hosted pane (never sends `screen.resize`)**: phone and desktop look at the same tmux pane; resizing would squeeze the desktop. The Mac terminal view joins sizing like a TUI window under the "widest viewer wins" rule (`terminal.*`, see the Mac design doc Terminal view rebuild).
2. Event streams must be **multicast**: session list, conversation and terminal can subscribe simultaneously; no single-consumer message stealing.
3. The push ciphertext field name is **`corral`** (base64); the plaintext development-machine identifier field is **`host_id`**, used by the notification extension to fetch the public key.
4. The notification extension compiles its own encryption and Keychain sources; it must not link the main app binary.
5. User-visible copy goes through `Shared/Resources/Localizable.xcstrings` semantic keys (en + zh-Hans, shared by both ends). **A missing key fails no build; the device shows the raw key** (seen before with menu keys). After changing user-visible copy, run `python3 scripts/check_localizations.py` (pure Python, no Xcode/simulator needed) and add keys before installing. System permission strings go through `iOS/Resources/InfoPlist.xcstrings` (en source + zh-Hans); Info.plist holds English source copy only. Remote errors without a message use `error.unknown`; do not hardcode equivalents. **Never put TUI shortcut bars in the chat input** (see the UI design knowledge base "input area").
6. Assistant colors and attention colors take the CLI as the single source; see [`docs/UI_DESIGN_KNOWLEDGE_BASE.md`](docs/UI_DESIGN_KNOWLEDGE_BASE.md).
7. **Connections must work on any network**: LAN and relay race concurrently (LAN ~2s, relay ~8s timeouts), first success wins — smart routing is "whoever is fast wins". **Do not** disable LAN on cellular/Wi-Fi heuristics (VLAN/VPN/overlay networks exist on cellular too). Candidates come from pairing `l=`, `hello.local_hints`, optional Bonjour. Reconnects and network changes must re-race; **never** wait serially or cling to the last address. Pair once. Hosts without relay/LAN addresses get them written back from `hello`. The UI must show LAN vs relay. **Installed/started, TCP up, or Connecting-turned-Failed is not connected**; the status bar must show connected and the dev machine `Currently online` ≥ 1. Handshake timeouts/cancellation must **immediately** close the socket; arbitration waits only for the first winner; losers, late winners and winners of an expired round are all closed; split the old socket before `adopt`. Contract: [remote knowledge base](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md) ("Same-machine and LAN connections never drop").
8. **Once a redraw direction is locked, change code directly**; no chained batches of mockups. Details: UI design knowledge base "redraw workflow".
9. **The iPhone in-session terminal view stays unshipped** (Mac client unaffected, it ships a terminal view): only the assistant session's own terminal page; project terminals (shells on the dev machine) are a separate shipped feature, entry rules in [project terminal design](docs/design/PROJECT_TERMINAL_DESIGN.md). The terminal page in session detail (segment switching, swipes, stream subscription) stays hidden from users; implementation may remain under `iOS/Views/Terminal/` behind the `ProductFeatures.terminalPaneEnabled` switch. **Do not** expose any terminal entry from menus, settings, gestures or empty states while the switch is off.
10. **iPhone session-list rows are fixed-height three-line rows at the normal font size** (Mac sidebar differs: fixed-height two-line desktop rows, see [Mac sidebar density redesign](docs/design/MACOS_CLIENT_DESIGN.md#sidebar-density-redesign-owner-request-2026-10-05)): one title line, one preview line, one project+time line. Title length and missing previews must not change row height, and no blank placeholder rows. The single authority is the [`docs/UI_DESIGN_KNOWLEDGE_BASE.md` row-height contract](docs/UI_DESIGN_KNOWLEDGE_BASE.md#row-height-contract).

## Directory map

| Path | Purpose |
|---|---|
| `Shared/Core/` | Both ends' pure Foundation layer (protocol, crypto, connection, storage, conversation/send/timeline logic); `Package.swift` portable tests cover only this |
| `Shared/UI/` | Shared SwiftUI interface and `AppModel`; platform differences via `#if os(...)` and `Shared/UI/Platform/` adapters |
| `Shared/Resources/` | Shared copy directory and shared color/assistant-identity assets (`SharedAssets.xcassets`) |
| `iOS/` | iPhone shell: entry, machine list, session list, QR pairing, push, project terminal, session terminal view (unshipped) |
| `macOS/` | Mac shell: main window, sidebar, inspector, pairing, settings, menu commands, `AppIcon.icon` |
| `Shared/Core/Network/RemoteClient.swift` | WebSocket, handshake, RPC, reconnect, per-channel multicast |
| `Shared/Core/Crypto/RemoteCrypto.swift` | Channel and push crypto aligned with the Python/Go sides |
| `Shared/Core/Store/HostKeychain.swift` | Non-UI Keychain adapter; access group comes from the build-expanded Info.plist value, never from hardcoded Swift |
| `iOS/Assets.xcassets` | iPhone AppIcon |
| `NotificationService/` | Push decryption rewriting title/body |
| `Tests/` | Crypto / pairing / frame-protocol unit tests |

## Mac debug process ownership

Before launching a newly built Corral Mac app for debugging or acceptance, terminate every existing Corral GUI app process, including installed Release and all DerivedData Debug copies. Match the Corral app executable path; do not terminate the CLI, remote host service or assistant sessions. Wait for the old app processes to exit before launching exactly one newest build. Verify the surviving PID, executable path, version/build and source commit before inspecting its window; stop and correct any mismatch. Coordinate the restart so concurrent tasks never launch competing app copies. At delivery, close Debug copies and leave only the latest installed Release running.

## Acceptance checklist (physical device; simulator never required)

- [ ] Unsigned generic-device build passes (compilation proof without any signing identity)
- [ ] Build, install and launch on the paired iPhone
- [ ] Pairing (QR or paste) survives restart
- [ ] **Network-change smoke**: connects within seconds off the dev-machine LAN (via relay, status bar shows relay); on-LAN racing may use LAN (status bar shows LAN); toggling airplane mode / switching networks re-selects automatically
- [ ] Session list matches the desktop side; grouping and attention dots correct (yellow/green/red, same as CLI)
- [ ] Conversation: tool summaries, question options, bottom status bar (no terminal entry, see constraint 9)
- [ ] ~~Terminal: Chinese text and colors correct, width unchanged across desktop windows~~ (feature parked; re-verify when re-enabled)
- [ ] Text and image input (**no** TUI shortcut bar); composer docks above the keyboard with the latest conversation still visible; rapid sends never duplicate; **a new session enters chat immediately with input focused, never back to the list**
- [ ] Push titles show decrypted real copy; quick reply enters the session
- [ ] Returning to foreground after a drop reconnects automatically; connection state visible at list top
- [ ] Light/dark and Chinese/English interfaces readable
