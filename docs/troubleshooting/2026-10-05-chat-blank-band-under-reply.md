# Blank band under a reply in the Mac conversation (2026-10-05)

## Symptom

Owner screenshots, Mac client in split panes:

- 12:53: after opening a long ended conversation, the latest reply is followed by a blank band above the composer, with the jump-to-latest button showing.
- 17:12: a blank band sits between the end of a long reply and the next user prompt in the middle of the timeline.

Session data had nothing in the band: the reply was the last content item, followed only by a non-displayed turn-duration record.

## Cause (Mac bubble text)

Bubble text was drawn by a TextKit 2 `NSTextView` (`NSTextView(usingTextLayoutManager: true)`) inside a non-scrolling `NSScrollView`, which sits inside the conversation's SwiftUI scroll view. Its frame came from `NSAttributedString.boundingRect`. Two faults leave the frame taller than the drawn text:

1. **TextKit 2 lays out and draws only its own viewport.** In a standalone harness with the same nesting, the viewport stayed at the region first visible (0–300 pt) after the outer scroll view moved to the bottom of the reply, so revealed lines are not laid out. Upstream reports: [Apple forum 817471](https://developer.apple.com/forums/thread/817471), [CodeEditSourceEditor #131](https://github.com/CodeEditApp/CodeEditSourceEditor/issues/131) (STTextView returns full bounds as its viewport because fragments outside it lay out incorrectly), [Neon #20](https://github.com/ChimeHQ/Neon/issues/20) (forcing TextKit 1 fixes it), [WWDC21 Meet TextKit 2](https://developer.apple.com/videos/play/wwdc2021/10061/) (noncontiguous layout, viewport only).
2. **Measurement and drawing used different engines.** Across the owner's two real replies at widths of 260–760 pt and text sizes of 14–16.8 pt, `boundingRect` was up to 60 pt taller than the TextKit 2 layout (never shorter).

Unverified: why the jump-to-latest button showed without user scrolling in the 12:53 capture. Opening a single pane and three-pane split with the same session, as well as a programmatic window-width sweep, landed on the true bottom.

## Fix

The Mac bubble text (`Shared/UI/Chat/SelectableAttributedText.swift`, macOS branch) uses one hand-built TextKit 1 stack (`NSTextStorage` → `NSLayoutManager` → `NSTextContainer`, padding 0, retained by the coordinator) for the live view. Measurement uses a detached stack with the same settings (`usedRect(for:)`). TextKit 1 lays out contiguously, so the whole frame is drawn. Frame, measured height and drawn height were identical in the harness at every width.

## Verification

- Shipped in Mac 0.3.16 (`221aaa0`, `mac-v0.3.16`); later installed builds carry it.
- 22:41–22:51, Debug build of the committed source against the live host, opening both affected sessions in their four-pane split (inspection launch only, no pointer): five launches. In four, window captures showed every pane resting on its latest line with no band under any reply. Scroll logs from a separate diagnostic copy showed every pane 0–1 pt from the bottom with only idle scroll phases.
- Open observation (not reproduced): on the first launch of a freshly built binary, two of four panes stopped short of the bottom. Their last lines sat under the composer and no blank band appeared; the jump-to-latest button was not visible above the composer. This was not reproduced in the next four launches, including one fresh rebuild. No change was made for it. If it is seen again, capture `scrolldiag`-style geometry: content height, inset and visible bottom per pane, plus scroll phases.

## Not the cause

- iPhone: `UITextView` frames come from the live view's own `sizeThatFits` (also capped at half the screen with inner scrolling). `testBubbleFrameMatchesTextLayoutForMarkdownReplies` confirms frame and drawn text match within 2 pt at widths of 240–420 pt.
- Scroll anchoring: simulator regressions `testLongMixedTranscriptOpensOnTrueBottom`, `testAsyncLongTranscriptOpensOnTrueBottom` and `testLongTranscriptStaysOnTrueBottomAcrossWidthChange` land on the true bottom; `ChatScrollView` was left unchanged.
- TUI: no nested text view; not affected.

## Do not

- Do not switch the Mac bubble back to TextKit 2 or to `boundingRect` sizing.
- Do not paper over the band with extra scroll-to-bottom retries.
- Do not force a full `ensureLayout` on every `layout()`; that was a diagnostic and costs a full relayout per pass.

<!-- 该文档整理/压缩于 2026-10-20 -->
