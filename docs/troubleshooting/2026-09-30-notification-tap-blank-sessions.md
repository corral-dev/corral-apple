# Blank "No sessions" after a notification tap (2026-09-30; corrected 20:20)

## Symptoms / triggers

Notifications arrive, but tapping one lands on a blank "No sessions" screen;
tapping a new session's notification shows an empty page; tapping a notification
for a deleted session gets stuck on blank.

## Decision (read this first)

- A tap has two legs: the host leg (`CorralApp` swaps the root `NavigationStack`
  to the tapped paired host) and the session leg (that host's `SessionListView`
  opens the `session_key` detail).
- The session leg must **never** push a route for a key missing from the snapshot:
  the old logic consumed the ticket and pushed anyway, the detail found nothing,
  and the consumed ticket blocked all later recovery. That was the blank screen.
- **Correction: `sessions.list/watch` is a window (`has_more`), never an
  authoritative catalog.** No list response — bounded, `unchanged`, or stale — may
  declare the target gone. An unknown key is resolved with a direct `session.get`
  lookup once the host is connected: found → merge into the store (keep the tapped
  key as an alias when the server returns a canonical key) → open the exact session.
  Only the server's explicit `not_found` consumes the ticket, and then with a
  visible dismissible "session is no longer in the list" recovery. Transport
  failures keep the ticket retryable. One lookup per ticket; superseded or
  wrong-host results are dropped without consuming or opening stale targets.
- **Cold launch:** the delegate is assigned before finish-launching, so a tap can
  arrive before the model attaches. The request is stored unconditionally; paired-host
  validation and the connection kick are deferred until `configure()` replays them,
  and the root calls the routing on appear — a pre-appearance tap cannot be lost.
  Unpaired hosts stay stored-but-harmless: no navigation, no synthesized input.
- **Pending display:** while a tap waits with an empty list, the list shows loading
  when the host is connected (lookup in flight), and connection/retry recovery when
  offline or after a transient failure. A pending-tap error on a non-empty list gets
  a Retry action that preserves the exact pending host/session/ticket and rechecks
  client ownership. The silent empty screen never renders for a pending tap.
- Search filters cannot cause a miss (`session(for:)` reads unfiltered records), and
  neither can collapsed sections. Key-identity questions are answered server-side
  (`require_session` alias resolution), never guessed on the phone.

## Implementation

- `SessionListView.openPendingNotificationSession` + `lookupNotificationSessionIfNeeded`
  (client/host/ticket rechecked after every await), `SessionListPlaceholder` policy
  (exact rendering logic, portable-tested), `SessionListStore` read/merge/alias only.
- `PushRegistrar`: store-before-model, `kickPendingHostConnection()` replay on
  `configure()`; `CorralApp.init` delegate assignment + explicit routing on appear.
- Pure portable policy in `NotificationReply` (`resolveTap`, `shouldStartLookup`,
  `classifyLookupError`, `routablePendingHost`) — the exact logic the view/registrar use.
- Regression: portable `NotificationTapRoutingTests` (window misses, `unchanged`,
  canonical alias, explicit `not_found`, error-then-recovery, supersede, wrong host,
  pre-model retention, replay dedupe, unpaired host, placeholder matrix).

## Dormant sessions are unroutable (2026-10-01)

A tap naming a dormant runtime (no phone entrypoint per the root runtime policy)
never pushes a detail, even when the key sits in an old snapshot or the server
still returns it from a direct `session.get`:

- `SessionListStore` never stores dormant records (`merge` covers live list,
  cache load, search hits, single patches, watched events; `session(for:)`
  rechecks through aliases), so `resolveTap(found:)` answers `.wait` for them.
- When the direct lookup returns a dormant summary, `SessionListView` consumes
  the ticket into the existing dismissible "no longer in the list" recovery
  (`sessions.notification_missing.title`) instead of merging or pushing.
  No new copy was added; transport-error retry semantics are unchanged.
- Regression: `SessionListStoreTests` dormant list/cache/search/event/patch/
  alias/waiting-count cases + `NewSessionOptionsTests` dormant-catalog and
  visibility-matrix cases (five actives, case-insensitivity, unknown/nil
  fallback stay visible).

## Verification

- Portable suite green; localization check green; Release generic build green.
  No on-device tap proof in this session (device limits in the report).

<!-- 该文档整理/压缩于 2026-10-20 -->
