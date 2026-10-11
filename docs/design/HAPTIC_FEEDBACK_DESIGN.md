# iOS haptic feedback design

Status: user-action implementation completed, 2026-10-01. Build, delivery and physical-device evidence are recorded below; tactile feel acceptance remains pending.

Implementation contract: use one main-actor UIKit feedback service for stable synchronous dispatch across sheet dismissal and navigation, with a Foundation-only event gate for visibility and deduplication validation. Haptic feedback is built-in default behavior, with no app setting, preference storage or extra settings entry. User-action callbacks own feedback; presentation and history snapshots do not. Terminal/arrival cues remain silent because the current phone contract does not expose verified per-turn notification arbitration. This is the design's evidence-gated fallback, not an inferred terminal-state trigger.

## Requirement

Design Corral iOS haptics around meaningful actions and confirmed outcomes. Feedback should be brief, restrained and consistent across pairing, session actions, conversation input and native questions. Reading and streaming remain quiet. Every outcome remains understandable when system settings or hardware suppress haptics.

This document owns the Corral event mapping. Shared semantics and platform guidance remain in the iOS haptic design guide (maintainer reference, not distributed); existing visual and interaction contracts remain in [the UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md).

## Feedback vocabulary

| Meaning | Feel | Public API | Corral use |
|---|---|---|---|
| Selection changed | One very light tick | `UISelectionFeedbackGenerator.selectionChanged()` | A custom filter or question choice actually changes |
| Action committed | One short light tap | `UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45)` | An outgoing operation is accepted locally and its pending state appears |
| Important success | Familiar system success rhythm | `UINotificationFeedbackGenerator.notificationOccurred(.success)` | Pairing, session creation or handoff is confirmed |
| Attention needed | Familiar system warning rhythm | `UINotificationFeedbackGenerator.notificationOccurred(.warning)` | An explicit operation has an uncertain result, or a verified active task stops unexpectedly |
| Action failed | Familiar system error rhythm | `UINotificationFeedbackGenerator.notificationOccurred(.error)` | A user-initiated operation is definitively rejected |

The impact intensity is a provisional Corral tuning value, normalized rather than a physical measurement or an Apple requirement. Compare it with the existing light impact on the same iPhone before adopting it. Selection and outcome rhythms stay system-defined; do not recreate them with timed pulses, increase every error to a heavy impact, or add a brand pattern. No continuous vibration or custom Core Haptics engine is needed for this design.

## Event mapping

