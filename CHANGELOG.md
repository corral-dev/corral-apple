# Changelog

Release notes are bilingual: English first, then complete Simplified Chinese.
Development adds entries under `## Unreleased`; at release time they become the
next version's section. A `Release: minor` or `Release: major` line requests a
larger version step; `Release: hold <reason>` keeps the changes unreleased until
the named acceptance is done.

## Mac 0.3.159 (164) / iPhone 1.0.205 (217)

### English

- Stabilized scrolling inside long iPhone and iPad messages: unchanged content no longer resets the native text layout, the scroll range stays consistent, and image-size changes preserve the reading position. Native text selection and the half-screen bubble cap remain intact.
- Cited images appear at their Markdown position inside the message, retain their aspect ratio and open in the full-quality viewer. Mermaid and PlantUML still render locally; leaving a message mid-render no longer prevents the same drawing from loading on return.
- Wide iPhone and iPad tables become row lists with labeled cells, avoiding horizontal scrolling. Mac keeps native tables and correctly retains list markers at the beginning of a message.

### 简体中文

- 优化 iPhone 和 iPad 长消息内部滚动：内容不变时不再重置原生文本排版，滚动范围保持稳定，图片尺寸变化时保留阅读位置。原生文本选择和半屏气泡高度上限保持不变。
- 引用图片显示在消息正文的 Markdown 引用位置，保持比例并可打开原图。Mermaid 和 PlantUML 仍在本地绘制；绘制途中离开消息，返回后同一图表仍可正常加载。
- iPhone 和 iPad 的宽表格改为带字段标签的逐行列表，无需左右滚动。Mac 保留原生表格，并正确显示消息开头的列表标记。

## Mac 0.3.158 (162) / iPhone 1.0.204 (215)

### English

- Cited Markdown images render inside the message at the position they are referenced, not in a fixed strip below the text. The image keeps its aspect ratio, loads asynchronously with a neutral placeholder, opens the full-quality preview on tap, and the following prose stays after it; bare path mentions keep the existing tile row.
- iPhone and iPad fall back from Markdown tables to a row list: each row is a bullet item titled by its first cell, and the remaining cells become labeled `Header: value` lines. Empty cells are omitted, so a wide table needs no horizontal scrolling.
- Leaving a conversation while a Mermaid or PlantUML drawing is still rendering no longer marks that source invalid; returning to the same message renders it normally. Copying a message with a drawing or table still yields the original text.
- Mac keeps its native table rendering through the shared Markdown table projection. Image, Mermaid and PlantUML rendering in the Mac conversation is unchanged.

### 简体中文

- 引用图片现在显示在消息正文中 Markdown 引用它的位置，不再固定在文字底部。图片保持比例，加载时显示中性占位，点击可看原图；后面的文字仍在图片之后。单纯提到路径的图片仍保留原来的底部缩略图。
- iPhone 和 iPad 的 Markdown 表格改为按行铺开的列表：每行一条，第一列做标题，其余列显示成「表头: 内容」，空单元格省略；宽表也不需要左右滑动。
- 图表还在绘制时离开会话，不会再把该源码记成无效；回到同一条消息会正常绘制。复制带图表或表格的消息仍能得到原始文字。
- Mac 通过共用表格投影继续使用原生表格渲染；Mac 对话中的图片、Mermaid 与 PlantUML 渲染保持不变。

## Mac 0.3.156 (160) / iPhone 1.0.200 (211)

### English

- Chat now displays cited images and locally rendered Mermaid/PlantUML diagrams. Open a drawing in the native viewer or inspect its original source; invalid or unsafe diagrams remain readable source.
- Mac keeps one live terminal stream when a newly created session receives its permanent identity, preventing the terminal grid from repeatedly disappearing and returning.
- Refined Mac pane reordering and aligned sidebar date counts with session content.

### 简体中文

