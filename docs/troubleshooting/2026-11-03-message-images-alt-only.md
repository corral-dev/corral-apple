# Message images show only their alt text

## Status and ownership

Confirmed source-level initialization defect, investigated 2026-11-03. The owner
subsequently requested a root fix with regression protection and a Mac release.
The initialization repair and native regression tests pass; delivery and physical
screen acceptance are recorded separately below.

Corral's Apple detail initialization owns this defect, not SessKit, image
creation or Markdown syntax. The owner capture shows a Claude assistant reply
with image labels (comparison, A1, A2, A3) but no images or loading placeholders.

## Initial investigation evidence

- The matching native Claude assistant record contains five ordinary Markdown
  image declarations, with absolute local PNG paths. Its body is 1,453 UTF-8
  bytes, below the Markdown parser's 16 KiB bound. All five files exist.
- The installed CLI source's `SessionHub.message_page` preserves that exact
  body at seq 49. An isolated hub, with the real native history and a temporary
  derived-cache directory, successfully returns all five images through
  `SessionHub.image_preview` at 640 px / quality 60. Returned previews are
  14,363, 12,562, 18,109, 12,129 and 78,128 bytes; the first four are JPEG and
  the last is PNG. This is local host-function verification, not a probe of the
  running daemon or the relay.
- The installed Foundation parser extracts all five `imageURL` runs from that
  exact body. Each URL's `absoluteString` retains the original path, and the
  run text is its alt label. This excludes malformed Markdown and URL encoding
  as causes for these particular references.
- `SessionDetailView.init` seeds `conversationStore` from `injectedStore` but
  leaves `imageLoader` nil. `prepareConversationIfNeeded` immediately returns
  when `conversationStore` already exists, before its injected-store branch
  can create `ChatImageLoader` or restore the draft.
- The iOS `SessionSplitView` supplies an injected store from its selected
  `ConversationPresentation`. The Mac's `MacPaneView` also injects its pane
  store. Both therefore take the early-return path. The iOS selection-owned
  lifecycle repair made this existing shared-detail defect reachable through
  ordinary mobile navigation; it is not evidence that the previous missing-
  history incident had the same root cause.
- `conversationContent` passes the nil image loader to `ChatView`.
  `MessageBubbleView` then falls back to `ChatMarkdown.attributed` and its image
  preparation call is a nil optional call. Consequently it never constructs
  inline image attachments or requests previews; the alt labels remain.

