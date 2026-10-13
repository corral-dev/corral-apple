# Mac conversation opens blank until scrolled (2026-10-13)

## Symptom

Opening a session in the native Mac client sometimes shows an empty (white) conversation area. Any scroll, even one point, makes the messages appear. Owner report against installed Mac 0.3.87.

## Cause

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
