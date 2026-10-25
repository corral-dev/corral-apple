# Project terminal (Mac and iPhone)

Status: adopted 2026-10-07 (owner request). Supersedes the "integrated terminal: do not copy" row of the [Mac reference study](MACOS_CLIENT_DESIGN.md#reference-study-what-applies) for this one capability; the client still runs no shell or process of its own.

## Owner requirement (2026-10-07)

Add a high-performance, stable, full-featured iTerm2-class terminal to the native Mac and iPhone clients, used the way the IntelliJ IDEA terminal is used: open it at any moment, it starts in the current project's folder, commands can be typed, and history is remembered.

## Reference behaviour

IntelliJ IDEA's terminal tool window ([JetBrains help](https://www.jetbrains.com/help/idea/terminal-emulator.html), [terminal settings](https://www.jetbrains.com/help/idea/settings-tools-terminal.html), [blog](https://blog.jetbrains.com/idea/2020/09/using-the-terminal-in-intellij-idea/)): ⌥F12 opens it at the bottom of the window; the start directory is the project root; new sessions open as tabs; tabs, working directory and shell history survive closing the IDE. What applies here: toggle key, project-root start, several sessions, persistence. Not copied: the bottom tool window and its tab strip (on the Mac each terminal is a split pane instead), per-tab shell picker, moving the terminal into an editor tab.

## Where the shell runs

The shell runs **on the paired development machine**, never on the client. The project path belongs to that machine, the Mac client may be connected to another computer, and the iPhone cannot run one at all. The host starts the user's login shell (`pw_shell -l`) in the project folder inside a detached tmux session on the Corral keepalive server, so:

- **Persistence and stability.** Hiding the terminal, quitting the app, a network change or a host-service restart never kills the shell; reopening reattaches to the same shell with its screen and recent scrollback. Only `exit` in the shell, an explicit close (Mac pane ✕ / ⌘W, iPhone Close Terminal), loss of the keepalive tmux server, or a reboot ends it.
- **Command memory.** History is the shell's own (zsh/bash/fish history file, ↑, Ctrl-R), shared with every other terminal on that machine. The client keeps no separate command history.
- **Isolation from agents.** Shell sessions use their own name prefix (`corralsh-`), so session scanning, hosted-card adoption, idle reclaim and pressure reaping never see or stop them.

## Wire (capability `project_shell`)

Shell output, input, sizing and colours reuse the desktop terminal stream (`terminal.*`, channel `term:<key>`; see the CLI remote knowledge base "桌面终端原始流") with keys of the form `shell:<id>`. Added methods: `shell.list` (all shells of the machine), `shell.open {cwd}` (start a shell in an existing folder; empty means home), `shell.close {key}`. Read-only pairings can neither list, open, close nor type. Paste goes through `input.text` (no submit) like the agent terminal, so bracketed paste follows the shell's real mode.

**Sizing differs from agent panes:** a shell has no TUI window viewer, so its grid follows the **latest active viewer** (the one that most recently attached, resized or typed), tmux's own default policy since 3.1 ([tmux `window-size latest`](https://github.com/tmux/tmux/wiki/Advanced-Use)). Since 2026-10-12 agent panes follow the most recently used viewer as well, through the shared registry that also counts TUI windows ([Mac design](MACOS_CLIENT_DESIGN.md#terminal-size-follows-the-client-in-use-owner-decision-2026-10-12)); `active: false` on attach/resize keeps a background window from taking a shell either. The iPhone's chat and snapshot mirror still never resizes an agent pane.

## Mac

**A terminal is a split pane (owner decision 2026-10-07, replacing a bottom tool-window panel the owner rejected on first sight).** Opening a terminal behaves like adding a pane: it appears beside the focused pane in the split area with the same equal widths, header, focus rule, close button and ⌘W, up to the four-pane limit (when full it replaces the focused pane, as Add Pane does). With no pane open it becomes the only pane.

- **Entries:** the toolbar terminal button and View ▸ Terminal (⌥F12, the IDEA key) open the focused project's terminal: a shell of that folder already in the split is focused; one running on the host but not shown is brought back as a pane; otherwise a new shell starts there. View ▸ New Terminal (⌥⌘T) and the Add Pane menu's "Terminal" item always start a new shell in the focused pane's project. A focused terminal pane's own folder counts as the project.
- **Pane:** header with a terminal glyph, the folder name and the running program when it is not the shell, and the close button; body is the same SwiftTerm emulator as agent terminal panes (local scrollback, selection, copy, links, light/dark palette reported to the host). The focused terminal pane owns the keyboard.
- **Opening without a jump (owner report 2026-10-07):** the shell starts at the grid its new pane will fit (slot width once it joins the split, split height below the header, base font), so the first screen needs no resize and the font never jumps; a shell opened at the host default of 100 × 30 first drew shrunk, then refitted. The waiting indicator appears only when attaching takes over 0.6 s, so an ordinary open shows the terminal background, then the prompt. The header keeps the folder name while a closed pane fades out.
- **Closing** a terminal pane (✕ or ⌘W) ends its shell, as closing the TUI's terminal pane does; when a program other than the shell is running it asks first. `exit` in the shell closes the pane. Navigating the split elsewhere (a sidebar click) only hides the pane; the shell keeps running and ⌥F12 brings it back.
- **Layout sharing:** terminal panes stay local to the Mac. TUI session groups (`layout.*`) only ever receive session keys, so a terminal never appears in a TUI window or the host layout store. Relaunch restores terminal panes with the other panes and reattaches to the same shells.

## iPhone

- **Entry:** "Open Terminal" in the session detail's top-right menu opens the project terminal for that session's project as a full-screen cover. The phone session page keeps only two navigation-bar buttons (back and that menu; owner rule 2026-10-07 in the UI design knowledge base); a separate terminal button squeezed the title. Hidden for read-only pairings and hosts without `project_shell`. This is separate from [iPhone agent terminal switching](IPHONE_AGENT_TERMINAL_DESIGN.md), approved 2026-10-14.
- **Screen:** navigation bar with Done, the shell tabs as a menu when more than one exists, and "+"; SwiftTerm's UIKit `TerminalView` fills the rest with its built-in keyboard accessory (Esc, Ctrl, Tab, arrows, function keys) ([SwiftTerm TerminalView](https://migueldeicaza.github.io/SwiftTerm/Classes/TerminalView.html), [accessory issue #116](https://github.com/migueldeicaza/SwiftTerm/issues/116)). Opening it with no shell for the project starts one.
- **Dependency:** SwiftTerm (MIT, same pinned release as the Mac) is used by the iPhone project shell and agent terminal; it supersedes "iPhone has no third-party package" in `apple/AGENTS.md`.

## Typing returns to the live screen (owner report 2026-10-07)

Owner report on Mac 0.3.33: after `clear` the prompt did not start at the top; blank rows and an older prompt sat above it. Cause (verified): after any small scroll back with the trackpad, SwiftTerm stops following output and only scrolls back when the caret leaves the visible rows, so the cleared screen was drawn a few rows lower in a view still scrolled into history. The host screen was correct (tmux showed the prompt on its top rows). Rule, as in iTerm2 and Terminal.app: a key typed or text pasted into any terminal (Mac agent and shell panes, iPhone terminal, TUI live pane) first returns the view to the live screen. In the TUI, Up/Down while scrolled back only return; other keys return and are sent.

## Security (review 2026-10-07)

An independent review (OpenCode worker, read-only) found no critical or high issue. Rules adopted from it:

- Read-only pairings can neither list, open, close, watch nor type into a shell; any call carrying a `shell:` key is refused for them.
- A `shell:` key is accepted only by `terminal.*`, `input.text` (paste) and `shell.close`; session, layout, pin, read-state, key and image methods refuse it, so a shell never enters the TUI's layout or session stores and no file can be dropped into its folder.
- Shell keys are `shell:` plus exactly eight lowercase hex digits; nothing else reaches tmux. Every tmux call is an argument list, never a shell string.
- Programs in a project shell may not write the device clipboard (OSC 52 is ignored, iTerm2's default); selecting and copying text still works. Agent terminal panes on the Mac keep OSC 52 for the agents' own copy commands. Remote programs can never read the clipboard, and only http/https links open.
- Shell output travels the same per-device encrypted data channel as other terminal frames; nothing of it is logged.
- Known boundary: if the keepalive tmux server itself dies (or the TUI's recovery restarts a server that reported itself dead), project shells end with it, like hosted agents. Shells are a soft limit of 16 per host service process.

## Acceptance

Real host, real paths: ⌥F12 opens a terminal pane beside the focused session in its project (`pwd`); type a command and see output; ↑ recalls it after relaunching the app; a second terminal in another project; `exit` closes the pane; resizing the window changes `tput cols`; the host layout store never contains a `shell:` key; light and dark; on iPhone the same shell opens from a session with the accessory keys working. A build, launch or unit test alone is not acceptance.

Debug inspection (no pointer driving; hold `/tmp/corral-mac-acceptance.lock`): `-CorralInspectProjectTerminal` with `CORRAL_INSPECTION_SHELL_FOLDER` (a disposable folder; never a real shell) opens a terminal pane, `CORRAL_INSPECTION_SHELL_CLOSE_AFTER` closes it, `CORRAL_INSPECTION_COMPARE_KEY` repeats both with a chat pane; `-CorralInspectProjectTerminalPair` opens two disposable terminals together to check narrow splits, and `-CorralInspectTerminalFit` records each Mac emulator's pane size, vote and host snapshot grid in `/tmp/corral-inspect.log`. `/tmp/corral-shell-motion.json` gets display-link frames plus main-thread stalls per step. `CORRAL_INSPECTION_SHELL_TYPE` types a command; `CORRAL_INSPECTION_SHELL_SCROLL_CLEAR` scrolls back and types `clear` as key events. iPhone: `-CorralInspectConversation -CorralInspectProjectTerminal` with the same folder and typing variables.

## Delivery (2026-10-07)

- Host: CLI v0.24.266/0.24.267 (`shell.*`, security hardening); the remote service runs it. The TUI typing rule ships with v0.24.268.
- Mac 0.3.36 (40), source `b82e165`: universal Release from an export of the commit, Developer ID signed, installed in `/Applications/Corral.app`; diagnostics read back 0.3.36 / 40, local transport ready, data attached.
- iPhone 1.0.127 (137), same source, installed on iPhone Max and read back with `devicectl`.
- Verified on the real host: Mac Debug build opened a terminal pane beside two session panes in the focused project (`pwd`, output, `tput cols`), reopening reattached the same shell with its history, `exit` closed the pane, the host layout store held no `shell:` key; after scrolling back three lines and typing `clear` as key events, the view was at the bottom (scroll position 1.0) with the prompt on the top rows. iPhone same-source Debug build opened the terminal from a session in a disposable folder: command output, a 58 × 29 grid matching the phone, keyboard accessory with Esc, Ctrl, Tab and arrows; the Release build was restored afterwards.
- Not exercised: physical keyboard and IME typing on the iPhone terminal, ⌥F12 and ⌥⌘T pressed on a physical keyboard (menu wiring built and inspected only), the busy-close confirmation, VoiceOver.

<!-- 该文档整理/压缩于 2026-10-20 -->
