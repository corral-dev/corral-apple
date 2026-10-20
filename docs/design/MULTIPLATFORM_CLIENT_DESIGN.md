# iPad and Mac client adaptation

Status: native iPhone and Mac clients are available as a public source beta. The Mac target is native macOS SwiftUI; iPad-specific adaptation remains a separate work item.

## Product rule: every Apple client is a remote client

iPhone, iPad and Mac Corral apps are clients of a Corral host (`corral remote`). They pair with, connect to, list, read and send input to sessions that run on the host. A client never starts, hosts or resumes an agent process on its own device, even when the client device is a Mac that could run one. "New session", "fork" and "hand off" remain host requests (`session.new` / `session.copy` / `session.handoff`). A native Mac client therefore needs no local runtime adapters, tmux or SessKit; desktop agent management stays the CLI/TUI's job.

## Product positioning (owner decision 2026-10-05)

The native Apple client is to become Corral's headline product, ahead of its open-source release. Its core selling points, in priority for design trade-offs and public presentation:

1. **High performance**: native rendering and responsiveness, a visible advantage over Electron desktop agent apps.
2. **Many agents in one place**: Claude Code, Codex, OpenCode, Cursor and Pi sessions side by side (active runtime allowlist only).
3. **Built for developers**: keyboard-first, dense information, developer workflows rather than consumer chat.
4. **Split panes**: several sessions visible and operable at once.
5. **Free switching between chat mode and terminal (TUI) mode** for every session.

Features that weaken these points need an explicit owner trade-off. Public presentation follows the [presentation guide](../https://github.com/corral-dev/corral/blob/main/docs/PUBLIC_PRESENTATION_GUIDE.md). The [Apple client repository](https://github.com/corral-dev/corral-apple) now publishes a self-build beta for iPhone and Mac; public App Store and TestFlight downloads are not available.

## Route

1. **Prerequisite cleanup (no visible change).** Keep business logic out of views so a second layout or window can reuse it; split oversized files. Tracked in [Code quality baseline](#code-quality-baseline-2026-10-01).
2. **iPad.** Adopt `NavigationSplitView` (session list sidebar + conversation detail) that collapses to today's stack on iPhone. Size by available space, not device or `UIScreen`; iPadOS 26 windows resize freely and `UIRequiresFullScreen` is deprecated ([WWDC25 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/), [space over size class](https://fatbobman.com/en/posts/from-size-class-to-available-space/), [NavigationSplitView guide](https://swiftcrafted.dev/article/swiftui-navigationsplitview-complete-guide-adaptive-multi-column-navigation)). Verify on the paired physical iPad.
3. **Mac: native macOS SwiftUI target (owner requirement 2026-10-04, superseding the earlier Mac Catalyst step).** Design, reuse architecture and phases: [Native macOS client design](MACOS_CLIENT_DESIGN.md). Catalyst was chosen on the assumption of an existing iPad/UIKit app; Corral is SwiftUI-first, and Apple recommends a macOS target for SwiftUI apps ([Apple forums, 2026](https://developer.apple.com/forums/thread/811728)). The Mac does not wait for the iPad step; both reuse the same shared code.

Native macOS cost drivers: 13 files import UIKit and 32 regions are `#if os(iOS)`; the selectable chat text is a `UITextView` (needs an `NSTextView` counterpart); camera QR pairing, haptics and push registration need Mac equivalents.

## Code quality baseline (2026-10-01)

Strengths: protocol, crypto, connection, stores and send/list/timeline policies already build and test on macOS through `Package.swift` (about 255 portable tests); `@Observable` state; no third-party dependencies.

Debts that block or slow multi-layout work:

| Debt | Owner kind | State |
|---|---|---|
| Send flow (text/image/question send, receipts, failure draft restore, retry) lives in `SessionDetailView` | non-UI logic extraction | done 1.0.88: `ConversationSendCoordinator` (Foundation-only, portable, 15 tests); view 744 → 624 lines |
| `RemoteClient.swift` ~1650 lines and `RemoteModels.swift` ~1350 lines mix concerns | non-UI file split, no behavior change | done 1.0.88: 17 files, largest 433 lines; pure move verified line-by-line. Trade-off: ~30 formerly `private`/`private(set)` connection members are now internal so cross-file extensions compile; nothing outside `Corral/Network` writes them |
| `SessionListView` ~990 / `SessionDetailView` ~740 lines mix layout, calls and state | UI restructuring, primary model only | partly done 2026-10-04: list data plane (watch, rewatch, recheck, search, pin/stop/delete) moved to shared `HostSessionFeed`, used by iPhone and Mac; `SessionDetailView` is shared with per-platform chrome; iPhone notification-tap routing stays in the page |
| Long-bubble cap computed from window/`UIScreen` height | UI, primary model only | Mac done 2026-10-04 (caps against the conversation viewport via `chatViewportHeight`); iPhone keeps the owner-decided half-screen cap |
| Unmounted `SessionHeaderTitleView` / `SessionHeaderPresentation` (+ tests) | UI dead code, primary model only | pending |
| Page-level tests run only under Xcode/iOS | test strategy | open |

## Repository layout (owner decision 2026-10-05)

The Apple client repository holds the iPhone app, the Mac app, the notification extension and their shared code, so the `ios` name is misleading. Target layout:

| Before | After | Contents |
|---|---|---|
| `Corral/ios/` (remote `corral-ios`) | `Corral/apple/` (remote `corral-apple`) | All Apple clients |
| `Corral/` (iPhone shell) | `iOS/` | iPhone-only entry, pages, pairing, push registration |
| `CorralMac/` | `macOS/` | Mac-only window, sidebar, panes, terminal, settings |
| `CorralNSE/` | `NotificationService/` | Push decryption extension |
| `CorralTests/` | `Tests/` | Unit tests (Xcode and SPM) |
| `Shared/`, `Configuration/`, `scripts/`, `design/`, `docs/` | unchanged | |

- Only folders move. Xcode target and scheme names (`Corral`, `CorralMac`, `CorralNSE`, `CorralTests`), bundle identifiers, entitlements content, keychain groups and push environments stay unchanged, so installed apps, pairing data and notifications are unaffected.
- Empty legacy folders left in the iPhone shell after the move to `Shared/Core` are removed.
- The rename runs only when no other task has uncommitted edits in the repository; it must never move another task's in-flight files.
- Done 2026-10-05 (`84844f8`): Mac 0.3.14 (18) and iPhone 1.0.112 (122) built from the new layout and installed. Untracked links from the old names (`Corral/ios`, and `Corral`, `CorralMac`, `CorralNSE`, `CorralTests` inside `apple/`) are kept only so sessions started before the move keep working; delete them once no running task uses the old paths. The old remote URL `corral-ios` does not redirect.

<!-- 该文档整理/压缩于 2026-10-20 -->
