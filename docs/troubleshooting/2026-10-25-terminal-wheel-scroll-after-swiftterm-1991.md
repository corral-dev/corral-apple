# Terminal pane stops scrolling after the SwiftTerm 1.99.1 migration (2026-10-25)

## Symptom

The owner reports that the agent terminal pane in the Mac client can no longer
scroll up or down, on a machine already running the SwiftTerm 1.99.1 build. The
symptom appeared with the migration commit (`d78fad9`, installed as Mac 0.3.149
build 153) and is reported against a Debug build of the same tree.

## Status

Unresolved. Do not claim a fix until the wheel gesture is accepted on the actual
window; no pointer automation is allowed for that check.

## What changed

The migration moved terminal input to the public `TerminalViewDelegate` and made
`StreamTerminalView.send(source:data:)` discard parser-generated replies because
tmux already answered them (`macOS/Terminal/StreamTerminalView.swift`). Wheel and
mouse reporting now follow SwiftTerm 1.99's native encoding and the
`TerminalViewDelegate` path in `TerminalHostView.send`.

## Hypothesis (not confirmed)

SwiftTerm 1.99 handles the wheel natively as mouse input when the hosted TUI has
enabled mouse reporting, so the gesture is forwarded to the agent instead of
scrolling Corral's own 10,000-row mirror scrollback. That is plausible for
OpenCode/Claude TUIs that enable mouse tracking, and matches "nothing moves"
when the TUI does not implement wheel scrolling itself.

## Options on the table

1. Force the wheel to scroll the local mirror scrollback (ignore mouse-mode
   forwarding for the mirrored pane) and verify native scrollback, selection and
   prompt navigation on one window.
2. Roll the pin back to SwiftTerm 1.20 and rebuild, restoring the previous wheel
   behavior while dropping the 1.99.1 render-loop gains.

Choose one before editing; two sessions were touching this file on 2026-10-25.
Keep the host's 12 ms frame coalescing either way (see the performance KB; the
50 ms experiment was reverted).
