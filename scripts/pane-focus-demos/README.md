# Split focus study

Owner request (2026-10-16): the current 2-point green header rule is difficult to notice on a large screen. Explore and screenshot native standalone demos, choose a visually restrained treatment, and preserve Corral's aesthetic. This is a fixture experiment, not authorization to replace the production interface.

Owner correction: keep the composer neutral regardless of focus. The follow-up redesign concerns the per-session pane header only. The previous header-plus-colored-composer recommendation is rejected. The owner also requests boldly larger session titles to create contrast; the title must dominate project metadata and controls. Compare 18-point titles in B/C with the 13-point baseline in A.

Compare identical conversation content and native controls across three header candidates:

- A: the existing accent rule, as a baseline.
- B: a compact 54-point header with title and project stacked, plus a grouped native action area.
- C: a 62-point header with a dedicated title row and a separate project/action row.

B/C use the same sage focus surface so their information hierarchy can be compared fairly. Every composer has the same neutral surface, text and send treatment.

Keep neighbouring conversation text fully readable. No focus outlines, glowing effects, saturated content backgrounds or new production states. Check two and four panes in light and dark appearance, including long titles and mixed chat/terminal fixtures. Distinguish programmatic focus/action verification from physical input, and native view exports from WindowServer screenshots.

Reuse the native `NSSplitView`, window toolbar, segmented controls and fixture-only boundary from [the toolbar demos](../toolbar-demos/README.md). Reuse existing assistant images rather than inventing icons. The production reference is `macOS/Panes/MacPaneView.swift` (`MacPaneHeader`): 2-point accent rule, secondary inactive title and retained native view picker. VS Code's [active/inactive group tab surfaces](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/media/multieditortabscontrol.css) inform the surface distinction; its CSS and application shell are not copied. AppKit's public [split view](https://developer.apple.com/documentation/appkit/nssplitview) and [segmented control](https://developer.apple.com/documentation/appkit/nssegmentedcontrol) APIs are present in the installed macOS 27.2 SDK and support the macOS 26 target.

The app uses local fixture sessions only: no networking, host connection, preferences, shell execution or real session mutation. Its bundle identifier is separate from Corral. Build output belongs under `~/.config/corral/design-previews/pane-focus/`, not in the source tree.

## Build and use

```sh
python3 scripts/pane-focus-demos/build.py --export
open ~/.config/corral/design-previews/pane-focus/Corral\ Focus\ Study.app
```

The default build exports its sources and existing runtime PNGs from committed HEAD, records that revision in the bundle, compiles with Swift 6 for macOS 26, signs locally, and creates `Corral-Focus-Study.zip`. It does not install over Corral. `--working-copy` supports iteration and deliberately omits the handoff ZIP. The app targets this Apple Silicon Mac; it is an internal local demo, not a notarized public client release.

The window toolbar changes A/B/C, two/four panes and light/dark appearance. Clicking a pane changes the selected pane; the native Chat/Terminal switch changes its local fixture. Send appends text locally. Prompts, host actions, attachment and close-pane controls are disabled context fixtures. Switching the experiment configuration resets the fixture, so no real content can be lost.

`--export` opens a background native window, exercises the real control target/actions, renders 20 scenarios and exits. It writes seven action results to `native-action-receipt.json` and 20 focus/layout states to `native-state-receipt.json`. Export waits one short main-run-loop interval after each rebuild so AppKit can finish text-view layout before caching the native content; synchronous repeated exports produced stale text overlapping adjacent panes and were rejected. Images are `NSView.cacheDisplay` content exports from the running native app, not painted mockups or WindowServer screenshots. They omit window chrome and cannot establish desktop compositing, physical input or animation behavior.

## Assessment (2026-10-16, owner correction)

The earlier recommendation coloring the composer is withdrawn. **Rejected by the owner: C, the 62-point two-row header.** It increases the title from the 13-point baseline to 18 points (bold when active, semibold otherwise), keeps project metadata at 11 points and native controls small, and gives the title its own line, aligns the project below it, groups the native view switch/prompts/menu in the lower-right area, and places close beside the title. The active pane is distinguished by its header surface and title weight. All composer backgrounds and send-button treatments stay identical across focus changes. This is a demo recommendation, not an adopted production design. The window toolbar remains the experiment selector; no per-session actions move into it.

| Candidate | Visual assessment |
|---|---|
| A, 44 points | The single row truncates the title earlier and relies on the weak accent rule. |
| B, 54 points | Stacking title/project helps, but the title still competes horizontally with the entire action group in four panes. |
| C, 62 points | The 18-point title gets substantially more space and content/actions form a clear hierarchy. The initial 70-point version was tightened by 8 points after visual inspection. Rejected by the owner as insufficient redesign. |

At the 425.25-point four-pane width, the title budget is 158.25 points in A, 200.25 in B and 328.25 in C. C retains the same compact native controls and adds no new persistent labels, controls or outlines. Its trial header colors remain `#D1E0D4` / `#334D3D` (light/dark); these are demo calibration values, not shared tokens.

Native compile diagnostics are empty. Seven control/action checks and 20 scenario-state checks pass, including equal neutral composer colors, one active pane, header containment and non-overlapping child frames. The 20 full-content renders cover light/dark, two/four panes and all four focus positions in a chat/terminal mix; two additional native header-region exports make the recommended layout easier to inspect. Full-content C light/dark, two/four-pane and mixed-terminal exports, both header strips and the competing B four-pane layout were visually inspected after increasing title size. B truncates three fixture titles; C shows all four completely at this width without increasing its 62-point height. This does not establish physical pointer/keyboard behavior or real terminal emulation.

Build exports are staged fresh before replacing `renders`; previous exports are preserved as `previous-renders-*` outside the handoff ZIP. This prevents rejected colored-composer previews from remaining in the current package when candidate counts change.

The baseline production reference and existing toolbar demos provide the applicable controls and interaction model. This iteration reuses their previously checked public AppKit APIs and existing runtime assets; it changes product-content layout only, without introducing native-control replacements.

Only the isolated Mac fixture and study documentation change. Production macOS, iPhone and TUI behavior remains unchanged. Capture correction (2026-10-16): the agent command runner still fails window capture, but invoking the same `macos-window-screenshot` helper through Terminal succeeds. This is a process-specific permission distinction, not a system-wide inability to capture. An inspected active native demo window screenshot includes real window chrome and four panes at 1560 × 949 logical pixels (3120 × 1898 before Retina reduction). At this narrower window size, long titles truncate; the earlier complete-title observation applies only to the 425.25-point fixture panes. The resized demo sidebar is empty except its footer, so that capture establishes pane-header appearance, not sidebar acceptance. Physical pointer/keyboard and terminal-emulation acceptance remain unverified. For screenshot review, embed the captured image directly in the conversation; an executable archive is optional supplementary material.

## Redraw requirement (2026-10-16)

The owner rejected the delivered composition: larger type and a second row do not constitute the requested redesign. Rework the relationships between session identity, title, focus and actions as a coherent header. Retain the larger-title requirement and neutral composers. Evaluate genuinely different spatial hierarchy and selection treatments, and deliver inspected real window screenshots directly. No production adoption is implied.

The redraw reuses the inspected production `MacPaneHeader` responsibilities and the study’s public AppKit native segmented control/buttons. The alternatives are product-content compositions, not replacements for system window chrome. A low-chrome title-led header is compared with a high-contrast session masthead: compact runtime/project identity, a dominant title, and a separate native view/action row. Existing state dots retain their meaning. The [Apple window guidance](https://developer.apple.com/design/human-interface-guidelines/windows) motivates recognizable input ownership; exact pane styling is a design experiment, not an Apple prescription.

## Single-line correction (2026-10-16)

The owner rejected the masthead redraw as cluttered and explicitly prohibits two-line pane headers. Keep one fixed-height row with a dominant title, compact native view switch and existing More entry. Project/runtime details and prompt history belong in the existing menu/tooltip; do not create a second metadata or action row. Keep focus on the header surface and composers neutral. Earlier multi-row assessments are rejected historical experiments.

## Current redraw constraints (2026-10-16)

The centered-title preview and heavy gray icon segmented switch are rejected. The header must stay one line, with a moderate left-aligned title, restrained controls and neutral composers. Oversized typography, metadata rows, centered composition and prominent icon clusters are not candidates for reuse.

The next fixture uses a 48-point header with a 15-point left-aligned title, a trailing text-based native view selector and More. The native selector remains NSSegmentedControl with its public NSSegmentedCell.isBordered setting; no replacement control is drawn. Public API: https://developer.apple.com/documentation/appkit/nscell/isbordered . Installed SDK headers confirm the property. The inspected reference is the existing study's selector and production MacPaneHeader; preserve select-one target/action semantics and remove the image presentation and heavy bezel. The active header has a distinct neutral surface; conversation and composer colors stay unchanged. This is an unapproved visual study, not a production design.
