# iPhone detail loses history or assistant messages despite a valid preview

## Status

Lifecycle repair delivered in iPhone/iPad 1.0.210 (222), 2026-11-02; physical
screen acceptance remains open. The owner reported both a Claude empty detail
and the current Pi conversation showing only phone-sent user bubbles. Evidence
narrows investigation to the client's detail loading/application path, but does
not establish the exact native trigger or prove both reports share one cause.

## Symptom and ownership

The iPhone session list shows the latest Claude reply, but opening that same
session shows the completed empty state, not a loading spinner or a tool-only
activity group. The report was captured on Corral 1.0.209 (221); the host was
Corral 0.24.357 with SessKit 0.2.21.

SessKit owns native history decoding. Corral owns remote projection and client
lifecycle/presentation. Do not patch SessKit or delete history merely because
the detail is empty: this incident's source, remote projection and production
Swift message decoder all retain the missing text.

## Verified evidence

- Installed CLI `show` returns 105 user/assistant text messages. This is a
  text-only view, not the count of remote cards with tools.
- The source JSONL is approximately 36 MB. A cold `RichReader.read_all(limit=80)`
  returns 80 cards: 76 assistant, 4 user, 24 with nonempty text.
- The active daemon's persisted transcript contains 420 cards, ending with the
  same latest reply visible in the list.
- A temporary read-only paired client queried the **running daemon over the
  encrypted relay**, not a replacement service. `sessions.watch` returns the
  affected row. Both `session.watch` and `session.messages` return the same
  80-card tail, seq 341–420, including 24 text-bearing cards. Watch took about
  163 ms; messages took about 153 ms. The temporary pairing was revoked and
  the original set of paired device IDs was preserved.
- The returned watch payload decoded through the actual production
  `RemoteJSONDecoder` and `RichMessage` Swift sources yields all 80 messages,
  including all 24 text-bearing cards. No compiler diagnostics were emitted.
  This is a macOS command-line decoder check, not phone screen acceptance.
- Read-only extraction of the phone's diagnostic container shows ready LAN
  control and an attached data plane around the report. The retained current
  run has 33 `orphanResponse` events, usually in groups of three after detail
  navigation. It has no `responseRejected` event. These diagnostic events
  contain no request method, request ID or session key, so they cannot alone
  prove that a specific discarded response is the affected `session.watch`, or
  distinguish cancellation from timeout/teardown.
- The phone's `conversation-tails` directory contains no files. The Mac has a
  nonempty cached tail for this conversation (400 cards, 146 with text), but
  its fresh rendered detail was not inspected. The local CLI reads the text;
  the TUI's rendered conversation was not inspected either.

## Leading hypothesis, not an established cause

Detail lifecycle cancellation or stale client binding is the leading candidate.
Before the selection-owned repair, an iOS detail owning its store started
`loadRuntimes`, `markRead` and `ConversationStore.start` as three child operations
of its view task. Disappearance scheduled `ConversationStore.stop`, which clears
loading; an existing detail did not rebind its store on client-instance changes.
`RemoteClient.callRaw` removes a pending request on caller cancellation; a later
reply can therefore be reported as `orphanResponse`.

The list has its own summary feed, and phone-submitted user bubbles are drawn
optimistically before canonical history arrives. A healthy preview plus visible
local sends is compatible with a missing initial detail load or assistant
subscription; it does not prove the assistant's history was lost.

That path can explain the combination of a completed empty state, no persisted
phone tail and groups of discarded replies. The recent adaptive
`SessionSplitView` navigation changes are relevant to inspect, but the captured
logs do **not** establish which appearance/disappearance or cancellation caused
this report. Do not call this a confirmed split-view regression yet.

The earlier view-task/data-plane incident
has a different verified boundary: this phone's data plane is attached. Its fix
must not be applied blindly. The [tool-only tail explanation](2026-10-25-chat-shows-activity-only.md)
also does not fit: this tail contains text.

## Repair contract and inspected reference

