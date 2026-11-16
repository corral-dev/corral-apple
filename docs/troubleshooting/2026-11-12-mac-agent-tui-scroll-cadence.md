# Mac agent TUI scrolling cadence (2026-11-12; cause and repair 2026-11-14)

## Status and ownership

**Open, intermittent.** The owner reported choppy vertical agent-TUI scrolling compared with iTerm2, then reported it felt smooth again without a scrolling fix being delivered; that improvement is not an established repair. This investigation changes DEBUG diagnostics only — production scrolling, SwiftTerm 1.99.3, mouse semantics, output order and the host's 12 ms maximum batching policy are unchanged. Mac renderer behavior belongs here; a demonstrated shared transport defect would belong in Corral's host, not SessKit's history parser.

## Correct measurement boundaries

The initial report overstated what the probe established. The reusable method is owned by the [Mac probe guide](~/.config/agentsync/docs/MACOS_APP_DEVELOPMENT_GUIDE.md#debug-event-and-cadence-probes-verified-2026-11-14); these product-specific corrections supersede the earlier renderer/occlusion attribution:

- Directly calling `scrollWheel` does not establish `NSApp.currentEvent` as that wheel event: the probe could borrow an unrelated mouse event's type and discard reports or classify them as passive. DEBUG direct delivery now scopes explicit `.scrollWheel` provenance around SwiftTerm's native handler (normal delivery unchanged). Reject runs with missing queued input rather than calling unrelated agent output a scroll response.
- The mixed-delta workload generates 180 events in three seconds but only **105 cross a whole-cell threshold** (134 reported lines): effective content-change demand ≈35/s, not 60/s, so it cannot establish a 30 fps renderer ceiling. Use the separate one-cell-per-event workload for sustained 60 events/s demand.
- `onFramePresented` measures Metal command-buffer completion or the end of a CoreGraphics draw, not WindowServer scanout; cursor-only frames may count, and the first completion after the next received batch is not causally matched to a particular input or changed glyph. Existing `eventToChangedFeedMs` / `eventToChangedFrameMs` keys are compatibility labels, not stronger evidence. With `contentProbe=false`, `changedFeedCount` counts all received batches.
- `frames` counts dirty driver callbacks, not successful drawable requests. SwiftTerm's `TerminalSnapshot.refresh` returns `.frozen` during synchronized output (DEC 2026), and `TerminalRenderOwner.prepareFrame` can then return nil before reaching Metal: a `renders / frames` ratio below one is **not proof of drawable starvation**, and that ratio also reproduced in an unlocked, active, unoccluded window.
- Keep snapshot/content inspection, screenshots and sampling separate from clean timing. Per-feed viewport snapshots previously raised the next-frame p95 from roughly 90 ms to 632 ms; a sampling/capture run stalled synthetic delivery by 448 ms and triggered SwiftTerm's wheel budget (322 of 360 expected reports).

Apple documents [window occlusion](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property) and [drawable-pool waits/timeouts](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable/), not this diagnostic ratio as proof of either cause; the upstream boundaries above were inspected in the pinned source.

## Visible-window evidence

Release-optimized client with DEBUG diagnostics, native Metal render loop, real host on loopback, disposable Pi alternate-screen session, mouse reporting on (`buttonEventTracking`), OF27UT Pro at 60 Hz. No occlusion-policy override on 2026-11-14; screen-capture access true, displays active and awake, no temporary display connected. App activity is recorded separately from window visibility — some mixed-delta runs were visible but not continuously active.

| Clean workload | Queued reports | Draw completions/s | Event → next draw completion* |
|---|---:|---:|---|
| Mixed deltas, repeat A | 134 / 134 | 35.8 | median 38.9 ms, p95 92.4 ms |
| Mixed deltas, repeat B | 134 / 134 | 41.6 | median 28.0 ms, p95 64.1 ms |
| One cell/event, six seconds A | 360 / 360 | 26.4 | median 33.1 ms, p95 138.0 ms |
| One cell/event, six seconds B | 360 / 360 | 38.4 | median 17.9 ms, p95 65.5 ms |

\*Temporal proxies, not causal input-to-pixel measurements. Both one-cell runs were active and unoccluded at start and end; the probe now records activity/visibility across every delivered event. All four clean runs had zero input retries/drops at Corral's input queue; parse p95 was under 0.11 ms. These results do **not** clear the sustained-scroll acceptance target.

Fresh window captures show numbered content moving upward and returning (mixed-delta capture: first visible number 359 → 334 → 359) — fresh scrolling, not a cached locked-screen image, but no proof of physical trackpad feel or frame-by-frame smoothness. Fixture-only raw output had 106 matched synchronized-output blocks, 105 completing during the three-second scroll interval, matching the 105 effective input events; 58 of those crossed feed boundaries, with end-minus-start receipt median 0.35 ms, p95 17.74 ms, max 21.38 ms. That motivates examining transaction/feed phase alignment but does not establish a transport fix.

## Candidates not adopted

Occluded-window A/B runs did not support changing any of these:

1. Metal → CoreGraphics: CoreGraphics 19.8/23.8 versus Metal 26.5/34.8 draw completions/s; upstream `Tools/RenderBench --scenario scroll` also favored Metal (187–210 versus 161–195 MB/s). Neither is proof of the owner's gesture.
2. Title watermark transparency: opacity 0 versus 1 showed overlapping results (33.2/26.8 versus 34.8/40.9 completions/s).
3. iTerm2-style accelerated wheel reporting: travel rose from 134 to 313 lines and host feeds to 618–694 without repeatable timing improvement; changing distance is not a smoothness repair, and the experiment was removed.

References inspected: iTerm2's [`iTermScrollAccumulator.m`](https://github.com/gnachman/iTerm2/blob/master/sources/FixBrokenAppleCrap/iTermScrollAccumulator.m) and [`PTYSession.m`](https://github.com/gnachman/iTerm2/blob/master/sources/PTYSession/PTYSession.m), Pi's [`wheel-scroll.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/tui/src/wheel-scroll.ts) and [`tui-alt-screen.ts`](https://github.com/badlogic/pi-mono/blob/main/packages/tui/src/tui-alt-screen.ts), and SwiftTerm 1.99.3 `FrameDriver`, `RenderLoop`, `TerminalRenderOwner`, `TerminalSnapshot` and the public mouse API. Reuse the maintained native renderer; do not copy private mouse encoding, patch DerivedData, remove synchronized output, drop output or lower frame rate to make a benchmark pass.

## Reproduction and cleanup

`-CorralInspectTerminalScroll` is DEBUG-only. Set `CORRAL_INSPECTION_SESSION_KEY` to an owned disposable Pi session whose cwd contains `corral-phone-acceptance-typing-`, and `CORRAL_INSPECTION_SCROLL_OUTPUT` to a private JSON path. Optional switches:

- `CORRAL_INSPECTION_SCROLL_DISPLAY`: place the window on that awake display.
- `CORRAL_INSPECTION_SCROLL_RENDERER=metal|cg`: renderer comparison.
- `CORRAL_INSPECTION_SCROLL_EVERY_EVENT=1`: 360 events, one cell/event at 60 Hz (default is the 180-event mixed-delta workload).
- `CORRAL_INSPECTION_SCROLL_STREAMING=1`: submit one harmless 1–400 integer prompt.
- `CORRAL_INSPECTION_SCROLL_CONTENT_PROBE=1`: per-feed content checking; **not a clean timing run**.
- `CORRAL_INSPECTION_SCROLL_RECORD_FEEDS=1`: retain fixture-only bytes in a private sidecar after timing for offline transaction analysis (normal reports contain payload-free timings only).
- `CORRAL_INSPECTION_SCROLL_CAPTURE_MIDPOINT=1`: publish midpoint capture phase.
- `CORRAL_INSPECTION_SCROLL_BENCHMARK_VISIBILITY=1`: temporarily disable upstream visibility suspension; label such runs separately.

The probe calls the native handler without posting system input or moving the pointer; application activation uses public `NSApp.activate()` (installed SDK, macOS 14+) and does not guarantee activation — preserve actual readback. Wait for **`phase=restored`**, not merely `complete`, before terminating: terminal hooks, renderer visibility policy, workspace and original window frame are restored first, and a completion report precedes the capture hold. Preserve failed phases as failures. The final mixed run verified `phase=restored`, `windowFrameRestored=true`, 134 queued reports and visibility throughout; application activity changed during the run. A second installed GUI appearing before the next run was rejected by the launcher without starting a competing probe; that interference does not justify repeated GUI termination.

Locked sessions use the screenshot skill's bounded wake/native-display readiness procedure; locking alone never requires the owner to unlock. Inspect changing fresh pixels before claiming motion. Private artifacts and launch scripts: `~/.config/corral/development/terminal-scroll-20261112/`.

Next attribution is sustained-scroll transaction/feed/presentation alignment with comparable runtime/output and clean timing. The arrival-wakes-the-wait path is unchanged; only the size at which a burst skips the window moved.

## Cause and repair (2026-11-14)

The cause was the host publish path, not the renderer. An agent full-screen redraw arrives as ~4–7 KB, under the 8 KiB coalescing bypass, so two successive redraws merged into one publication and the first waited out the remaining 12 ms window. Replaying the recorded 60-line/s feed measured 20.8 ms p95 publish delay with 277 publications where 417 frames were available; a 2 KiB bypass measured 0.5 ms and 417. `TerminalStream._COALESCE_MAX_PENDING_BYTES` is now 2 KiB; component reasoning is in the [CLI performance KB](../https://github.com/corral-dev/corral/blob/main/docs/PERFORMANCE_KNOWLEDGE_BASE.md#the-8-kib-bypass-merged-redraws-measured-2026-11-14). No client code, SwiftTerm pin, renderer, opacity, mouse or scroll policy changed.

Alternating control/repair runs, one visible unoccluded window, one sustained one-cell-per-event workload, same host and machine:

| Run | event→frame median | p95 | renders / driver frames | content frames/s |
|---|---|---|---|---|
| control 1 (8 KiB) | 24.2 ms | 93.1 ms | 190/353 = 0.54 | ~31 |
| control 2 (8 KiB) | 29.9 ms | 113.1 ms | 177/355 = 0.50 | ~29 |
| repair 1 (2 KiB) | 16.7 ms | 62.9 ms | 285/352 = 0.81 | ~47 |
| repair 2 (2 KiB) | 14.8 ms | 48.4 ms | 301/352 = 0.86 | ~50 |

All four runs queued 360/360 reports, kept `droppedBatchCount=0`, restored the original frame and stayed visible. The display link was measured separately at the same moment: median 16.66 ms, max 17.95 ms, zero missed ticks, so optional-display starvation stays dead as an explanation. The terminal still does not reach a full 60 content frames/s; the remaining gap is the agent's own redraw throttle plus the cost of one publication, not a renderer ceiling.

While the owner reported current lag: the five retained SwiftTerm render threads were idle in their semaphores, the app main thread was idle in the event loop, and load average was 116–133 from five Pi agents, Chrome and Sidecar encoding. A saturated machine and this publish gap were both present; only the second is Corral's to fix, and both must be reported honestly.

The host path is shared with iPhone agent terminals and the desktop TUI, so they inherit the pacing change; neither was measured in this Mac-only pass. The client binary did not change, so no client release is implied.

<!-- 该文档整理/压缩于 2026-11-15 -->
