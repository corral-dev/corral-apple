# Mac layout constraint loop

## Requirement

The prompts inspector described below was removed on 2026-10-05 in favor of the per-pane [prompts card](../design/MACOS_CLIENT_DESIGN.md#prompts-card-owner-request-2026-10-05); the navigation-detail viewport findings still apply.

The native Mac client must settle window and split-pane constraints after opening a conversation, receiving messages, resizing, and toggling the prompts inspector. Preserve the native sidebar and resizable inspector, equal panes, readable pane minima, prompt navigation and newest-prompt scrolling.

## Verified cause and remedy

On 2026-10-05, Mac 0.3.16 (20) and 0.3.17 (21) aborted or hung in native window constraint updates. Crash reports contain `NSGenericException` with excessive Update Constraints passes; samples of the installed client at 100% CPU show the main thread repeating window layout. The exception path includes `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` and `NSHostingView.SizeConstraints.update(from:)`. Real-host transport diagnostics remained ready; this was a native Mac layout problem.

The native navigation detail and inspector negotiated content-dependent fitting sizes repeatedly. Both now use their allocated viewport. The balanced navigation split has an explicit detail column minimum; the inspector is attached outside the navigation container and has explicit min/ideal/max width (240/300/420 pt) and ideal height. When the inspector is open, the window minimum is at least 1080 pt and grows by 221 pt per additional visible pane, avoiding clipped native columns. Newest-prompt scrolling runs asynchronously after list creation.

Changing only the window minimum, split style, inspector placement, text sizing/insets, text engine, composer placement, or inspector width did not fix the real resize reproduction. Their diagnostic substitutions were removed. The successful remedy preserves the existing text engine and composer.

Public API basis: [Inspectors in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10161/), [balanced navigation split](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle/balanced), [inspector column width](https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)).

The board uses its actual visible page count, not the four-pane page capacity. Native column negotiation needs the inspector-open floor to grow with each additional pane; minimum-width arithmetic must include this native fitting overhead.

## Working animation

The existing three working dots retain their color, size and rhythm, with a static reduced-motion state. Mac dots now animate only their own Core Animation layers instead of invalidating the SwiftUI window every frame. The original real working-chat baseline consumed about 18–23% CPU while otherwise idle. APIs: `CALayer`, `CAKeyframeAnimation`, `CAAnimationGroup`; [Apple rendering guidance](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency).

## Verification

A real working conversation with the inspector open completed 62 resize steps after viewport stabilization (median 76.8 ms, p95 103.1 ms). Adding the native window floor and restoring prompt auto-scroll completed 44 further steps (median 87.1 ms, p95 118.4 ms, max 133.2 ms). Idle CPU settled at 0–0.1%; a real window capture at the minimum width showed the full sidebar, latest conversation, composer and prompts, without edge clipping.

Final Mac 0.3.18 (22) checks: working-chat resize completed 44 steps (median 81.9 ms, p95 99.0 ms), followed by six inspector visibility transitions and 0.0% idle CPU. Two real ended sessions completed 20 resize steps (median 85.5 ms, p95/max 110.9 ms); native split origins remained at zero at the 1301 pt minimum. The inspected capture showed two equal panes, complete sidebar and inspector. The interaction path verified composer focus, pane selection, prompt jump and pane closure, then dissolved the temporary host group. Shared-core tests passed all 325 cases, lifecycle probes and localization checks passed, and the universal Release build was signed with Developer ID.

The active board had one real active session during acceptance. Its corrected actual-count sizing completed 44 resize steps (median 75.2 ms, p95 95.4 ms), settled at 0.0% CPU, and the inspected minimum-width capture had no clipping. Four simultaneous active sessions were unavailable and were not claimed as verified.

The faulty container is Mac-only. iPhone uses its own navigation/composer and retains its existing animation; TUI has no SwiftUI/AppKit inspector. No corresponding container implementation requires a change on those platforms. This record does not claim a fresh phone visual or TUI interaction acceptance.

## Installed verification

Mac 0.3.18 (22), source commit `5049c92` and tag `mac-v0.3.18`, was pushed and installed as the universal signed Release at `/Applications/Corral.app`. The replaced application bundle was preserved outside the repository. Signature validation and installed version readback passed.

The installed Release opened the exact reported working conversation through native accessibility row selection, without moving the pointer. Real chat, newest content, composer and three prompts were inspected in the window capture. The native inspector button completed two visibility transitions; native window sizing changed to 1320 pt and back to 1080 pt without hanging or crashing. Sequential captures showed the dots changing phase. Real transport remained ready with the conversation subscription attached; idle CPU was 0.1% (0.4% during live updates), about 95–97 MB resident memory. This verifies the installed behavior, in addition to the Debug resize/interaction probes.

The semantic action route uses Apple's [accessibility action API](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction) and selected/size attributes; it requires existing accessibility permission. It does not inject pointer events.
