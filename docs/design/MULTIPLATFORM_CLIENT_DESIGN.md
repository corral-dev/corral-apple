# iPad and Mac client adaptation

Status: native iPhone and Mac clients are available as a public source beta. The Mac target is native macOS SwiftUI. The iPad uses the iPhone target with a Mac-like split layout ([iPad layout and interaction](#ipad-layout-and-interaction-owner-request-2026-11-01)). Split panes stay Mac-only (owner decision 2026-11-01).

## Product rule: every Apple client is a remote client

iPhone, iPad and Mac Corral apps are clients of a Corral host (`corral remote`). They pair with, connect to, list, read and send input to sessions that run on the host. A client never starts, hosts or resumes an agent process on its own device, even when the client device is a Mac that could run one. "New session", "fork" and "hand off" remain host requests (`session.new` / `session.copy` / `session.handoff`). A native Mac client therefore needs no local runtime adapters, tmux or SessKit; desktop agent management stays the CLI/TUI's job.

## Product positioning (owner decision 2026-10-05)

The native Apple client is to become Corral's headline product, ahead of its open-source release. Its core selling points, in priority for design trade-offs and public presentation:

1. **High performance**: native rendering and responsiveness, a visible advantage over Electron desktop agent apps.
2. **Many agents in one place**: Claude Code, Codex, OpenCode, Cursor and Pi sessions side by side (active runtime allowlist only).
3. **Built for developers**: keyboard-first, dense information, developer workflows rather than consumer chat.
4. **Split panes**: several sessions visible and operable at once (Mac client only; the iPad shows one conversation, owner decision 2026-11-01).
5. **Free switching between chat mode and terminal (TUI) mode** for every session.

Features that weaken these points need an explicit owner trade-off. Public presentation follows the [presentation guide](../https://github.com/corral-dev/corral/blob/main/docs/PUBLIC_PRESENTATION_GUIDE.md). The [Apple client repository](https://github.com/corral-dev/corral-apple) now publishes a self-build beta for iPhone and Mac; public App Store and TestFlight downloads are not available.

## Route

1. **Prerequisite cleanup (no visible change).** Keep business logic out of views so a second layout or window can reuse it; split oversized files. Tracked in [Code quality baseline](#code-quality-baseline-2026-10-01).
2. **iPad.** Delivered as specified in [iPad layout and interaction](#ipad-layout-and-interaction-owner-request-2026-11-01). Adopt `NavigationSplitView` (session list sidebar + conversation detail) that collapses to today's stack on iPhone. Size by available space, not device or `UIScreen`; iPadOS 26 windows resize freely and `UIRequiresFullScreen` is deprecated ([WWDC25 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/), [space over size class](https://fatbobman.com/en/posts/from-size-class-to-available-space/), [NavigationSplitView guide](https://swiftcrafted.dev/article/swiftui-navigationsplitview-complete-guide-adaptive-multi-column-navigation)). Verify on the paired physical iPad.
3. **Mac: native macOS SwiftUI target (owner requirement 2026-10-04, superseding the earlier Mac Catalyst step).** Design, reuse architecture and phases: [Native macOS client design](MACOS_CLIENT_DESIGN.md). Catalyst was chosen on the assumption of an existing iPad/UIKit app; Corral is SwiftUI-first, and Apple recommends a macOS target for SwiftUI apps ([Apple forums, 2026](https://developer.apple.com/forums/thread/811728)). The Mac does not wait for the iPad step; both reuse the same shared code.

Native macOS cost drivers: 13 files import UIKit and 32 regions are `#if os(iOS)`; the selectable chat text is a `UITextView` (needs an `NSTextView` counterpart); camera QR pairing, haptics and push registration need Mac equivalents.

## iPad layout and interaction (owner request 2026-11-01)

Owner request: keep one iPhone/iPad code base, give the iPad a Mac-like layout, and apply the usual iOS-to-iPadOS interaction changes. Sources: [Elevate the design of your iPad app (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/208/), [What's new in SwiftUI (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/256/), [TN3192 UIRequiresFullScreen](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key).

Scope (delivered 2026-11-01):

| Area | Behavior |
|---|---|
| Container | (Superseded for the iPhone by [iPhone Duo and one adaptive layout](#iphone-duo-and-one-adaptive-layout-owner-decision-2026-11-01).) The iPad idiom uses a two-column `NavigationSplitView`: the sidebar holds the selected machine's session list; the detail column holds the selected conversation in its own `NavigationStack`. The iPhone keeps its `NavigationStack` (machines → sessions → conversation) unchanged. |
| Width | Columns follow available width, not device or orientation. Narrow windows, Slide Over and small Stage Manager windows collapse natively to one stack (list, then pushed conversation). Changing width never discards the selection. All four orientations; no `UIRequiresFullScreen`. One window per app (multiple scenes are not enabled). |
| Selection | Session rows bind to the split selection (`List(selection:)` with the existing `NavigationLink(value:)`), so the sidebar shows the native selected-row highlight. Every path that opened a conversation on iPhone (row tap, search result, notification tap, new session, copy/hand-off result) selects it instead; a new session still opens with the composer focused. No selection shows `mac.detail.empty.title` with a New Session action. |
| Machines | As on the Mac, the machine switcher lives in the sidebar: the sidebar title (machine name and connection route) is a menu listing paired machines (check mark on the current one) plus pairing. Switching machines clears the selection. No paired machine shows the existing full-window empty state and pairing. |
| Settings | Machine settings open as a sheet with Done (the sidebar does not push pages into the detail column). |
| Search | The session search field sits in the sidebar (`.sidebar` placement); the iPhone bottom-bar minimized search stays iPhone-only. |
| Keyboard | Menu bar commands (`.commands`, shown in the iPadOS 26+ menu bar and the ⌘-hold overlay) mirror the Mac where the action exists: New Session ⌘N, Pair a Machine ⇧⌘N, Search ⌘F, Switch Chat / Terminal ⌘E, sidebar toggle (`SidebarCommands`). Commands dim instead of disappearing. ⌘Return sends from the composer (a ⌘ chord never reaches an input method's composition, so marked Chinese text is never sent). Plain Return keeps the iPhone text behavior. Every command also stays reachable by touch. |
| Pointer | Session rows get a context menu (pin/unpin, stop, delete with confirmation), matching the Mac session menu and also serving iPhone long-press. Standard controls keep the system hover effect. |
| Drag and drop | Images dragged from another app onto the composer attach through the same encoder as the Mac (iPhone gains the same drop target). |

Out of scope (owner decision 2026-11-01): the iPad does not get Mac-style split panes (several sessions side by side in one window). The detail column always shows exactly one conversation; do not port the Mac workspace or propose iPad panes again without a new owner request. Multiple iPad windows have no decision and stay disabled until requested.

Acceptance: build for the iPhone and iPad idioms; install on the paired physical iPad and the paired iPhone; on the iPad capture landscape full screen (sidebar + conversation), the no-selection placeholder, and the machine menu; confirm the iPhone list, conversation and search are unchanged. Hardware-keyboard, pointer and drag paths need a person at the iPad; report them as unverified until exercised.

Delivered 1.0.207 (219): a full generic-device Release build has only the retained diagnostics in [compiler diagnostics](../PERFORMANCE_KNOWLEDGE_BASE.md#new-session-delivery-diagnostic-review), and the Mac target still compiles with its retained ones. Installed on the iPad Pro 12.9-inch (4th generation, iPadOS 27.2) and the paired iPhone, with the version read back from both. A physical iPad capture in landscape full screen showed the sidebar (machine header, settings, New Session, sidebar toggle, top search, filters, sections) beside a selected conversation. The owner then tested the iPad themselves and accepted it (2026-11-01). CoreDevice cannot rotate or resize this iPad ([device debugging limits](~/Codes/_standards/workspace-docs/swift-docs/ios-physical-device-debugging.md)), so the agent has no portrait or narrow-window captures; the owner's own test covered the iPad. The pairing sheet's trust line now varies by device ("this iPad").

## iPhone Duo and one adaptive layout (owner decision 2026-11-01)

Owner request: when the iPhone Duo is unfolded, show the iPad layout. Owner decision (same day, chosen over keeping the iPhone Machines page): every iOS device uses **one** adaptive `NavigationSplitView` tree, so folding is a plain resize that collapses or expands the sidebar instead of swapping view trees. This supersedes the "iPhone keeps its `NavigationStack`" row in [iPad layout and interaction](#ipad-layout-and-interaction-owner-request-2026-11-01). Sources: [Apple iPhone Duo resizing checklist](https://developer.apple.com/iphone-duo/prepare/) and the shared [iPhone Duo guide](~/Codes/_standards/workspace-docs/swift-docs/iphone-duo-adaptive.md).

| Area | Behavior |
|---|---|
| Layout choice | Never by idiom or device model. The split tree is used everywhere. A compact width (iPhone, Duo outer display, narrow iPad windows, resizable iPhone Mirroring) collapses natively to a stack: the session list, then the pushed conversation. A regular width shows the sidebar beside the conversation. |
| Continuity | Fold and unfold keep the machine, the selected conversation, its draft, scroll position and chat/terminal mode, because the same views stay mounted. A fold must not restart the conversation. The list may refresh when it becomes visible again, as it already does after a pop on iPhone. |
| iPhone entry | The app opens on the selected machine's session list (the Machines page appears only with no paired machine). Switching machines and pairing use the title menu. Machine settings open as a sheet with Done, which survives a fold. |
| Search | Compact width keeps the iPhone's bottom minimized search. Side by side, the field sits fixed under the sidebar's title bar (`navigationBarDrawer(displayMode: .always)`); `.sidebar` placement let iOS 27.1 float it as a pill across both columns of an unfolded Duo (owner report 2026-11-01). The choice follows the current size class. |
| Bars | Every screen keeps horizontal bars: `toolbarVerticalBehavior(.disabled)` on both split columns (owner reports 2026-11-01). On the Duo outer display the iOS 27.1 vertical bar spanned the status column, leaving a blank column beside a shortened composer and Send out of a right thumb's reach. Apple documents bottom-heavy screens as an opt-out case. Opting out on the conversation alone was tried and rejected: pushing from the list (vertical bar) animated through a broken state, with "⋯" parked under the composer and no Back for about half a second (owner screenshot and simulator recording). One axis everywhere also keeps controls in one place across screens. |
| Search placement | The compact/regular decision is read outside the split columns: a sidebar column always reports a compact width, which once put the iPhone's floating bottom search between the two columns of an unfolded Duo. |
| Shortcuts | The system Find group is removed at launch (`UIMainMenuSystem.Configuration.findingPreference = .removed`, iOS 26+). Its ⌘F / ⌘E otherwise conflicted with Search and Switch Chat / Terminal (`_UIMenuBuilderError`). Replacing SwiftUI's `.textEditing` group does not remove it. |
| Geometry | No launch-time or `UIScreen.main` geometry; long-bubble caps and image scale read the live window scene. iOS 27.1 vertical bars stay system-owned (standard toolbars only). |
| Not adopted | Hinge (`onHingeChange`) and arrangement/reserved-region APIs: Corral has no physical-hinge interaction or two-semantic-pane layout across the fold. Multiple windows stay disabled. |

Acceptance: the Duo simulator outer display (folded) and inner display (unfolded) on the iOS 27.1 runtime, each fold direction with a conversation open (state carried over, no new `session.watch` for the open conversation in the host's recent actions), plus the the paired iPhone and iPad installs. Folding in the simulator is a Device Hub UI control with no command-line equivalent, so the owner performs each fold; the agent captures both displays with `simctl io <device> screenshot --display=<1 outer | 3 inner>`.

Delivered 1.0.208 (220), 2026-11-01. The full generic-device Release build has only the retained diagnostics, and the Mac target compiles with its retained ones. Installed on the paired iPhone and the iPad, with versions read back.
- **Duo simulator (iOS 27.1, Debug):** captures show the unfolded split (sidebar with its top search field, selected-row highlight, conversation), the folded conversation (horizontal bars, full-width composer) and the folded session list (vertical bar with settings, New Session and search).
- **Continuity:** during the owner's unfold (18:08:52) and fold (≈18:09:08–13), the host received only `sessions.watch` / `sessions.unwatch` from the Duo, with no new `session.watch` for the open conversation.
- **Physical devices:** the iPhone opened directly on the session list with the machine menu title, and the iPad kept its sidebar and conversation.
- **Not verified:** hardware-keyboard, pointer and drop paths on device, a physical Duo, and Duo inner portrait.

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