Corral's selected iOS conversation must retain history loading and assistant
updates across native detail relocation, without changing navigation, adding
controls/retries or introducing parser fallbacks. Preserve existing cached-tail,
draft, question and generation policies. The reusable ownership, replacement and
unsubscribe-ordering rules are maintained in the [shared client/backend guide](~/Codes/_standards/workspace-docs/swift-docs/client-backend-integration.md#long-lived-subscriptions-and-logical-selection).

Inspected implementation reference: `macOS/Panes/MacPaneSurface.swift`,
`MacPaneLifetime`'s explicit presentation ownership and serialized suspension.
Adapt only that lifecycle pattern for the iOS selected-conversation owner; keep
Mac pane retention and terminal sizing unchanged. Continue using public
`NavigationSplitView`, `NavigationStack`, `List(selection:)`, `@State` and
Observation. Apple's [task lifetime contract](https://developer.apple.com/documentation/swiftui/view/task(name:priority:file:line:_:))
confirms cancellation when a view disappears or changes identity; its declaration
was checked in the installed Xcode 27.2 SDK. This establishes API semantics, not
proof of the precise transition in the report.

## Implemented repair and verification

`SessionSplitView` now owns one selected `ConversationPresentation` and injects
its store into the existing detail view. Initial watch runs in the selection's
owned task, not a render task. Transient detail disappearance cannot stop it.
Deselection/client replacement serializes the previous unwatch before another
watch; a new client replaces the store and its detail identity even for the same
session key. Folding with unchanged ownership retains the existing store. The
Mac already uses its separate `MacPaneLifetime`; this does not change Mac pane
or TUI behavior. Native parsing and the host service are unchanged.

Five portable regressions cover rendering-task cancellation with an initial
assistant snapshot and a later assistant event, same-selection reuse, same-key
return before old unwatch finishes, client replacement and session isolation.
The complete Core suite passes 479 tests in Debug and in an optimized run with
existing DEBUG-only transport fixtures enabled. That optimized fixture run is
not a pure production-Release runtime test; the signed generic-device Release
build is checked separately. The unused Void binding in an existing observation
test was removed without weakening its assertions. Xcode-extracted
string-valued count keys gained English/Chinese translations alongside the
existing numeric variants; the localization checker passes all 582 usages.
Existing native Markdown, camera-queue and metadata-tool diagnostics retain the
individual assessments in the [performance knowledge base](../PERFORMANCE_KNOWLEDGE_BASE.md#new-session-delivery-diagnostic-review).

Simulator functional checks used the existing paired Duo simulator, without
pointer/gesture automation. The affected Pi conversation renders assistant
history and a later live commentary in the repaired app. **The committed 221
baseline also loaded it successfully on a fresh launch**, so these frames prove
working app paths, not reproduction of the phone's original transition or a
causal before/after fix. Both physical devices required a passcode during these
checks, and fresh CoreDevice captures were black. Physical Claude/Pi acceptance
remains open, not replaced by simulator screenshots or successful installation.

## Delivery and remaining acceptance

- Signed 1.0.210 (222), source `8a996fd`, was installed on both the paired iPhone and
  the paired iPad, with independent CoreDevice version/build readback. The
  iPhone delivery receipt confirms `installed_and_uploaded`, but explicitly
  reports launch as unverified.
- [AppShelf](the private install shelf) accepted release 409. Its availability
  is a package handoff, not evidence that either affected phone detail rendered.
- A final encrypted-relay check opened one actual detail for each of Claude,
  Codex, OpenCode, Cursor and Pi. All returned messages and assistant text; the
  affected Claude/Pi tails each returned 80 cards. Temporary read-only pairings
  were revoked and the original device-ID set was preserved. This is host-path
  sampling, not a physical client-screen pass.
- Final simulator frames were inspected for both affected conversations,
  including live Pi commentary. The task-booted simulator was shut down.
- A clean committed Developer ID Mac 0.3.160 (165) archive/export was prepared
  from the same source, but this task did not install, notarize or publish it.
  On resumption, the installed executable matched the later shown-pane-focus
  delivery (`8643c70`, hash prefix `c5f3e6c9`), which descends from `8a996fd`.
  Preserve that newer installation instead of overwriting it with the older
  `mac-prepared/` export. The installed process reported ready local control and
  attached data; this is not a rendered comparison of the affected conversation.
  Mac/TUI screen acceptance remains unverified; neither uses the iOS lifecycle
  owner.

The owning [release runbook](../https://github.com/corral-dev/corral/blob/main/docs/RELEASE_RUNBOOK.md#when-a-phase-fails)
records the separate delivery-log failure and receipt-preserving recovery. Do not
attribute that maintainer-tool error to the conversation defect.

## Remaining diagnostic improvement

Correlate one affected detail open across view/store instance, session key,
lifecycle revision, snapshot request and RPC outcome. Extend bounded local
diagnostics to distinguish request cancellation, response decoding, stale-result
rejection and snapshot application, including message/text counts but **never
message bodies, tokens or attachment paths**. Current orphan events omit that
correlation, so correct existing documentation cannot resolve this gap alone.
This is an investigation backlog item, not authorization for unrelated logging
or navigation redesign.

Then verify list → same detail → text visible on the physical iPhone, and compare
the corresponding native Mac and TUI surfaces. The user's failure screenshot
remains open evidence; healthy host responses and the decoder probe are not a
fix or visual acceptance. Private payloads and copied phone diagnostics remain
outside Git under `~/.config/corral/development/claude-empty-20261102/`.
