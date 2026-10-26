# Pi agent terminal jumps to the top of the conversation (2026-10-26)

## Symptom

Owner report: in the Mac client's terminal view, a Pi session sometimes jumps by
itself to the very first line of the conversation, typically after switching
sessions; on a long session the person has to scroll a long way to see the
latest output. Only Pi sessions are affected.

## Cause (verified)

Pi's main-screen TUI (`@earendil-works/pi-tui` `tui-main-screen.js`
`fullRender(true)`) redraws everything whenever the terminal width or height
changes (session switches and splits move the shared tmux grid) and whenever a
line above the viewport changes. Each redraw is
`ESC[?2026h ESC[2J ESC[H ESC[3J`, the whole transcript, `ESC[?2026l`. The host
streams the pane's raw output (tmux control mode), so the client emulator
receives that erase-scrollback (ED 3) itself. Other active runtimes use the
alternate screen or scroll regions and rarely send ED 3.

SwiftTerm 1.99.1 `cmdEraseInDisplay` case 3 trims the scrollback and clamps
`yDisp` to `max(yDisp - trimmed, 0)` but leaves its internal `userScrolling`
flag set. A reader scrolled back by even one row therefore sits at row 0, and
the re-rendered transcript is appended below without moving the viewport: the
view lands on the conversation's first line. A snapshot resync whose grid
changed while scrolled back has the same result, because the full reset (RIS)
keeps the flag and `preservingViewportDuringSnapshot` only restores an unchanged
grid. Upstream `main` is unchanged as of 2026-10-26.

Reproduced with the production `StreamTerminalView` and `TerminalHostFeed`
against the pinned SwiftTerm build: live viewer → bottom; scrolled up five rows,
then a Pi full redraw → top (`viewportRow=0`); scrolled up then back to the live
edge → bottom; scrolled up plus a resized snapshot → top; 12,000-row redraw
while scrolled → top of the retained 10,000 rows.

## Rule

Host output that erases the history under a reader (ED 3, RIS) returns the
viewport to live output, as Ghostty does when erased history leaves its viewport
pin inside the active area (`PageList.fixupViewport`). Host output never moves a
viewer who was at the live edge away from it. A snapshot that cannot restore the
reader's position (changed grid) also returns to live output; an unchanged-grid
snapshot still keeps another reader's row.

The fix lives in the shared `Shared/UI/Terminal/TerminalHostFeed.swift`, so it
covers the Mac agent and shell panes and the iPhone terminal. Snapshot callers
pass `hostGridChanged` from the grid of the previous host snapshot: the Mac
`placeTerminal` (and SwiftTerm's own bounds-driven resize on iPhone) re-wraps the
emulator before `preservingViewportDuringSnapshot` runs, so comparing emulator
dimensions saw an "unchanged" grid and restored a distance measured after that
re-wrap (real run: reader at 0.9967 → 0.544 after re-wrap → restored to 0.165 for
about 450 ms until Pi's ED 3 arrived). The TUI live pane
keeps its offset relative to the live edge (`EmbedPane.history_offset`, tmux
capture), so it never lands at the top and needs no change.

## Verification (2026-10-26)

- `scripts/test_mac_terminal_selection.py` (pinned SwiftTerm, production
  `StreamTerminalView`/`TerminalHostFeed`) adds the Pi full redraw in one chunk
  and split after ED 3, a 12,000-row live redraw, ordinary output at full
  scrollback keeping a reader's text, and resized snapshots. The redraw and
  resized-snapshot checks fail against the previous `TerminalHostFeed`.
- Real host path, Mac Debug `-CorralInspectPiRedraw` with
  `CORRAL_INSPECTION_PI_SHORT_ID` on an idle hosted Pi session (3,166 history
  rows): the reader scrolls back five rows, a claimed one-column resize makes Pi
  redraw through tmux control mode, then the original grid is claimed back.
  Previous build: position 0.997 → 0, first visible row `pi v1.4.0` (the
  session's start). Fixed build: 0.997 → 1.0 in one step for both redraws, last
  rows Pi's editor and status line.
- Pixel limit: under a locked session SwiftTerm's `FrameDriver` pauses rendering
  while the window's occlusion state is not visible, so window captures keep the
  last frame (they showed the five-row reader frame while the sidebar updated).
  Terminal position evidence above comes from the emulator viewport rows; a
  physical-window pixel check needs an unlocked session.
- Delivery: source `7792584` built from a clean clone. Mac 0.3.152 (156)
  Release, signed with the same Developer ID, is installed in `/Applications`
  (executable identical to the build) and reports a ready local connection with
  data attached. iPhone 1.0.198 (209) is on the private install shelf
  (`ios-deliver` job `eac7f1a4789fdf9797e7eaf4`); direct installation returned
  `device_unavailable`, so no phone-side check has run.
