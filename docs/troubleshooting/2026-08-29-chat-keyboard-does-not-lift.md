# Chat keyboard occlusion, frozen input, and status-bar overshoot

## Symptoms and scope

Search terms: 键盘没有顶起输入框、输入条被挡住、键盘起来后无法键入、界面点不动、输入框飞到顶部状态栏、重构键盘输入区。

Reports: repeated occlusion, then unresponsive typing/taps, then a composer near the status bar. The current rewrite replaces keyboard avoidance, composer focus timing, and conversation position management together.

## Confirmed code defect

The removed `guideCoverHeight` accepted `CGRect.zero` as a valid keyboard guide frame: zero is neither null nor infinite. Subtracting its `minY` from the window bottom produces the full window height. Taking the maximum of that result and the notification overlap promotes invalid geometry into screen-sized bottom padding. The probe also wrote SwiftUI state during layout/update callbacks, while delayed scroll tasks could accumulate independently of view lifetime.

This proves an invalid-frame overshoot path in the implementation. It does not prove a particular internal iOS deadlock; no failing main-thread stack was captured in the original session. Do not repeat the old blanket claim that native `safeAreaInset` is broken or that all keyboard-layout-guide constraints freeze input.

## Sending is an explicit scrolling intent

A repeated local send or retry may reuse an existing local message identity. Watching only the last timeline ID therefore misses valid sends. The composer/send coordinator emits a separate scroll request after preparing a send; native scroll position consumes it. Background replies do not emit that request. Cover two sends of the same text while reading history in the runtime regression test.

## Current design

Product behavior and ownership are authoritative in [UI design: conversation input](../UI_DESIGN_KNOWLEDGE_BASE.md).

- `ChatScreen`: one native keyboard safe area, composer in the bottom inset.
- `ChatScrollView`: native scroll position and anchors; no keyboard geometry or delayed scroll retries.
- `ComposerBar`: native focus on the mounted input, no fixed navigation-delay timer. Existing text/image send rules remain.
- Remove `KeyboardLift`, its window selection/probe, merged height arithmetic, and arithmetic-only tests that merely endorsed that implementation.

Platform background and invalid-geometry guidance: [iOS layout standard](../../../../_standards/workspace-docs/swift-docs/ios-spacing-layout-tokens.md#keyboard-ownership-and-invalid-geometry).

## Verification

`ChatKeyboardLayoutTests` mounts the production chat/composer in a real application window and uses responder APIs without moving/clicking the Mac pointer. It checks visible software-keyboard geometry, text insertion, multiline growth, dismissal/reopening, history selection, and background content. Screenshots are saved as test attachments. Use the project test script with one simulator booted.

Do not label simulator checks as physical iPhone acceptance. Chinese IME candidate changes, interactive dismissal by touch, photo picking, and actual navigation taps remain separate acceptance cases. Installation and AppShelf upload are also distinct from user interaction verification.

Runtime verification on iOS 26.2 (iPhone 17) and iOS 27 (iPhone 13 Pro): the four focused tests passed on each runtime, including two keyboard/input cycles and repeated identical sends after history navigation. Screenshots confirm the composer above the keyboard. Physical iPhone interaction remains unverified while the device is unavailable.

2026-09-30 observation: on the `Corral Keyboard Test` simulator (iOS 26.2), `testShortConversationStaysAtTopOverKeyboard` fails with "Runtime layout/input did not settle" (the software keyboard never rises) on both the committed code and the working tree, even after a simulator reboot; the other 187 tests pass. Treat it as a simulator keyboard environment issue until reproduced elsewhere; it is not evidence against scroll-follow changes.

<!-- 该文档整理/压缩于 2026-09-29 -->
