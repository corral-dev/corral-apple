# Mac agent terminal width/height flips about once a second (2026-10-26)

## Symptom

A Mac pane showing an agent TUI (seen with Claude Code) alternates between filling the pane and a narrower or shorter grid. Examples: the text wraps at 40 columns in the left part of a wide pane, or the agent's input row sits well above the pane bottom and then snaps back. Only sessions created in the running Mac app since its launch show this; quitting and reopening the app makes it stop.

## Cause (confirmed)

A session created on the Mac starts under a provisional key. After its first prompt the host announces `old_key → new_key`. `MacWorkspace` carried the pane's view mode over, but `MacTerminalSessions` kept the provisional terminal alive. When the pane reopened under the canonical key, it opened a second terminal. The host still resolves the old key to the same tmux pane, so `SessionHub._terminals` held two `TerminalStream`s for one pane. Both carried the same viewer id (`remote:<device>:<connection>`). Each stream's one-second tick renewed its own stored vote into the shared `host-viewers.sqlite3` row, and the pane was resized to whichever vote was written last. A fresh snapshot followed each resize.

The stale terminal's vote came from older geometry, for example a dormant narrow split (40 columns) or the window on another display (56 rows instead of 72).

## Evidence

- In the live registry, the installed app's single viewer row for two sessions created that evening alternated `93×72 ↔ 93×56` and `93×56/93×72/40×70`. The app had one window and one connection.
- Pre-fix Debug build, disposable `corral-phone-acceptance-delivery` session through `-CorralInspectAddPaneSession` (Terminal default view): the first prompt was sent with `tmux send-keys`. About two minutes later `-CorralInspectTerminalFit` logged a second `terminal attached`. After a window resize, the tmux pane alternated `65×52 ↔ 52×40` every 1–2 s, with a snapshot on each change.
- Fixed build, same steps: one attach only. After the migration and a resize, the pane stayed at `61×49` for 12 s. The migrated terminal kept receiving output: a second prompt rendered at the bottom of the pane.

## Fix

`MacTerminalSessions.migrate(from:to:)`, called from `MacWorkspace.sessionMigrated`, keeps the same terminal object under the canonical key. Its stream keeps the old key, which the host resolves. If a terminal already exists under the new key, the provisional one closes. `TerminalEmulator` lets only a presented pane adopt the shared terminal, so a dormant pane can neither pull it back nor hide it. Requirement: [One terminal per hosted pane across key migration](../design/MACOS_CLIENT_DESIGN.md#terminals-outlive-their-panes-owner-correction-2026-10-25).

## Cross-end

The iPhone agent terminal holds one stream per view and stops it when hidden, so it has no duplicate. The TUI does not use remote terminal streams. Neither is affected.

## Not this cause

Terminal scroll lag that comes and goes while the Mac is compiling (a load average near 70) is CPU contention. Sampling the installed app found its main thread mostly idle.

## Delivery

Mac 0.3.154 (158), built from `7145134` (Developer ID Release, archive diagnostics: only the retained `ChatMarkdown` Sendable entries), is installed in `/Applications`. The binary matches the export, the signature verifies, and the single GUI process reports a ready local connection with data attached. After installation, every terminal vote from the app held steady across repeated registry samples. The new-session migration path itself was accepted on the Debug build of the same source; it was not repeated on the installed app.
