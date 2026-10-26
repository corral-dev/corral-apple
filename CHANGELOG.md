# Changelog

Release notes are bilingual: English first, then complete Simplified Chinese.
Development adds entries under `## Unreleased`; at release time they become the
next version's section. A `Release: minor` or `Release: major` line requests a
larger version step; `Release: hold <reason>` keeps the changes unreleased until
the named acceptance is done.

## Unreleased

### macOS

- Reorder split panes by dragging a pane header onto another pane's header: the dragged pane takes that slot, intervening panes shift, and the focused session, drafts, prompts card and native terminal views stay intact. A compact grip marks the draggable header area; a single pane has no reorder affordance.

### macOS and iPhone

- The terminal view no longer jumps to the start of a Pi conversation. When Pi redraws its whole screen (after a session switch, split or resize), a reader who had scrolled back now returns to the latest output instead of being left on the first line.

### 简体中文

- Mac 分屏支持拖动顶部调整顺序：把一格拖到另一格顶部松手，它插入该位置，中间的分屏依次后移，焦点会话、草稿、提问卡片和原生终端视图都保持不变。顶部有紧凑拖动柄；只有一个分屏时不显示。
- 终端视图不再跳回 Pi 会话最开头：Pi 整屏重画时（切换会话、分屏或改变尺寸之后），之前往上翻过的视图会回到最新输出，而不是停在第一行。