- 聊天支持引用图片，以及在本地绘制 Mermaid/PlantUML 图表。可用原生查看器打开图表或查看原始源码；无效或不安全的图表保留为可读源码。
- Mac 新建会话获得正式身份时保留同一条实时终端流，避免终端格子反复消失、重现。
- 优化 Mac 分屏拖动排序，并将侧栏日期计数与会话内容对齐。

## 0.3.154 — 2026-10-26

### macOS

- Keep agent and shell headers compact while their full leading strips remain draggable; the drag region no longer expands the header into the conversation.
- Fix split-pane drag interruption and landing: immediate release no longer leaves neighbours overlapped, roster changes cannot write or restart an interrupted drag, and an older landing cannot finish a newer drag. Regression checks now execute the production motion/reset path.
- The Your prompts card's last row now returns the terminal pane's agent-owned viewport to live output through the host's guarded `terminal.latest` action, instead of scrolling only SwiftTerm's local buffer. Drafts, running work and the Chat/Terminal mode are preserved; older hosts keep the local-buffer fallback, and Chat mode is unchanged.
- Reorder split panes by dragging the header itself: the pane lifts with a shadow and follows the pointer, neighbours slide aside once it covers half of them, and releasing inserts it at that slot (`[1, 2, 3, 4]` → drag 4 over 2 → `[1, 4, 2, 3]`). The title, project label, status area and blank header space are all handles; the trailing menu and Close stay buttons, a click without travel keeps the title's prompts toggle and focus, single panes do not move, a cancelled drag restores its starting order, and a roster change abandons the drag without writing a group. The order syncs once on release and the focused session, drafts and native terminals stay intact.

### 简体中文

- 会话和项目终端的顶栏保持紧凑，左侧整条区域仍可拖动；拖动区域不会再把顶栏撑高并挤占对话。
- 修复分屏拖动的中断和落位：快速松手不再让相邻面板残留重叠，面板数量变化后不会错误同步或重新启动旧拖动，旧动画也不会提前结束新拖动。回归检查现已执行生产代码中的位移和收尾流程。
- 提问卡片的最后一行现在通过宿主侧受控的 `terminal.latest` 动作，把终端分屏里助手自己的滚动位置带回最新输出，而不只是滚 SwiftTerm 的本地缓冲。草稿、进行中的工作和聊天/终端模式都保留；旧宿主继续使用本地缓冲回退，聊天模式不变。
- 分屏改为直接拖动顶栏排序：被拖的格子浮起并带阴影跟随鼠标，盖住相邻格一半时相邻格实时让位，松手后插入该位置（`[1, 2, 3, 4]` 把 4 拖过 2 得到 `[1, 4, 2, 3]`）。标题、项目名、状态区和顶栏空白处都可拖；右侧菜单和关闭仍是按钮，只点不拖时标题的提问卡开关和聚焦照常，只有一个分屏时不能拖，拖动被取消时恢复原顺序，格子数量变化时放弃本次拖动，两者都不写分组。顺序只在松手后同步一次，焦点会话、草稿和原生终端都保持不变。

## 0.3.152

### macOS

- Reorder split panes by dragging a pane header onto another pane's header: the dragged pane takes that slot, intervening panes shift, and the focused session, drafts, prompts card and native terminal views stay intact. A compact grip marks the draggable header area; a single pane has no reorder affordance.

### macOS and iPhone

- The terminal view no longer jumps to the start of a Pi conversation. When Pi redraws its whole screen (after a session switch, split or resize), a reader who had scrolled back now returns to the latest output instead of being left on the first line.

### 简体中文

- Mac 分屏支持拖动顶部调整顺序：把一格拖到另一格顶部松手，它插入该位置，中间的分屏依次后移，焦点会话、草稿、提问卡片和原生终端视图都保持不变。顶部有紧凑拖动柄；只有一个分屏时不显示。
- 终端视图不再跳回 Pi 会话最开头：Pi 整屏重画时（切换会话、分屏或改变尺寸之后），之前往上翻过的视图会回到最新输出，而不是停在第一行。