| Surface / event | Feedback and exact trigger | Visible feedback and silence boundary |
|---|---|---|
| Scan a pairing code | Light tap once when a valid, previously unhandled pairing link enters the pairing operation | Show pairing progress. Recognition does not mean the computer is paired. Unrelated or malformed QR codes do not vibrate |
| Complete pairing, scanned or pasted | Success once after authenticated pairing completes and the host is saved | Show/open the paired host. Paste and scan use the same outcome path. Opening the scanner, camera authorization and reconnecting an existing host are silent |
| Pairing fails | Error once for a definitively invalid/rejected pairing attempt; warning once for an uncertain network outcome | Show the reason and retry route. Repeated camera frames and automatic retries of the same failed link remain silent; an explicit retry is a new attempt |
| Change runtime/project filters or question choices | Selection once when a custom control's committed selection changes | Selected value updates visibly. Re-tapping a selected single-choice option is silent; multi-choice add/remove each counts. Native pickers, toggles and menus keep their own feedback without an extra layer |
| Pin / unpin a session | Selection once after the confirmed new pinned state is visible | Do not vibrate on the initial request or an automatic list refresh. A failed pin gets its failure outcome instead |
| Send text or images | One light tap when validation passes, the send is accepted and pending state is shown | This means the request started, not that the assistant received or finished it. One batch produces one tap regardless of image count. No second success pulse for ordinary delivery |
| Submit a native question request | One light tap when a valid submission enters its submitting state | Choice taps only select answers. Automatic question folding, typing, request arrival history and card dismissal after acknowledgement do not add a second submission pulse |
| Explicitly retry a message / question | One light tap for the accepted retry, then an outcome only if attention is needed | Keep existing command identity and draft-preservation rules. Automated retries are silent |
| Create a session or hand off to another assistant | Success once when the host confirms the resulting session and the app routes to it | Show progress while waiting. Do not add a start tap to these milestone actions. Selecting a recent combination or dismissing the creation sheet is not a success |
| Copy an entire message, prompt or session identifier through a Corral action | One light tap after the pasteboard write succeeds | Keep a visible/accessibility confirmation. Native text selection and its system Copy menu receive no extra app feedback |
| Stop a session / delete a session / remove a paired host | One light tap after the requested result is confirmed and reflected in the surface | Preserve the existing confirmation and data rules. Opening/cancelling a confirmation is silent; an intentional stop is not a warning or an assistant failure |
| Pull to refresh / load earlier | Keep native refresh feedback. If Corral owns the gesture, one light threshold tap per armed gesture, with reset only after release | No second pulse when history arrives, no vibration per scroll frame, and no gesture pulse for automatic history loading |
| Explicit action fails or remains uncertain | Error for authoritative rejection; warning for a timed-out/lost connection with unknown outcome | Show an actionable message and preserve the pending operation/draft as required. A timeout alone must not claim non-delivery. One outcome per attempt; background retry failures stay silent |
| A fresh question needs an answer in the current conversation | One light tap accompanying the newly visible question card, only under the foreground rules below | Use the request's stable identity. Multiple questions in one request produce one arrival tap. An ordinary question is not a warning |
| The current assistant turn finishes / unexpectedly stops | Success for verified completion; warning for verified interruption, once per turn, only under the foreground rules below | Completion is the assistant turn's result, not proof that its promised work passed acceptance. The final answer/status remains visible. Never infer this from a process disappearing or stream silence |

Foreground arrival/completion feedback is conditional on reliable event identity; it is not a prerequisite for the initial user-action implementation. If the phone cannot distinguish a fresh request or terminal turn from restored history, keep that event silent until the data path provides that evidence. This design does not authorize changes to SessKit or the remote protocol.

Always quiet: launch, opening/returning between pages, ordinary scrolling, search typing, keyboard focus, tab changes, opening/closing sheets, expanding activity details, streaming text, tool progress, automatic title/list updates, connection racing, background sync and reconnect snapshots. Disabled or cancelled actions do not vibrate. Attachment picking and standard long-press menus retain native behavior.

## Timing, deduplication and foreground ownership