Apple documents [`imageURL`](https://developer.apple.com/documentation/foundation/nsattributedstring/key/imageurl)
as the URL attribute for a Markdown image. That attribute is not itself the
`NSTextAttachment` inserted by Corral's image loader. The investigation checked
Apple's documentation and the installed Foundation behavior separately.

## Initial investigation scope

- iPhone/iPad: the production selected-conversation path has the confirmed
  initialization defect and matches the owner capture. the paired iPhone was
  unavailable to CoreDevice; no fresh phone-rendering check was performed.
- Mac: normal chat panes use the same injected-store detail path, so they have
  the same source-level defect. No GUI process was restarted or inspected.
  Direct `ChatView` media inspection bypasses `SessionDetailView`; its earlier
  successful screenshots do not test this initialization path.
- TUI: does not use the Apple detail, image loader or attachment renderer.
  This specific defect does not apply; native terminal image support is a
  separate runtime capability, not established by this investigation.
- The production daemon/relay was not queried: the saved diagnostic key is no
  longer paired. No new pairing was created and existing pairings were left
  unchanged. Do not claim the current live image transport passed.

## Root-fix contract and inspected reference

Reuse the existing `SessionDetailView` draft restoration, `ChatImageLoader` and
`ChatImageAttachment` implementation, with the native hosting-test pattern from
`Tests/MessageBubbleLayoutTests.swift`. Keep public SwiftUI `@State` and native
text attachments; no replacement renderer, controls or navigation are introduced.
This is an internal initialization-order repair, not a change to framework/API
semantics. Initialize the detail's local collaborators independently of whether
its conversation store was injected or created locally. Preserve the container's
ownership of loading, watch/unwatch and store lifetime; do not create a second
store or restart history subscriptions to obtain an image loader. Retain
host/session/client isolation, draft restoration and cache behavior.

A regression must mount the real `SessionDetailView` with an injected store,
not only parse Markdown or mount `ChatView` with a manually supplied loader.
Verify inline attachments and host preview loading, then inspect the same
message in installed iPhone/iPad and Mac clients. Also cover draft restoration
and client replacement because the early return skips those collaborators.
Do not patch SessKit, rewrite the assistant's references, or weaken the host's
message-reference containment check.

## Implemented repair and verification

The detail prepares its image loader and draft before the existing-store return.
The unreachable duplicate injected-store setup is removed. Existing stores remain
container-owned; repeated preparation neither reloads the draft over current input
nor replaces the loader/store. No native-history parser, host or navigation
behavior changes.

`MessageBubbleLayoutTests` mounts the production `SessionDetailView` with an
injected store, without supplying an image-loader environment. Five cached image
previews must become five non-placeholder native attachments, the saved draft
must appear, and an edited draft must survive repeated preparation. A second
mounted test replaces the detail identity and verifies that old attachments and
drafts do not leak into the new session. The fixture isolates hosts/drafts on
disk and restores its in-memory host list; it does not alter user pairings.
The full 22-case native Markdown/bubble/detail suite passes on the Duo simulator.
The 483-case portable Core suite also passes, including selection/client replacement
and watch ownership regressions. These checks do not establish physical-device
screen acceptance or the production host's live image transport.

The replacement fixture originally kept a `NavigationStack` as the unchanged
hosting root, which retained its previous root content despite replacing the
nested detail. The final fixture mounts and replaces the detail itself using its
production store-identity boundary, and waits for the new native content rather
than a fixed animation delay. Both old-content and wrong-draft assertions remain.
This fixture result is not attributed to a product navigation regression.

Complete logs remain under the agent-workflow checkout receipts. Existing native
Markdown, serial camera-queue and no-AppIntents tool diagnostics retain their
individual assessments in the [performance guide](../PERFORMANCE_KNOWLEDGE_BASE.md#new-session-delivery-diagnostic-review).
Changed production and test sources emit no new compiler warning. The iPad's
fresh pre-delivery capture shows the lock screen, and the paired iPhone fails its
CoreDevice usage assertion; neither provides changed-screen evidence yet.

## Structural-newline duplicate images

The first fresh Mac main-window capture after restoring the loader showed the
real Finder preview twice. Compiling production `ChatMarkdown` against the
reported body confirms ten `imageURL` runs for five declarations: each label is
followed by a synthetic newline that inherited the same image attribute.
This is a second rendering defect previously hidden by the nil loader.

The reusable mutation/attribute boundary and regression requirements are recorded
in the [Swift standard](~/Codes/_standards/swift.md#structural-separators-must-not-become-media-references).
Corral inserts explicit unstyled separators instead of inheriting image attributes.
The native Mac text-network probe now verifies five declarations produce five
image runs, two intentional references to the same URL stay two images, and a
whitespace alt label is retained. Its existing 560 paragraph/list width/font
transitions also pass. The nine-case iOS Markdown suite adds the same count and
separator assertions. Re-running the exact reported body against the corrected
production Markdown source returns five image runs, not ten.

## Delivery

Repair `f29be8d` is shipped from release commit `47b177c`, with durable release
receipt `20261103-171823`.

- **Mac 0.3.162 (167):** universal Developer ID Release, notarized app and DMG,
  published [download](https://github.com/corral-dev/corral-apple/releases/tag/mac-v0.3.162)
  and signed Sparkle feed. The installed executable matches the preparation
  receipt and its active client reports ready local control/data. Independent
  downloads of the 16,851,767-byte DMG and appcast match GitHub's SHA-256 digests;
  the newest feed item is 0.3.162 with the signed update ZIP.
- **iPhone/iPad 1.0.212 (224):** signature/profile validation and AppShelf upload
  succeeded (release 427, delivery job `33ba111706fe82fac50df64a`). The actual
  signed app was also installed on the paired iPad; CoreDevice independently
  reads back version/build 1.0.212/224. Direct iPhone installation failed because
  the device is unavailable. [Safari installation](the private install shelf)
  remains available after passkey sign-in. No iPhone installation is claimed.
- Full release Debug/static-analysis, universal Mac Release and generic iOS
  Release logs were inspected. Only the individually assessed native Markdown,
  serial camera and no-AppIntents/build-tool diagnostics remain; no new warning
  was introduced by these fixes.

### Remaining visual acceptance and diagnostic improvement

The fresh installed Mac capture shows a connected session list with no selected
conversation, not the affected image message. The earlier Debug main-window
capture demonstrated the initialization repair and exposed the second duplicate-
image defect; the subsequent exact-body run-count regression verifies the latter
mechanism, not a fresh installed-message visual pass.

A later same-source Debug media probe connected to the real host and loaded nine
referenced previews, but selected seq 352, a newer bare-path message, and reported
zero inline attachments. Its `last referenced message` heuristic is not a valid
selector for the original Markdown-image report. This failed acceptance assertion
is not reported as a product pass. Improvement item: select an explicitly named
message containing explicit image declarations and mount `SessionDetailView`,
rather than a bare-mention `ChatView` fixture. The installed Release was restored
and is the sole running Corral GUI process after the probe.

Fresh iPad captures show its lock screen; iPhone capture fails with CoreDevice
4016. Physical iPhone/iPad image appearance and the installed Mac message remain
unverified. No pointer, unlock, virtual display or user-history mutation was used;
the task-booted simulator is shut down. These limits do not negate publication or
installation evidence, but must not be described as completed screen acceptance.

The current presentation requirement remains [Inline cited images](../UI_DESIGN_KNOWLEDGE_BASE.md#inline-cited-images-owner-correction-2026-10-27).
The separate history-lifecycle investigation is [iPhone detail loses history](2026-11-02-claude-detail-empty.md).
