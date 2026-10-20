# Mac conversation opens blank until scrolled (2026-10-13)

## Symptom

Opening a session in the native Mac client sometimes shows an empty (white) conversation area. Any scroll, even one point, makes the messages appear. Owner report against installed Mac 0.3.87.

## Reopened: switching and zoom rendering (owner report, 2026-10-13)

The owner reports recurring blank panes and overlapping text after session switching and zoom/resize, and requests a rendering refactor. The earlier re-anchor probe is insufficient evidence of resolution. Investigate row ownership, actual glyph bounds versus allocated row frames, and layout transactions across visible/dormant pane transitions. Preserve native selection, history position, latest following, message spacing, tool/question controls and bounded history work. Do not infer correctness from any drawable glyph or a passing build. This is Corral presentation ownership, not SessKit history interpretation.

Current hypotheses (not established causes): a retained NSTextView is returned to multiple SwiftUI representable lifetimes; synchronous document restyling can precede row remeasurement; estimated lazy geometry and repeated latest anchoring may interact. Extend production-mounted regression coverage before selecting the refactor. WindowServer capture is currently rejected; native geometry evidence must remain separate from screenshot acceptance.

### Native row ownership refactor

Use a unique `NSView` mount per `NSViewRepresentable` lifetime, containing the document-owned `NSTextView`. Reattachment relinquishes the previous mount before the new mount takes ownership. Stale layout, update and teardown callbacks must not resize, restyle, detach or retire focus from the replacement row. SwiftUI owns the mount frame; only the current mount lays out its child. Keep detached TextKit measurement, the bounded document cohort and native multi-container selection. Do not add a scroll view per uncapped message or recreate the document on zoom.

Inspected reference: the existing `MacSelectableTextView` and `MacConversationTextDocument` stable-view path, plus the product's lease-based `MacPaneSurface` mounts. Reuse their text rendering, selection and lifetime protections, with row-level ownership instead of returning one pooled native view as several representables. Public APIs: [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable), `NSView.layout`, and [native multiple-text-view selection](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextUILayer/Tasks/MultipleViews.html); declarations verified in Xcode 27.2's installed macOS SDK. These APIs are available within the macOS 26 deployment target. This removes a demonstrable ownership hazard; the full symptom remains open until the strengthened layout and installed-path acceptance succeeds.

### Attributed-content invalidation

A mounted regression fails when text keeps the same characters but changes its link attributes: the standalone native text path compares only string/font size/colors and leaves the old attributes in the live storage. Updates must compare the complete immutable attributed source used for measurement and drawing. This applies to standalone tool/detail text as well as conversation rendering; native document-owned rows already update their full attributed storage. Preserve selection when its range remains valid. The iPhone has the same string-only update gate and proposal-width/final-width split in its independently implemented `UITextView` adapter; correct both copies. UIKit measurement keeps its detached native sizer and the existing half-screen cap, using the final hugging width for height. The Mac container-break correction is platform-specific. TUI uses terminal-cell layout and has neither adapter.

### Measurement parity

A detached native reproduction with a 40 pt paragraph indent measured a 220 pt proposal as 180 × 311 pt, then drew it at the returned 180 pt width with 416 pt of text. `usedRect.width` omits the origin; it is not the occupied right edge. Preserve the indent using `maxX`, then measure height at the exact returned width. In the production Markdown fixture, non-final linked containers also use an explicit newline/container break whereas detached measurement ends at the message text; this produces a repeatable 4 pt discrepancy with Markdown line spacing. Measurement must mirror that boundary rather than add arbitrary padding. Verify live per-container glyph ranges and height against the detached result.

### Live-window follow-latest investigation

Correction: the "stable empty viewport" in the four-pane 150%/120% cycle was a detector false positive. SwiftUI's own visible scroll targets were only `prompts`, and the app-rendered pane snapshot showed the complete question card; the detector counted native text views only. The inspection now treats question cards, tool summaries and the activity cue as content (`blank` requires no text row and no visible non-message target).

The strengthened inspection (SwiftUI scroll geometry and visible targets per conversation, `-CorralInspectRenderingHold`/`-CorralInspectRenderingSnapshots` app-rendered pane PNGs, and `-CorralInspectFastScroll` trackpad-phase wheel events delivered through the window at the pane centre, no pointer movement) then established three real failures of the lazy stack:

- **Latest row under the composer after zoom.** With the position bound to the latest item, SwiftUI kept that row's pre-zoom placement when it grew; repeated item requests (also with an alternated anchor) landed at the same stale place, 298 pt short of the real end (native frames 2206–2678 pt in a 2685 pt document).
- **Blank after edge positioning.** Edge requests and edge-pinned size changes during estimate churn (estimated content 1264 → 2984 → 1962 → 4800 → 4708 pt for one session) left no realized rows in the viewport.
- **Fast scrolling.** 40-step flicks moved the offset to 11322 pt in a 2026 pt document; the pane was blank until it settled (about 0.4 s).

Each scroll-request variant moved the failure between these cases. Decision: [native conversation table with exact row heights](../design/MACOS_CLIENT_DESIGN.md#native-conversation-table-with-exact-row-heights-owner-decision-2026-10-13).

## Earlier cause

`ChatScrollView` hosts a `LazyVStack`. When the loaded window is replaced wholesale while following the latest message — typically the cached tail first, then the host's newer window — the scroll offset is left where the previous window's estimated row heights put it. The lazy stack realizes no rows at that offset and does not re-evaluate until the scroll position changes, so the pane stays blank indefinitely. It is not slow rendering: no rows exist in the viewport, and drawing work is unaffected.

iPhone already re-anchors to the latest item when the measured content height changes (`onChange(of: contentHeight)` in the iOS branch); the Mac branch had no equivalent.

## Fix

The Mac branch re-anchors to the latest item whenever the measured content height changes while following the latest message and the reader is not scrolling (`showLatest()`, which still requires real overflow). History reading (`followsLatest == false`), selection and jumps are unaffected.

## Verification

- `python3 scripts/test_mac_chat_open.py` mounts the production scroll view and native text network and checks open, live append, wholesale window replacement and older-page prepend, in visible and revealed-dormant hosts at two widths. Before the fix: window replacement at 520 pt draws 0 rows in the first frame, after 0.3 s and after 1.5 s; a 1-pt scroll restores them. After the fix: every case draws the latest message from the first display frame. The probe still counts a pre-display transient state (the commit before the re-anchor), which is not a displayed frame in this harness but may cost at most one frame on screen.
- `python3 scripts/test_mac_chat_reflow.py` (zoom/width reflow, history position, selection) passes unchanged.

Limits: the probe validates native layout and row realization, not WindowServer pixels (the console was locked during this investigation). Pointer scrolling is left to the owner.

## Delivery

Mac 0.3.88 (92), built from `21a3f86`, is installed at `/Applications/Corral.app`: the executable matches the export, its signature verifies, and live diagnostics report the local connection ready with the data channel attached. Its public publication stopped at notarization stapling (`stapler` error 68, a transient CloudKit TLS failure); the fix is published with Mac 0.3.89, whose source contains it. The installed window was not visually inspected because the console was locked during delivery.

## Cross-client

- iPhone: shares the file but has its own `#if os(iOS)` re-anchor; not changed.
- TUI: no lazy conversation stack; not applicable.

<!-- 该文档整理/压缩于 2026-10-20 -->
