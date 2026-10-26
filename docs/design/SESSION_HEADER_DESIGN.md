# Session Header — Detailed Design

Status: **Adopted for implementation, 2026-09-15.** The conversation header in the installed app must match this layout. Device screenshots remain the acceptance evidence; this document is not itself a shipping claim.

The user requested a redesign of the conversation header and then a detailed design. This document specifies the proposed layout and its acceptance contract. Numerical values below are design targets, not measurements of the installed app. The existing [UI design knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md) remains the authority for shipped behavior for implementation details not yet verified against an installed screen.

## 1. Problem and intended result

The supplied screenshot shows a long single-line title, a visually prominent circular Back button, and a centered secondary row containing a spinner, green Running text, a blue runtime dot, the runtime name, and a disclosure arrow. The activity capsule immediately below the navigation surface has little visible separation. These are observations of that screenshot, not a diagnosis of the layout code.

The redesign gives the header three clear responsibilities, in this order:

1. Identify the current conversation through its title.
2. Identify the assistant and explain its current state without competing with the title.
3. Offer Back and the existing question-history entry.

The proposed reading order is title → assistant/state → conversation content. Only the state marker needs a bright signal color. No new settings, stop controls, terminal access, model picker, or host badges are introduced.

## 2. Composition

**Project in the header (owner report 2026-10-20):** the header must identify the project, not only the assistant. A freshly created session showed `Claude · 新会话` over `Claude`, so the page named no project. The iPhone secondary row reads `● Assistant · Project ⌄`, where Project is `SessionPresentation.projectName(from:)` (the same leaf name the session list shows) and is omitted when empty. The project text truncates before the assistant name; the disclosure stays visible. The VoiceOver heading includes the project. The Mac pane header shows the same project name as secondary text after the title; truncation shortens the project text before the title. The TUI pane title reads `Assistant · Project · Title` ([Terminal UI knowledge base](../https://github.com/corral-dev/corral/blob/main/docs/TERMINAL_UI_KNOWLEDGE_BASE.md)). Do not substitute a full path.

**More action icon (2026-10-01):** the conversation's top-right More menu uses the plain horizontal `ellipsis` system symbol, without a ring around the dots. Retain the existing native toolbar button surface, minimum 44-point target, accessibility label and menu actions.

**Header parity (owner correction 2026-10-17):** Chat and Terminal use exactly the same title, assistant name, colored marker, disclosure arrow and tappable prompt-history header. Never replace the assistant subtitle with “Terminal” or remove the disclosure in Terminal mode. The existing native principal-toolbar Button opens the same prompt sheet in either mode; selecting a prompt keeps Terminal active and uses its existing native prompt navigation. The inspected reference is `SessionDetailView.sessionHeaderLabel` in Chat mode and its shared toolbar Button/sheet; remove only the mode-specific subtitle branch. Mac pane headers already retain their title and prompt entry across display modes; terminal CLI chrome remains independently owned.

**Display mode (owner correction 2026-10-14):** Chat / Terminal belongs inside this existing More menu, with native selection marks, rather than a standalone segmented row under the navigation bar. The [iPhone agent terminal contract](IPHONE_AGENT_TERMINAL_DESIGN.md) owns capability, local display and remote-action access boundaries.

Delivery evidence: Release 1.0.76 (86) built successfully, was installed on the paired iPhone with matching device version readback, and was uploaded to AppShelf. On-device visual acceptance remains unverified: launch was denied because the phone was locked, and the captured screenshot was black.

**Session fork naming:** the existing same-assistant action follows the shared [Fork Session terminology contract](../https://github.com/corral-dev/corral/blob/main/docs/CROSS_RUNTIME_HANDOFF_KNOWLEDGE_BASE.md#session-fork-naming-2026-10-01), including menu and accessibility wording. The wire method remains `session.copy`.

Fork naming delivery: 1.0.77 (87) was installed on the paired iPhone with matching version readback and uploaded to AppShelf. The later launch command succeeded, but both captured phone images were black; the menu's physical visual acceptance remains unverified. The signed build and localization checks passed.

```text
System status bar — managed by iOS

  ‹     你认为我的 doc-skills
        需要压缩一下吗          ⌄
        Codex   ● Running

  [ tools  Agent activity  3 tools  › ]
  Conversation content …
```

- Back occupies the leading control column. The title and metadata share one leading edge beside it; they are not independently centered.
- The title has two available lines at ordinary text sizes. The example line break is illustrative: real layout wraps to the available width rather than inserting a newline into the stored title.
- The disclosure belongs to the title block. It opens question history, never a model or status selector.
- Agent activity remains scrollable conversation content. It is not part of the fixed header and must not become a pinned third status row.
- Reserve a compact two-line title area for both short and long titles. A one-line title leaves its second line slot unused, keeping the metadata baseline stable. This deliberately trades a small amount of height for predictable placement; it must be reviewed in the real page, with the keyboard visible.

### Geometry at the default system text size

All values are logical points. The system status-bar safe area is excluded from header height.

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

The disclosure aligns with the last visible title line. It must not wrap onto a line of its own or change position when the state text changes. The entire title/metadata region is one target, so the small glyph is not a small independent control.

The 80-point target is a deliberate cost of a readable two-line title plus metadata. This proposal does **not** claim a shorter header than the current screenshot.

**Containment revision (implementation):** keep the system navigation bar, native Back, and `.toolbarRole(.editor)` so the title group sits on the leading edge. Place the two-line title plus metadata in the principal toolbar item. Do **not** reserve an empty second title line: a standard inline bar clips an 80-point reserved slot. A one-line title stays compact; a long title grows to two lines. If device review finds the title clipped, revise containment again rather than shrinking type.

## 3. Typography, color, and material

### Typography

- Title: system headline, semibold; retain the original conversation wording. No all-bold oversized heading, letter-spacing compression, marquee, or automatic font shrinking.
- Assistant: system footnote, regular weight. Preserve the runtime's canonical name; do not show a model name in its place.
- State: system footnote, regular weight, secondary label color. The small marker carries the signal color; do not color the entire secondary row green.
- The app's conversation-font setting continues to affect conversation content only. System Dynamic Type still affects the header.

### Color

- Title and Back use semantic primary label colors; state and disclosure use readable secondary label colors.
- Reuse the established assistant and attention palette from the [UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md). Do not sample approximate blue/green values from the generated preview or invent a quieter incompatible palette.
- Prefer the established runtime tint for the runtime label only if it meets small-text contrast on the real navigation surface. Otherwise use primary label text, keeping the assistant identifiable by its name. Do not reduce opacity to obtain a pale blue.
- There is only one status marker. Remove the additional blue brand dot and the perpetual execution spinner from this composition.
- Running remains green; waiting for user input remains yellow. Red continues to mean the product's existing unread/new-result signal, not a newly invented Ended or Offline state.

### Material

- Keep system navigation material and native Back treatment on supported systems. Older systems use their native navigation appearance.
- The generated light preview expresses hierarchy; its flat background is not a requirement to disable native glass.
- Do not add a glass card around the title, an outer highlight ring, decorative gradient, or a custom heavy bottom rule.
- Conversation background and the content-hugging activity capsule retain their existing semantic surfaces.
- Dark Mode, Increase Contrast, and Reduce Transparency must remain readable through native semantic appearance. Do not hardcode a white header.

## 4. Content and state rules

### Title

1. Use the current conversation title verbatim, with display-only whitespace normalization.
2. Ordinary sizes: at most two visible lines, truncating at the end of line two if necessary. Never truncate the stored title or rewrite it into an AI-generated short title.
3. Missing title: localized `Untitled session` / `未命名会话`; do not substitute a filesystem path or opaque identifier.
4. The question-history sheet includes the full title as wrapping text in its scrollable content, before the existing question cards. Keep the sheet's own navigation title short. This supplies a discoverable place to read the untruncated title.
5. A title update keeps the header's reserved height stable. It does not reset the conversation or move the user away from the message they are reading.

### Secondary row

**Where the live header is (2026-10-01):** the shipped header is `SessionDetailView.sessionHeaderLabel` (title + assistant name, opens question history). `SessionHeaderTitleView` / `SessionHeaderPresentation` are not mounted anywhere; editing them changes nothing on screen.

**Superseded in part (owner decision 2026-10-01):** Running and Needs reply are no longer shown in the header; the activity cue above the composer owns them (see the [UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md#conversation-polish-2026-10-01)). The header keeps title and assistant name.

The row reads `Assistant   marker State`. Treat the following as proposed presentation, not new server states or a new liveness detector:

| Confirmed condition | English / Simplified Chinese | Marker |
|---|---|---|
| Actively executing | Running / 执行中 | Green |
| Waiting for the person's answer | Needs reply / 等你回复 | Yellow |
| Session alive, confirmed idle | Ready / 就绪 | Neutral |
| Session definitively ended | Ended / 已结束 | Neutral |
| Connecting or reconnecting, execution freshness unavailable | Connecting… / 连接中… | Neutral |
| Disconnected, execution freshness unavailable | Offline / 已断开 | Neutral |
| Connected but execution state not yet confirmed | Updating… / 更新中… | Neutral |

- Resolve execution state from the existing live-conversation source. A process being alive, a socket being connected, or recent text being visible does not by itself mean Running. The open conversation's `live` / attention from watch and metadata must drive the header — do not keep a stale list-row `live=false` that paints Ended while the watch already reports the session alive. Treat keepalive/`hosted` as still live for the header. While connected, a fresh `working` / `waiting` attention signal wins over a stale not-live flag.
- A stale running snapshot must not remain an affirmative live claim after disconnection. While execution freshness is unavailable, show connection/unknown wording in the same status slot; do not append a second network badge.
- A confirmed ended state can remain Ended when viewing historical content offline. Offline does not imply the remote task ended or failed.
- For conflicting fresh execution signals, use the existing authoritative state resolution. If it cannot distinguish the rows above, mark the mapping gap during implementation; do not infer it using timers or invent a new transport protocol in this visual change.
- No blinking, breathing, rotating, or bouncing during normal execution. Static color plus words communicates activity. A screen-content loading indicator may remain where content actually loads.
- State changes update the metadata in place without moving the title, Back, or conversation. Waiting-to-Running must not create or remove a full-width strip in the message area.
- Unknown runtime names remain visible in neutral text. All user-facing fallback/state/accessibility strings have English and Simplified Chinese versions.

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

- Keep the question-history filter: genuine user questions only, oldest to newest; no injected context or relay/system turns.
- Back and heading targets do not overlap. The title group has a minimum 44-point target and a subtle visible pressed response. It has no persistent pill background.
- Use native sheet and navigation transitions. Respect Reduce Motion; do not add overshoot or a title-collapse animation.
- Opening question history must not submit or discard a composer draft. The sheet itself does not autofocus an input. Keyboard dismissal follows the existing modal behavior rather than a new keyboard-height controller.
- The header stays visible during conversation scrolling and keyboard presentation. It does not collapse and expand based on scroll direction.

## 6. Accessibility and adaptation

- VoiceOver order: Back → combined heading button → conversation content. The heading announces the **full** title, assistant, and state, with a localized hint such as `Show questions in this session`. Hide decorative dot/chevron elements from separate accessibility navigation.
- Announce an actionable transition such as Needs reply once; do not announce every streaming refresh or continually interrupt message reading.
- At larger ordinary Dynamic Type sizes, allow the header to grow with its semantic fonts; 80 is a default target, not a fixed frame.
- At accessibility sizes, allow up to three title lines and place the state on a separate metadata line if assistant plus state no longer fits. Retain access to the full title in the sheet and VoiceOver. No font shrinking, overlap, or horizontal scrolling.
- At narrow widths/landscape, preserve safe areas and Back first. Truncate the title rather than clipping controls. State text has priority over optional decoration. If assistant and state do not fit, wrap the state group intact.
- Respect right-to-left layout and mirror directional Back/disclosure symbols where appropriate. Mixed Chinese and Latin title text remains ordinary text, not a code-style font.
- Verify text contrast on both appearances and over scrolled content. State meaning is always available in words, even without color.

## 7. Integration boundaries and feasibility gate

This is a product/layout specification. Header source code has not been audited in this documentation task, and no particular SwiftUI modifier is claimed to satisfy the geometry.

- Preserve native navigation-stack ownership, back gestures, system safe areas, and existing presentation ownership.
- A standard inline navigation bar must not be assumed to fit two title lines plus metadata. Before full implementation, verify that the chosen navigation host can reserve the required height on the supported OS versions and with large text.
- If a fitting native title host cannot provide that space, explicitly revise the containment/design. Do not hide the navigation bar, draw a replacement over the status bar, or overlay a clipped title as a workaround.
- Do not read keyboard frames, add global-window probes, create another window, or compensate with delayed scroll commands for this header.
- Reuse existing session identity, runtime naming, execution-state ownership, question-history filtering and scroll destinations. No new polling, server state machine, model call, or persistent setting is required by the design.
- Changes are confined to the conversation header and the full-title section of its existing question-history sheet. Agent activity requires only boundary-spacing verification; its content and behavior are unchanged.
- The existing UI knowledge base previously described a centered title group with a runtime color dot. This layout replaces those two presentation choices. The matching KB paragraph is updated with this implementation.

## 8. Acceptance contract

Implementation is accepted only after evidence from the affected screen, not from the generated image or installation result.

| Scenario | Required evidence |
|---|---|
| Original screenshot title | Two readable lines when required by actual width; complete assistant/state; no clipped disclosure |
| Short and very long titles | Stable ordinary metadata baseline; truncation only after line two; full title reachable in the sheet |
| Default and accessibility text | Normal page remains compact; large text grows/reflows without overlapping Back or content |
| Light/dark, contrast, transparency | Readable native surfaces; no custom highlight frame or pale unreadable runtime label |
| Running → Needs reply → Running → Ready | Correct words and established signal colors; no spinner or repeated conversation status strip |
| Disconnect/reconnect during execution | No stale affirmative Running claim; title/history stay available; fresh state returns without layout jumps |
| Back, edge swipe, question-history entry | Native navigation works; one sheet per activation; selected question resolves correctly |
| Sheet dismissed without selection | Reading position and draft retained; full title is available even with no questions |
| Keyboard, short transcript, long transcript | Header never covers content; existing keyboard avoidance/following behavior remains intact |
| First activity capsule at rest | Fully visible with one deliberate top gap; stays content-hugging and scrolls with conversation |
| VoiceOver and Reduce Motion | One heading target, full title announcement, non-overlapping controls, no needless motion |

For later implementation: inspect paired-device availability first and use the existing installed app on the available physical iPhone. Do not install a second UI-test app; a simulator capture does not replace this acceptance. Delivery must follow the shared installation/upload process; capture and inspect the header afterward. Record any untestable state separately rather than marking the table passed.

## 9. Basis and evidence limits

- User screenshot and the follow-up request for detailed design: source of the problem statement and requested scope.
- [Product UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md): current state colors, question-history behavior, content-hugging activity, type-setting boundary, and navigation interaction.
- [Mobile UI rework brief](MOBILE_UI_REWORK_BRIEF.md): native composition, compact normal text, and actual-app acceptance.
- [Apple toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): navigation hierarchy, useful titles, and deliberately limited controls.
- [Apple typography](https://developer.apple.com/design/human-interface-guidelines/typography): semantic text, Dynamic Type, and legibility.
- [Apple layout](https://developer.apple.com/design/human-interface-guidelines/layout): adaptation to size and accessibility context.
- [Apple materials](https://developer.apple.com/design/human-interface-guidelines/materials): navigation/control material and content separation.

The reference image is a visual sketch, not an exact pixel specification or a verified iOS rendering. The layout targets, proposed state copy, accessible reflow and navigation-host feasibility remain to be validated on the physical iPhone after implementation.

<!-- 该文档整理/压缩于 2026-09-29 -->
