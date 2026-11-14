# Mac agent TUI scrolling is not smooth (2026-11-12)

## Symptom and status

The owner reports that vertical scrolling inside a Mac agent TUI still feels
choppy after several optimization rounds, unlike the same agent in iTerm2; an
earlier Corral build felt fluid. **Status: open.** This round produced
attribution, a reusable measurement harness, and three rejected hypotheses. It
did not restore the owner's experience and ships no behavior change.

## What was measured

Environment: macOS 27.2, Xcode 27.2 beta 2, SwiftTerm 1.99.3 (exact pin), Mac
client in a Release-optimized build carrying the DEBUG inspection, Metal
renderer with the upstream render loop (`isUsingMetalRenderer == true`,
`isUsingRenderLoop == true`), real host on encrypted loopback, disposable Pi
session in its alternate screen with mouse reporting on
(`buttonEventTracking`).

Workload: 180 pixel-precise wheel events paced at 60 Hz over about three
seconds, alternating direction, with a fixed delta cycle of 3, 5, 8, 13, 21, 8,
5, 34 points. That is 134 whole lines after cell-height accumulation. Each run
also reported `TerminalView.diagnostics`, the payload-free input queue stages,
and the native `onFramePresented` completion times.

| Metric (clean runs, Release-optimized) | Observed |
|---|---|
| Queued input batches for 134 lines | 134 (no input lost) |
| Input RPC dispatches | 98–105 (batching works) |
| Rate-limit retries / dropped batches | 0 / 0 |
| Input RPC acknowledgement | median ~3 ms, p95 7–18 ms |
| Native scroll handler | median 0.04–0.07 ms, p95 < 1 ms |
| Event → changed host content | median 7–12 ms, p95 ~42 ms |
| Event → completed native frame | median 30–40 ms, p95 64–91 ms |
| Content frames per second | 24–38 |
| Frame interval | median 19–33 ms, p95 55–70 ms |

Reading: wheel delivery, request batching and VT parsing are already fast; the
remaining latency and the visible stepping sit between the host's changed
content and the completed frame, at a cadence well under the 60 Hz the display
offers.

## Rejected this round

1. **Metal is not slower than CoreGraphics.** Same binary, same workload,
   alternated order: CoreGraphics produced 19.8 and 23.8 content frames/s,
   Metal 26.5 and 34.8. Upstream `Tools/RenderBench --scenario scroll` agrees
   (Metal 187–210 MB/s against CoreGraphics 161–195 MB/s in an A-B-B-A run).
2. **The title watermark's transparent terminal background is not the cause.**
   `backgroundOpacity` 0 with the identity background against 1 with an opaque
   terminal showed no repeatable difference (33.2/26.8 against 34.8/40.9
   content frames/s; overlapping tails).
3. **iTerm2-style accelerated wheel reporting made it worse.** iTerm2's fast
   trackpad path converts `deltaY` and writes up to 32 reports from one event
   in a single write. Reproducing that only for mouse-reporting terminals raised
   delivered travel from 134 to 313 lines and host feeds to 618–694 while
   content frames/s stayed level or fell (23.8 → 24.1, and 33.2 → 27.1 in the
   paired runs). More travel per report is a speed change, not a smoothness
   fix, so the experiment was removed.

## Measurement trap

Do not diff the visible screen after every feed while timing. A first run that
read `terminalContentSnapshot(region: .viewport)` per feed to prove "the content
changed" reported an event → frame p95 of 632 ms and a maximum of 767 ms; the
same workload without that read reported 64–91 ms p95. Snapshotting per feed
perturbs the display link. Keep content verification in a separate run from
timing, exactly as the existing typing inspection already requires.

## Blocking limitation

Every automated run reported `NSApp.isActive == false` and
`window.occlusionState` without `.visible`, even after `makeKeyAndOrderFront` +
`orderFrontRegardless`. This host runs the agent session against a virtual
display, so Corral's window cannot become the active, unoccluded window.
`TerminalView.diagnostics` shows `renders / frames ≈ 0.58–0.60` in that state:
about 40% of render-loop frames never acquire a drawable and present nothing.

That ratio is consistent with WindowServer throttling drawable supply for
inactive or occluded windows, so it is **not** evidence of a Corral or SwiftTerm
defect and this round must not convert it into a fix. Any next step needs a
genuinely visible, active window: either the owner scrolls the installed client
while the agent records `TerminalView.diagnostics`, or the measuring session runs
on the display the window is actually on.

## Reproduction harness

`-CorralInspectTerminalScroll` (DEBUG only) with `CORRAL_INSPECTION_SESSION_KEY`
pointing at a disposable Pi session whose cwd contains
`corral-phone-acceptance-typing-`, and `CORRAL_INSPECTION_SCROLL_OUTPUT`
pointing at a JSON report path. Optional switches:

- `CORRAL_INSPECTION_SCROLL_RENDERER=metal|cg` selects the renderer for an A/B.
- `CORRAL_INSPECTION_SCROLL_STREAMING=1` first submits one harmless 1–400
  integer workload so the agent is producing output during the run.
- `CORRAL_INSPECTION_SCROLL_CONTENT_PROBE=1` verifies content actually changed;
  use it in a separate run, never during timing.
- `CORRAL_INSPECTION_SCROLL_BENCHMARK_VISIBILITY=1` disables SwiftTerm's public
  occlusion pause for the measurement window and restores it afterwards.

The probe delivers events straight to the terminal view's own `scrollWheel`,
never posts system events and never moves the pointer. Reports contain
payload-free timings only. Private evidence for this round:
`~/.config/corral/development/terminal-scroll-20261112/`.

## Next lever, in priority order

1. Obtain one measurement in a genuinely visible window (paragraph above); the
   drawable ratio decides whether the remaining cost is presentation or main
   thread.
2. If drawable starvation reproduces in a visible window, investigate the Metal
   surface/present path with upstream, not with a Corral-local renderer.
3. If instead the render loop draws every frame but at ~30 Hz, investigate why
   the display link and the host publish cadence interleave, keeping the
   existing 12 ms bounded coalescing.
4. Only then revisit per-event wheel semantics. iTerm2's distance handling is a
   speed policy; it did not improve cadence here.