1. Touch-down uses the existing visual pressed state. Haptics belong to a committed action, changed selection, or visible outcome. Keep state update and feedback in the same UI transaction; do not add a cosmetic delay or wait for a navigation animation to finish.
2. One semantic event has one owner. Composer feedback must not also fire in the detail controller. Pairing success belongs to the shared authenticated result, not the QR callback. A batch, request, gesture or operation is the unit, not each attachment, question, scanner frame or redraw.
3. Use an operation/attempt identity for user actions and a stable request/turn identity for unsolicited events. Render counters may deliver an already-approved event but must not decide whether it is new. Do not deduplicate by localized error text or by a single global timestamp that suppresses independent actions.
4. When one operation produces a start and outcome in the same UI update, play its outcome only. During an asynchronous send, a later warning/error is useful because it changes the visible pending state. Never play a backlog after the page disappears or the app becomes active again.
5. A starting tuning budget for incidental selection/threshold taps is at most one per 150 ms; suppress extras instead of queuing them. This is a Corral comfort budget, not an Apple requirement. It must not suppress a distinct explicit failure or change the task's visible state.
6. App-authored feedback requires an active foreground scene. Unsolicited question/turn feedback additionally requires the matching host and session detail to be visible, reading position following the latest content, and no active typing or text selection. In history-reading mode, show the existing new-content cue without vibrating. Suppressed feedback is consumed, not deferred until return.
7. Other sessions and hosts remain silent inside the app. Lock-screen/background alerts remain owned by the existing system-notification path and its preferences. A turn/request handled by that path must not also produce an app pulse for the same event; returning from a notification never replays it. See [completion notification design](https://github.com/corral-dev/corral/blob/main/docs/design/AGENT_COMPLETION_NOTIFICATIONS_DESIGN.md) for terminal evidence and notification deduplication ownership.
8. For unsolicited events that coincide, an interruption takes priority over completion, which takes priority over a question-card arrival tap. Do not stack several notification rhythms for one state change.

## Default behavior and accessibility

- User requirement: haptic feedback is a built-in default function, not an app setting. Do not add a haptic switch, extra settings entry, intensity control, setup step or per-host preference. Remove the previously added app preference and ignore any value it stored.
- Native feedback generators retain iOS and hardware behavior. Do not bypass system decisions or substitute a legacy vibration API when a request produces no haptic.
- Every action retains its visible state, readable error and accessibility description when haptics are unsupported or suppressed. Do not replace a suppressed haptic with an unsolicited sound.
- Reduce Motion preserves semantic outcomes; timing follows state changes rather than animation completion. Verify tasks with VoiceOver and the same native controls.

## Original source evidence

Inventory baseline: commit `44684f8`, inspected 2026-10-01. These are source observations, not installed-device or tactile acceptance.

| Original source | Verified observation at the baseline | Adopted integration |
|---|---|---|
| [ComposerBar.swift](../../Shared/UI/Composer/ComposerBar.swift) | `sendDraft` increments `sendPulse` after its local validation/clear and before `onSend`; the view uses light impact | Retain one start event, align it with actual accepted pending state and foreground policy, and evaluate the lower intensity |
| [SessionDetailView.swift](../../Shared/UI/Chat/SessionDetailView.swift) | `showComposerError` increments `errorPulse`; the view uses `.error` | Classify definitive versus uncertain outcomes and scope by attempt; avoid repeating a display helper's pulse |
| [PairingScannerView.swift](../../iOS/Views/Pairing/PairingScannerView.swift) | QR detection increments `scanPulse` before pairing-link validation; failure increments `errorPulse`; `pair` dismisses after success without a success trigger | Move recognition feedback after validation. Add the shared success outcome before dismissal through an owner that survives the transition. Deduplicate the same failed code across automatic retries. The UI knowledge base's pairing-success feedback is a design target, not current source acceptance |
| [AnswerOptionsView.swift](../../Shared/UI/Chat/AnswerOptionsView.swift) | `toggle` changes answer selection and may fold/open questions; `submit` forwards the complete request | Emit one selection event for a real change and one accepted-submission event from the submitting owner; do not haptically replay automatic folding |
| [NewSessionSheet.swift](../../Shared/UI/Sessions/NewSessionSheet.swift) | `createSession` obtains and decodes the host-created session, then calls `onCreated` and dismisses | Emit success through the parent/navigation owner after confirmation; failure remains in the creation surface |
| [SessionListView.swift](../../iOS/Views/Sessions/SessionListView.swift) | Pin/stop await a host call and refresh the list | Tie feedback to the confirmed visible result rather than request start or every refreshed list |

## Implemented behavior

One main-actor [UIKit feedback service](../../Shared/UI/Design/HapticFeedback.swift) owns all app-authored feedback. Its [portable policy](../../Shared/Core/Presentation/HapticFeedbackPolicy.swift) consumes foreground/visibility-suppressed events, deduplicates each operation phase, throttles incidental selections and invalidates asynchronous operations when their surface disappears. UIKit dispatch occurs before sheet dismissal or navigation; the former composer/scanner SwiftUI modifiers were removed so the two adapters cannot double-fire. Public UIKit generator scope and the installed SDK were checked against the app's iOS 17 minimum. Generator preparation is optional and never delays the outcome.

Callbacks cover accepted text/image batches and question submissions, changed question/filter choices, confirmed pairing/create/clone/handoff/pin/stop/delete/unpair outcomes, explicit failures and the custom history-pull threshold. Network uncertainty produces a warning, authoritative rejection produces an error, and cancellation stays silent. Existing native copy menus have no extra app feedback; no new pasteboard action was introduced.

There is no app-specific haptic setting or stored enablement value. User-action feedback runs by default; unsolicited question/terminal cues remain silent until event identity and notification arbitration are verified. This scope does not change SessKit or the remote protocol.

## Validation and delivery evidence

- 2026-10-01: after removing the app setting, the coordinator reran the full current portable suite: 272 tests, zero failures, including five haptic policy tests. The policy checks background/visibility suppression without replay, per-attempt phase deduplication, selection throttling, abandoned-surface invalidation and truthful error classification.
- The signed generic-device Release build for 1.0.91 (101) passed. All 224 localization key usages have English and Simplified Chinese entries. The former setting section, extra Machines toolbar entry, enablement storage and unused setting translations are absent from the current source.
- Source commit `134ba46` is published as v1.0.91. Concurrent delivery job `3b3242bb9351ae640028926d` independently verified installation and launch on the paired physical iPhone and a matching internal install-shelf package (shelf release 155). A separate live app query read back 1.0.91 (101).
- After a fresh ordinary Release launch, the coordinator inspected the phone screenshot: Machines has its existing pairing control and no extra Settings entry. The host-settings section removal is source/build verified; that sheet was not photographed. The first capture was black; the post-launch recheck showed the real Machines surface. No physical tap counts or tactile feel acceptance are claimed.

## Physical-device acceptance

The implementation's build, portable tests, installed version and screenshot inspection are separate evidence from tactile acceptance. A screenshot or a vibration-shaped animation cannot demonstrate physical haptics. The checklist below remains the tactile and live-action acceptance plan; it is not a claim that each path has been exercised.

| Real path on the existing Corral iPhone app | Acceptance |
|---|---|
| Send once, send a multi-image batch, rapidly tap disabled Send, explicitly retry | One accepted-start tap per operation; no duplicate tap or duplicate send; pending/draft behavior remains correct |
| Pair by scan and paste; hold the camera on the same failed code | Recognition differs from success, both routes share success, automatic failures do not repeatedly buzz |
| Choose/change single and multiple answers, type a note, submit all answers | Selection changes tick; typing/folding stays silent; Submit pulses once; the original live agent request actually continues |
| Create/handoff, pin/unpin, copy, stop/delete with cancellation and failure | Feedback aligns with the actual confirmed outcome; cancellation is silent; native menu/control feedback is not doubled |
| Pull and cancel below threshold, cross threshold several times, release, load history | At most one threshold tap per armed gesture; no stream/scroll/load-completion buzzing |
| Definitive rejection, uncertain network delivery, retry | Different system outcome semantics with truthful visible messages; preserved operation/draft; no false success |
| Fresh current-session question and terminal result; repeat snapshot/reconnect, other session, history reading, active typing, background/notification return | Fresh eligible events at most once; restored/suppressed events do not replay; system and app do not double-alert |
| Relaunch and switch hosts; enable VoiceOver / Reduce Motion; use system haptic preferences | Feedback remains built-in with no app switch; all tasks remain usable; no custom substitute vibration or audio |

Record the source commit, installed version, event/attempt identity, outcome and physical tap count separately from builds and test results. Compare the impact tuning with the existing app on a haptic-capable iPhone; a second supported iPhone is useful when available, but lack of one must not become a claim of cross-device tactile acceptance. Existing phone and pointer-control constraints still apply.

## Official basis

- [Apple HIG: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics): system meaning, causal consistency, short discrete feedback, optional haptics and avoiding overuse.
- [SwiftUI SensoryFeedback](https://developer.apple.com/documentation/swiftui/sensoryfeedback): public semantic feedback types. [Selection](https://developer.apple.com/documentation/swiftui/sensoryfeedback/selection) changes a value; [success](https://developer.apple.com/documentation/swiftui/sensoryfeedback/success) marks a completed task/action.
- [SwiftUI impact](https://developer.apple.com/documentation/swiftui/sensoryfeedback/impact(weight:intensity:)): physical-impact feedback supplements the visible experience; hardware/platform response can vary.
- [UIKit UIFeedbackGenerator](https://developer.apple.com/documentation/uikit/uifeedbackgenerator): system feedback-generator family for imperative integration.

These references support API scope and semantic principles. The Corral event matrix, intensity starting point, suppression budget and current-session eligibility are product design choices requiring real-device acceptance.
