# Mac messages that start with a list break the first line (2026-10-27)

## Symptom

A Mac conversation message whose first line is an ordered or unordered list is
laid out one line too tall and clipped at the row bottom. The first line shows
only the marker (`1.` or `•`), indented by the list's hanging indent, then a
blank line, then the item text. Later items in the same message look normal.

Owner capture (Mac 0.3.156): a four-item numbered user message rendered as
`1.` alone, an empty line, the first item's text, then items 2-3 with item 3
cut in half at the bubble's bottom edge. The same text renders correctly in
the TUI and on the iPhone.

## Root cause

The Mac conversation is one `NSTextStorage`/`NSLayoutManager` with one
`NSTextContainer` per message, separated by a newline that the layout-manager
delegate turns into `.containerBreak`
(`MacConversationTextDocument.update`).

After a control character that ends a container, TextKit 1 treats the **first
line of the next container as a continuation line of that paragraph**: it
applies the paragraph's `headIndent` and ignores `firstLineHeadIndent`. This is
invisible for ordinary paragraphs, code blocks and block quotes because their
`headIndent` and `firstLineHeadIndent` agree (0/8/12). Lists are the exception:
`ChatMarkdown` sets `headIndent = 18` with `firstLineHeadIndent = 0` so the
marker starts flush and the item text hangs at the tab stop of 18 pt.

With the continuation treatment the marker itself starts at 18 pt, at the tab
stop. The tab after the marker then has no reachable stop (the style's only
stop is at 18, already behind it; `defaultTabInterval` is 0), so TextKit ejects
the tab to a new line and the item text follows on the next line at
`headIndent`. The row is still measured from the detached measurement, which
has no container break before the message, so the drawn text is one line
taller than the row and the tail is clipped.

Minimal reproduction (production sources, two containers, one list message):

```
container 0  range={0,6}  "上一条消息\n"
container 1  range={6,90} used height 113   <- measured 67 for the same text alone
   y=0  x=18 "1."
   y=23 x=18 "\t"
   y=46 x=18 "流程日志的写法改造现在就安排subagent来实现\n"
   y=71 x=0  "2.\t流程步骤记录保留多少天…"
```

No source text produces this without a preceding container: the same block as
the only block starts at x=0 with `1.\t…` on one line. The defect is therefore
in the Mac container boundary, not in Markdown parsing or in the message text.

## Fix

`MacConversationTextDocument.update` appends a **near-zero paragraph break**
after every container-break newline (font 0.1 pt, no spacing). The next
container then starts with an empty paragraph, so its first real line is a
normal paragraph start: `firstLineHeadIndent` applies and list markers stay
flush. The extra paragraph adds well under 0.1 pt of height and is not part of
any message's selection range.

Do not "fix" this by changing list indents, by dropping the container break, by
replacing tabs with spaces, or by adding a visible blank line: those trade the
clipping for misaligned bullets, broken per-message containers or extra
spacing. The iPhone renders each message in its own `UITextView` (no container
break) and the TUI has its own cell renderer, so only the Mac document needs
the correction.

## Verification

- Production-source probe `scripts/test_mac_chat_lists.py` (`swiftc` harness,
  no pointer input): a numbered list and a bullet list as the first line of
  messages 2-4 keep `1.\t…` / `•\t…` on one line, the marker at x=0, no
  marker-only or tab-only line, and drawn height equal to the detached
  measurement. On the parent commit it fails with marker x=18, a tab-only line
  and drawn 167 pt vs measured 121 pt; with the fix it passes.
- `scripts/test_mac_text_selection.py` (native multi-block selection, copy,
  streaming, zoom, tables) passes with the container's paragraph start modelled.
  `test_mac_chat_open.py`, `test_mac_chat_reflow.py`,
  `test_mac_session_switch.py`, `test_mac_session_context_menu.py` and
  `test_mac_composer.py` pass.
- Real Mac app (Debug 0.3.157 (161) built from `80edea1`, exact session opened
  with `-CorralInspectConversation -CorralInspectPromptJump`): the prompt jump
  landed on the owner's numbered message and the WindowServer capture
  (3024×1898) shows all four items with flush markers and no clipping;
  `/tmp/corral-list-second.png`. Release 0.3.157 (161) was built from a clean
  checkout of `80edea1` (`agent_workflow` run
  `d03e496ba2b541dda744ba375301a031`, repo
  `/private/var/folders/.../opencode/corral-list-fix`), Developer ID signed and
  installed at `/Applications/Corral.app` (executable SHA-256
  `5e2f1f05…b48712de`); it is the only Corral GUI process and connects over
  local transport. The installed app restores with no session selected, so the
  visual evidence comes from the same-source Debug window; opening the
  conversation in the installed app needs a click.
- iPhone: each bubble is its own `UITextView`, so there is no container boundary
  and the reported layout cannot occur (not reproduced). TUI: terminal-cell
  renderer, no Markdown bubble (not applicable).
