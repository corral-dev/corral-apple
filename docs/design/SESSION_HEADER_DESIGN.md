# Session Header — Detailed Design

Status: **Adopted for implementation, 2026-09-15.** The conversation header in the installed app must match this layout; device screenshots remain the acceptance evidence and this document is not a shipping claim. Numerical values are design targets, not measurements. The [UI design knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md) remains the authority for shipped behavior in details not yet verified against an installed screen.

## 1. Problem and intended result

The supplied screenshot showed a long single-line title, a visually prominent circular Back button, and a centered secondary row (spinner, green Running text, blue runtime dot, runtime name, disclosure arrow), with the activity capsule below the navigation surface barely separated. These are observations of that screenshot, not a diagnosis of the layout code.

The redesign gives the header three responsibilities in order: identify the conversation through its title; identify the assistant and its state without competing with the title; offer Back and the existing question-history entry. Reading order is title → assistant/state → conversation content, and only the state marker needs a bright signal color. No new settings, stop controls, terminal access, model picker or host badges.

## 2. Composition

**Project in the header (owner report 2026-10-20):** the header must identify the project, not only the assistant — a fresh session showed `Claude · 新会话` over `Claude`, naming no project. The iPhone secondary row reads `● Assistant · Project ⌄`, where Project is `SessionPresentation.projectName(from:)` (the same leaf name the session list shows) and is omitted when empty. Project text truncates before the assistant name; the disclosure stays visible; the VoiceOver heading includes the project. The Mac pane header shows the same project as secondary text after the title, truncating the project before the title. The TUI pane title reads `Assistant · Project · Title` ([Terminal UI knowledge base](../https://github.com/corral-dev/corral/blob/main/docs/TERMINAL_UI_KNOWLEDGE_BASE.md)). Do not substitute a full path.

**More action icon (2026-10-01):** the conversation's top-right More menu uses the plain horizontal `ellipsis` system symbol without a ring around the dots, retaining the native toolbar button surface, ≥44-point target, accessibility label and menu actions.

**Header parity (owner correction 2026-10-17):** Chat and Terminal use exactly the same title, assistant name, colored marker, disclosure arrow and tappable prompt-history header. Never replace the assistant subtitle with "Terminal" or remove the disclosure in Terminal mode; the existing native principal-toolbar Button opens the same prompt sheet in either mode, and selecting a prompt keeps Terminal active using its existing native prompt navigation. Inspected reference: `SessionDetailView.sessionHeaderLabel` in Chat mode plus its shared toolbar Button/sheet — remove only the mode-specific subtitle branch. Mac pane headers already retain title and prompt entry across display modes; terminal CLI chrome stays independently owned.

**Display mode (owner correction 2026-10-14):** Chat / Terminal belongs inside this existing More menu with native selection marks, not a standalone segmented row under the navigation bar. The [iPhone agent terminal contract](IPHONE_AGENT_TERMINAL_DESIGN.md) owns capability, local display and remote-action access boundaries.

Delivery evidence: Release 1.0.76 (86) built, installed on the paired iPhone with matching version readback and uploaded to AppShelf; on-device visual acceptance remains unverified (launch denied because the phone was locked, captured screenshot black).

**Session fork naming:** the existing same-assistant action follows the shared [Fork Session terminology contract](../https://github.com/corral-dev/corral/blob/main/docs/CROSS_RUNTIME_HANDOFF_KNOWLEDGE_BASE.md#session-fork-naming-2026-10-01), including menu and accessibility wording; the wire method remains `session.copy`. Delivery: 1.0.77 (87) installed with matching readback and uploaded; the later launch succeeded but both captured phone images were black, so the menu's physical visual acceptance remains unverified (signed build and localization checks passed).

```text
System status bar — managed by iOS

  ‹     你认为我的 doc-skills
        需要压缩一下吗          ⌄
        Codex   ● Running

  [ tools  Agent activity  3 tools  › ]
  Conversation content …
```

- Back occupies the leading control column; the title and metadata share one leading edge beside it and are not independently centered.
- The title has two available lines at ordinary sizes. The example break is illustrative: real layout wraps to available width rather than inserting a newline into the stored title.
- The disclosure belongs to the title block and opens question history, never a model or status selector.
- Agent activity remains scrollable conversation content, not part of the fixed header, and must not become a pinned third status row.
- Reserve a compact two-line title area for both short and long titles; a one-line title leaves its second slot unused so the metadata baseline stays stable. This trades a little height for predictable placement and must be reviewed in the real page with the keyboard visible.

### Geometry at the default system text size

All values are logical points; the system status-bar safe area is excluded from header height.

| Element | Proposed target | Constraint |
|---|---|---|
| Header content height | 80 | Derived from 8 + 44 + 4 + 16 + 8; never force it at larger text sizes |
| Leading/trailing page inset | 16 | Respect wider system safe areas in landscape |
| Back target | At least 44 × 44 | Native target takes precedence over decorative sizing |
| Back visual | Approximately 36–40 diameter | Keep native rendering; do not wrap a native glass button in another circle |
| Back glyph | Approximately 20–22 | System directional chevron, visually lighter than the title |
| Gap after Back target | 12 | Title starts near x=72 on an ordinary portrait viewport |
| Title area | Two approximately 22-point lines | 17-point semantic headline, semibold, leading aligned |
| Title-to-metadata gap | 4 | Separate identity from state without creating a second bar |
| Metadata | Approximately 16 high | 13-point semantic footnote, regular weight |
| Assistant-to-state group gap | 12 | No extra separator dot |
| State marker | 6 diameter | Followed by 6 points before the state text |
| Disclosure glyph | Approximately 10 | Reserve a 16-point trailing slot in the title area |
| First visible conversation item | Approximately 12 below header content boundary at rest | Count the existing conversation inset; do not add a second inset |

The disclosure aligns with the last visible title line, must not wrap onto its own line and must not move when the state text changes. The whole title/metadata region is one target, so the small glyph is not a small independent control. The 80-point target is the deliberate cost of a readable two-line title plus metadata; this proposal does **not** claim a shorter header than the screenshot.

**Containment revision (implementation):** keep the system navigation bar, native Back and `.toolbarRole(.editor)` so the title group sits on the leading edge, and place the two-line title plus metadata in the principal toolbar item. Do **not** reserve an empty second title line: a standard inline bar clips an 80-point reserved slot. A one-line title stays compact; a long title grows to two lines. If device review finds the title clipped, revise containment again rather than shrinking type.

## 3. Typography, color, and material

### Typography

- Title: system headline, semibold, original conversation wording. No all-bold oversized heading, letter-spacing compression, marquee or automatic font shrinking.
- Assistant: system footnote, regular weight, runtime's canonical name (never a model name in its place).
- State: system footnote, regular weight, secondary label color — the small marker carries the signal color, not the whole secondary row.
- The app's conversation-font setting affects conversation content only; system Dynamic Type still affects the header.

### Color

- Title and Back use semantic primary label colors; state and disclosure use readable secondary label colors.
- Reuse the established assistant and attention palette from the [UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md); do not sample approximate blue/green values from the generated preview or invent an incompatible quieter palette.
- Prefer the established runtime tint for the runtime label only if it meets small-text contrast on the real navigation surface; otherwise use primary label text and keep the assistant identifiable by name. Do not lower opacity to obtain a pale blue.
- There is only one status marker: remove the extra blue brand dot and the perpetual execution spinner from this composition.
- Running stays green and waiting for user input stays yellow; red keeps meaning the product's existing unread/new-result signal, not a new Ended or Offline state.

### Material

- Keep system navigation material and native Back treatment on supported systems; older systems use their native navigation appearance.
- The generated light preview expresses hierarchy; its flat background is not a requirement to disable native glass.
- No glass card around the title, outer highlight ring, decorative gradient or custom heavy bottom rule.
- Conversation background and the content-hugging activity capsule keep their existing semantic surfaces.
- Dark Mode, Increase Contrast and Reduce Transparency must stay readable through native semantic appearance; never hardcode a white header.

## 4. Content and state rules

### Title

1. Use the current conversation title verbatim, with display-only whitespace normalization.
2. At ordinary sizes: at most two visible lines, truncating at the end of line two. Never truncate the stored title or rewrite it into an AI-generated short title.
3. Missing title: localized `Untitled session` / `未命名会话`; never a filesystem path or opaque identifier.
4. The question-history sheet includes the full title as wrapping text in its scrollable content, before the existing question cards, while keeping the sheet's own navigation title short.
5. A title update keeps the reserved height stable and does not reset the conversation or move the reader away from their message.

### Secondary row

**Where the live header is (2026-10-01):** the shipped header is `SessionDetailView.sessionHeaderLabel` (title + assistant name, opens question history). `SessionHeaderTitleView` / `SessionHeaderPresentation` are not mounted anywhere, so editing them changes nothing on screen.

**Superseded in part (owner decision 2026-10-01):** Running and Needs reply are no longer shown in the header; the activity cue above the composer owns them (see the [UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md#conversation-polish-2026-10-01)). The header keeps title and assistant name.

The row reads `Assistant   marker State`; the following is proposed presentation, not new server states or a new liveness detector:

| Confirmed condition | English / Simplified Chinese | Marker |
|---|---|---|
| Actively executing | Running / 执行中 | Green |
| Waiting for the person's answer | Needs reply / 等你回复 | Yellow |
| Session alive, confirmed idle | Ready / 就绪 | Neutral |
| Session definitively ended | Ended / 已结束 | Neutral |
| Connecting or reconnecting, execution freshness unavailable | Connecting… / 连接中… | Neutral |
| Disconnected, execution freshness unavailable | Offline / 已断开 | Neutral |
| Connected but execution state not yet confirmed | Updating… / 更新中… | Neutral |

- Resolve execution state from the existing live-conversation source; a live process, a connected socket or recently visible text does not by itself mean Running. The open conversation's `live` / attention from watch and metadata must drive the header — do not keep a stale list-row `live=false` that paints Ended while the watch reports the session alive. Treat keepalive/`hosted` as still live; while connected, a fresh `working` / `waiting` attention signal wins over a stale not-live flag.
- A stale running snapshot must not remain an affirmative live claim after disconnection: show connection/unknown wording in the same status slot and never append a second network badge.
- A confirmed ended state can remain Ended when viewing historical content offline; offline does not imply the remote task ended or failed.
- For conflicting fresh execution signals use the existing authoritative state resolution; if it cannot distinguish these rows, mark the mapping gap during implementation instead of inferring it with timers or a new transport protocol.
- No blinking, breathing, rotating or bouncing during normal execution: static color plus words. A screen-content loading indicator may remain where content actually loads.
- State changes update metadata in place without moving title, Back or conversation; Waiting→Running must not create or remove a full-width strip in the message area.
- Unknown runtime names stay visible in neutral text; all user-facing fallback/state/accessibility strings have English and Simplified Chinese versions.

## 5. Interaction contract

| Action | Result |
|---|---|
| Tap Back | Return through the existing navigation stack; retain normal list position and draft behavior |
| Interactive back swipe | Retain the native gesture and transition |
| Tap title, subtitle, or disclosure | Present the existing large question-history sheet exactly once |
| Tap a question card | Dismiss that sheet and navigate to the corresponding conversation message using the existing behavior |
| Dismiss the sheet | Return to the prior reading position unless a question was selected; never jump to latest merely because the sheet closed |
| Tap an empty history entry | The same sheet opens with its localized empty state and full title |
| Tap Agent activity | Open the existing tool-detail sheet, independently of the header |

- Keep the question-history filter: genuine user questions only, oldest to newest, no injected context or relay/system turns.
- Back and heading targets do not overlap; the title group has a minimum 44-point target and a subtle visible pressed response, with no persistent pill background.
- Use native sheet and navigation transitions and respect Reduce Motion; no overshoot or title-collapse animation.
- Opening question history must not submit or discard a composer draft; the sheet does not autofocus an input, and keyboard dismissal follows existing modal behavior rather than a new keyboard-height controller.
- The header stays visible during conversation scrolling and keyboard presentation; it does not collapse based on scroll direction.

## 6. Accessibility and adaptation

- VoiceOver order: Back → combined heading button → conversation content. The heading announces the **full** title, assistant and state with a localized hint such as `Show questions in this session`; hide decorative dot/chevron elements from separate navigation.
- Announce an actionable transition such as Needs reply once; never announce every streaming refresh or interrupt reading.
- At larger ordinary Dynamic Type sizes the header grows with its semantic fonts; 80 is a default target, not a fixed frame.
- At accessibility sizes allow up to three title lines and move the state to a separate metadata line when assistant plus state no longer fits, keeping the full title in the sheet and VoiceOver. No font shrinking, overlap or horizontal scrolling.
- At narrow widths/landscape preserve safe areas and Back first; truncate the title rather than clipping controls, and wrap the state group intact when it does not fit. State text takes priority over optional decoration.
- Respect right-to-left layout and mirror directional Back/disclosure symbols where appropriate; mixed Chinese and Latin titles stay ordinary text, not a code-style font.
- Verify contrast in both appearances and over scrolled content; state meaning is always available in words, not color alone.

## 7. Integration boundaries and feasibility gate

This is a product/layout specification: header source code was not audited in this documentation task, and no particular SwiftUI modifier is claimed to satisfy the geometry.

- Preserve native navigation-stack ownership, back gestures, system safe areas and existing presentation ownership.
- Do not assume a standard inline navigation bar fits two title lines plus metadata; before full implementation verify the chosen navigation host can reserve the required height on supported OS versions and at large text.
- If no fitting native title host provides that space, explicitly revise containment/design. Never hide the navigation bar, draw a replacement over the status bar, or overlay a clipped title.
- Do not read keyboard frames, add global-window probes, create another window or compensate with delayed scroll commands for this header.
- Reuse existing session identity, runtime naming, execution-state ownership, question-history filtering and scroll destinations; no new polling, server state machine, model call or persistent setting.
- Changes are confined to the conversation header and the full-title section of its existing question-history sheet; agent activity needs only boundary-spacing verification.
- The UI knowledge base previously described a centered title group with a runtime color dot; this layout replaces those two presentation choices, and the matching KB paragraph was updated with the implementation.

## 8. Acceptance contract

Implementation is accepted only from evidence on the affected screen, not from the generated image or an installation result.

| Scenario | Required evidence |
|---|---|
| Original screenshot title | Two readable lines when actual width requires it; complete assistant/state; no clipped disclosure |
| Short and very long titles | Stable ordinary metadata baseline; truncation only after line two; full title reachable in the sheet |
| Default and accessibility text | Normal page stays compact; large text grows/reflows without overlapping Back or content |
| Light/dark, contrast, transparency | Readable native surfaces; no custom highlight frame or pale unreadable runtime label |
| Running → Needs reply → Running → Ready | Correct words and established signal colors; no spinner or repeated conversation status strip |
| Disconnect/reconnect during execution | No stale affirmative Running claim; title/history stay available; fresh state returns without layout jumps |
| Back, edge swipe, question-history entry | Native navigation works; one sheet per activation; selected question resolves correctly |
| Sheet dismissed without selection | Reading position and draft retained; full title available even with no questions |
| Keyboard, short transcript, long transcript | Header never covers content; existing keyboard avoidance/following behavior intact |
| First activity capsule at rest | Fully visible with one deliberate top gap; stays content-hugging and scrolls with conversation |
| VoiceOver and Reduce Motion | One heading target, full title announcement, non-overlapping controls, no needless motion |

For implementation later: inspect paired-device availability first and use the existing installed app on the available physical iPhone. Do not install a second UI-test app, and a simulator capture does not replace this acceptance. Delivery follows the shared installation/upload process, then capture and inspect the header; record untestable states separately rather than marking the table passed.

## 9. Basis and evidence limits

- User screenshot plus the follow-up request for a detailed design: source of the problem statement and requested scope.
- [Product UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md): current state colors, question-history behavior, content-hugging activity, type-setting boundary and navigation interaction.
- [Mobile UI rework brief](MOBILE_UI_REWORK_BRIEF.md): native composition, compact normal text and actual-app acceptance.
- [Apple toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [typography](https://developer.apple.com/design/human-interface-guidelines/typography), [layout](https://developer.apple.com/design/human-interface-guidelines/layout), [materials](https://developer.apple.com/design/human-interface-guidelines/materials).

The reference image is a visual sketch, not an exact pixel specification or a verified iOS rendering; layout targets, proposed state copy, accessible reflow and navigation-host feasibility remain to be validated on the physical iPhone after implementation.

<!-- 该文档整理/压缩于 2026-11-15 -->
