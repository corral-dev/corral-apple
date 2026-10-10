# Native toolbar demos

Three standalone macOS fixture apps explore the [icon-only toolbar requirement](../../docs/design/MACOS_CLIENT_DESIGN.md#icon-only-toolbar-exploration-owner-correction-2026-10-07).

- **A — Grouped:** window actions stay in the real window toolbar; each pane groups its native Chat/Terminal segmented control separately from prompts, menu and close.
- **B — Window toolbar:** view switching and prompts move into the real window toolbar and follow the focused pane. This reduces repeated controls in splits but changes where pane actions live.
- **C — Compact:** each pane has one native terminal toggle instead of two exposed view segments; prompts, menu and close stay beside it. Turning the toggle off returns to chat.

All action buttons are icon-only, using SF Symbols, tooltips and accessibility names. Menus and conversation content retain ordinary text. Window toolbars, segmented controls, search, popovers and split views use AppKit directly. The fixture chat and terminal are deliberately local, with no networking, host pairing, production preferences, shell execution or real session mutation. The apps have separate bundle identifiers and never replace Corral.

## Build and open

Requires macOS 26+ and Xcode command-line tools. Build outputs default to `~/.config/corral/design-previews/toolbar` (honoring `XDG_CONFIG_HOME`).

```sh
python3 scripts/toolbar-demos/build.py --open
```

The build creates three independently launchable `.app` bundles and a ZIP. It records the source commit in every bundle and exports its sources from that commit; commit intended demo changes before packaging. Uncommitted later edits cannot enter a bundle. `--output` selects another output directory. Existing bundles are replaced only inside that selected build directory; the installed Corral app is never touched.

You can click Chat/Terminal, prompts, add/close pane, the session menu and the project-terminal button. Sending a message adds a local fixture reply. Search highlights a match in the focused pane. The menus expose only implemented local fixture behavior; they never perform real restart, stop, handoff or deletion.

For deterministic visual acceptance, launch a built executable with `--scenario terminal`, `--scenario prompts`, `--scenario split` or `--scenario dark`. `--verify <receipt.json>` exercises the same local action handlers inside the running native app, verifies the resulting view state and writes an evidence receipt, then leaves the default chat open. This is programmatic action/rendering evidence, not physical pointer or keyboard acceptance.

Screenshots use the installed `macos-window-screenshot` skill. No image generation or custom drawings replace the system's interface controls or symbols.
