# iPhone agent terminal

Status: adopted 2026-10-14; implementation and physical acceptance pending.

## Product behavior

The owner approved restoring chat/terminal switching inside an iPhone agent session. This supersedes the 2026-09-10 hidden agent-terminal decision. The project shell remains a separate feature.

- Use the native segmented Picker for Chat / Terminal. Do not add a horizontal swipe that conflicts with terminal selection, scrolling or navigation.
- Terminal shows and controls the same hosted agent, never a second agent or a local shell. Reuse SwiftTerm 1.20.0 UIKit TerminalView, the existing iPhone shell terminal component and RemoteTerminalStream. Replace the old Canvas/screen.* mirror; do not merely enable it.
- Only a presented foreground terminal subscribes and claims the host grid. Hide or background it to stop the stream and withdraw its vote. Returning reuses the local emulator screen while a fresh ordered snapshot reconciles it. Chat keeps its reading position, draft and attachments.
- The terminal owns its keyboard and native accessory keys; the chat composer is absent in Terminal mode. Opening a session still starts in Chat. Read-only devices may view an already running agent, cannot type/resume or claim dimensions.
- Fit rows and columns to the real keyboard-adjusted viewport, respect the host agent minimum of 40 columns and 10 rows, and coalesce layout-driven resize. Use the existing latest-used-viewer policy: using the phone can narrow the shared host pane; desktop use takes it back. Never send screen.resize.
- Hosts without terminal_stream expose only Chat. Ended agents show an explicit Resume action for authorized devices; mode switching alone does not restart a process. Disconnection preserves the last screen and reconnect obtains a fresh snapshot.
- Remote terminal queries must not generate input replies, remote clipboard reads/writes are disabled, links are restricted to HTTP(S), and paste uses input.text with submit:false for host-owned bracketed paste.

## Inspected references and applicability

The existing ShellTerminalHost supplies native UIKit rendering, selection, accessory keys and theme handling. MacTerminalPane/RemoteTerminalStream supplies raw-stream lifecycle, ordered snapshot recovery and capability handling. Reuse the SwiftTerm emulator and Corral encrypted transport; do not copy the SSH example transport or the old Canvas renderer.

Official references: [SwiftTerm 1.20.0 UIKit implementation](https://github.com/migueldeicaza/SwiftTerm/blob/v1.20.0/Sources/SwiftTerm/iOS/iOSTerminalView.swift), [tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode), [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput), [UIKeyboardLayoutGuide](https://developer.apple.com/documentation/uikit/uikeyboardlayoutguide).

## Acceptance

Build iPhone and Mac configurations, portable Core tests and localization checks. On a paired physical device inspect Chat / Terminal, keyboard open/closed, Chinese composition and paste, selection during output, portrait/landscape, rapid repeated switches, background/foreground, reconnect and desktop size reclaim. Verify five supported runtimes against a real host without typing into user-owned sessions. Host tests or installation alone are not physical UI acceptance. When the phone is unavailable, deliver the signed committed build through ios-deliver/AppShelf and record the unverified device behavior.
