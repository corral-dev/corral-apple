# Chat diagram rendering

Status: implemented in the shared chat surface on 2026-10-26 after the owner requested images, Mermaid and PlantUML; the 2026-10-24 study alone did not implement production rendering. Component and live-host acceptance are recorded below, installed Mac/iPhone acceptance separately, so a Debug fixture is never presented as shipped behavior.

Review the [offline preview](../../design/chat-diagrams/preview.html), [light study](../../design/chat-diagrams/light.png), [dark study](../../design/chat-diagrams/dark.png), [Mermaid study](../../design/chat-diagrams/mermaid.png), [corrected mindmap](../../design/chat-diagrams/mindmap.png) and [study evidence](../../design/chat-diagrams/evidence.json). The preview contains real pre-rendered engine output, source text, appearance/sample/text-size controls and a drawing/source viewer; its study controls are outside the proposed chat UI.

## Delivery implementation (2026-10-26)

The production chat surface recognizes fenced Mermaid/PlantUML and safe whole-message diagram source in `ChatMarkdown`, stores candidates with the parsed message, and renders them as native `NSTextAttachment`s in the existing selectable text network. Pinned Mermaid 12.0.0, PlantUML 1.2026.8, DOMPurify 3.4.16 and C4 2.13.0 assets are bundled under `Shared/Resources/ChatDiagrams`; rendering is local, serialized and credential-free. Invalid or unsafe source remains ordinary selectable source.

The inline attachment is a transparent canvas PNG rendered from the sanitized SVG; on macOS the same drawing also gets a PDF page for the native viewer. Because PDFKit paints an opaque white page behind transparent content and WebKit's print PDF paper is opaque, the viewer PDF uses the resolved light/dark window surface as page color and the viewer uses the same surface color — an implementation constraint, not a claim that either framework can export a transparent page through public API. The original source remains the only copy/selection representation.

Mac row identity includes the image-loader identity/capability and a per-message media revision, so a table realized before the loader exists refreshes without discarding row anchors; the iPhone observes the same store and updates the native attachment directly. Drawings are cached in memory and on disk by host, engine versions, appearance and source hash, with the PNG cache separate from the viewer PDF so a cached inline drawing stays transparent.

Component acceptance (Mac Debug, production `ChatView`/table): both light and dark fixtures produced two native attachments, preserved adjacent selectable text and source copy, rendered 11 Mermaid/PlantUML types in both appearances, and rejected two unsafe/invalid sources. The live host-backed fixture loaded the cited image from this session's history (`imagesLoaded=1`, 80 messages) and displayed it in a conversation row; the PDF viewer and source picker were captured in both appearances.

Installed delivery (2026-10-26): Mac 0.3.155 (159) at `/Applications/Corral.app` with Developer ID signature and executable hash verified, local transport ready with data attached, no Debug copy left running. iPhone 1.0.199 (210) installed and launched on the paired iPhone; `ios-deliver` verified the install, uploaded release 364 to the [install shelf](the private install shelf), and the device reports the same version/build. The installed Mac window was captured at the session list — opening the conversation, scrolling to the cited image and the Diagram/Source sheet still needs the owner's click because pointer automation is prohibited; the iPhone screen was captured at its existing conversation, and a diagram-bearing message opened by touch remains a physical acceptance step. No gesture or pinch-zoom performance is claimed.

### Cancellation and revisiting (owner follow-up, 2026-10-27)

Leaving a conversation, replacing a streaming revision, backgrounding or losing the last consumer cancels presentation work, not the validity of the diagram source. Such cancellation must not add the source key to the invalid-source cache, so revisiting the same drawing renders normally. Keep engine rejection/deadline failures distinct from consumer cancellation. Identical requests may join existing active/queued work even when the waiting queue is full; only new distinct work is subject to the queue bound. Verify cancellation followed by same-source rendering through the real local engine, not a mock or a successful build alone.

Acceptance (production `ChatView`/`ChatDiagramStore`, Mac Debug): cancelling a unique source before first paint left zero attachments and did not enter the invalid-source cache; revisiting the message rendered exactly one diagram; clearing the host removed its cache entry. The same run's 22-sample matrix (11 diagram forms in light and dark) rendered and both unsafe/invalid sources stayed rejected. iPhone screenshots of the real `ChatView` show Mermaid flowcharts and PlantUML sequence diagrams rendering after the first engine load; the phone's table acceptance is owned by [the mobile table-to-list fallback](../UI_DESIGN_KNOWLEDGE_BASE.md#mobile-table-to-list-fallback-owner-correction-2026-10-27).

Installed delivery (2026-10-27): Mac 0.3.158 (162) at `/Applications/Corral.app` from source `ce8a84d` — Developer ID signed, executable SHA-256 `a4cb2b16…9bd8d0a`, the only Corral GUI process and online to the host. iPhone 1.0.204 (215) was signed from `ce8a84d`, installed on the paired iPad and uploaded as AppShelf release 369 at the [install shelf](the private install shelf); the paired iPhone was unavailable, so its direct installation is owner-side. Physical screenshot acceptance of the updated chat remains with the owner because the iPad was locked; composition evidence used the production components on iOS 27 and macOS.

## Product requirements

The owner requested Mermaid and PlantUML rendering in Corral clients on 2026-10-24 and explicitly requested implementation of images and both formats on 2026-10-26. Render actual diagrams, not only syntax-highlighted source, and finish with a reply containing a Markdown image and both diagram fences so the owner can inspect the real conversation. This document owns Corral's adaptation; performance targets remain distinct from measured results.

- Render diagrams in iPhone and native Mac chat content; preserve the assistant's original terminal output in terminal mode and the TUI.
- Recognize explicit diagram fences and safely recognize unlabelled complete diagram source without misclassifying ordinary prose.
- Fit Corral's typography, Pine palette and native reading surfaces in light and dark, preserving meaningful author-specified styling.
- Make first viewing responsive, reuse completed drawings and retain offline readability; no first-use network download of drawing engines.
- Preserve original messages and readable source on failure. Historical messages stay read-only; presentation does not modify native histories, message content or the wire protocol.
- Handle incomplete streaming source, narrow panes, large text, selection/copy and asynchronous height changes without breaking reading continuity.
- Verify the design with real engine output, then verify implementation separately through both installed clients — a design preview is not an installed-app pass.

## Reference requirements

The reviewed WaterfallNotes requirements are in `~/Codes/WaterfallNotes/web/docs/TYPOGRAPHY.md` (Diagram rendering) and `~/Codes/WaterfallNotes/web/docs/VISUAL_DESIGN.md` (Diagrams in the text sheet). The 2026-09-28 source conversations establish the priorities: visual integration, safe recognition, a real demo, and no phone waiting over ten seconds for engine downloads. WaterfallNotes' paper-slip decoration, editable-note behavior and web-service deployment are product-specific.

## User experience

Reading order stays text → diagram → text within the original message. Both user and assistant messages can contain diagrams, each retaining its existing bubble, alignment and text-size rules; multiple diagrams stay in source order. Conversation list snippets, search indexing, notifications, tool-output details, the composer and original terminal modes keep their current text projections.

| State | Presentation and interaction |
| --- | --- |
| Cached drawing | Display its known geometry with the first message layout; do not briefly show source first. |
| First render | Keep the intact code/source visible while drawing and replace only that block when ready. No blank loading rectangle, animation, toast or persistent language label. |
| Ready | Diagram sits on the current message surface: no inner card, frame, shadow, permanent toolbar or glass. |
| Incomplete or invalid | Keep the ordinary selectable source; never insert an engine error picture, erase the block or interrupt the rest of the message. |
| Open drawing | Activate the diagram to open a native sheet with a PDFKit viewer, a native Diagram/Source picker and an explicit Done control; opening is user-initiated. |
| View/copy source | Native context-menu and accessible actions expose the original source; source view is selectable and read-only. |

### Width, height and the WaterfallNotes difference

Ordinary diagrams start at the current message font metrics and fit their column; width changes scale the existing vector/preview instead of re-running the engine. Long diagrams follow the existing message-height/inner-scrolling contract rather than inventing a new collapsed-message state.

For a drawing that cannot fit at a readable scale, show a complete inline overview and provide the same open action as other inline images; in the native viewer PDFKit owns zooming and panning at natural scale, and the overview does not count as readable inspection.

This deliberately adapts WaterfallNotes' horizontal scrolling inside an SVG block: Corral's Mac conversation uses a TextKit 1 selection network and iPhone messages one selectable native text view, so a plain image attachment has no independent horizontal scroller. The proposal preserves those native selection paths and uses an explicit viewer for large drawings; it does not promise inline horizontal scrolling, switch the conversation to WebKit or migrate Mac selection to TextKit 2. If inline horizontal scrolling becomes an explicit requirement, reopen this interaction/integration decision before coding.

Keep message reading position, selection, drafts and keyboard state when a drawing appears or its appearance changes. When the reader follows the latest message use the existing latest-content path; when reading history, retain the message/block anchor and offset. Never refocus the composer, open a window or force a bottom jump because rendering completed.

## Visual language

Use Corral's Pine theme and system typography from `Shared/UI/Design/Palette.swift` and `Typography.swift`. WaterfallNotes contributes a method for mapping engine styles to product roles; its stationery, tape, paper shadows and six slip tints do not transfer.

| Diagram role | Corral treatment |
| --- | --- |
| Background | Transparent on the current message surface; resolve the actual background for contrast and export. |
| Labels | Neutral foreground; node labels start at `.bubbleBody`, relationships use the existing smaller text role. Mac baseline 14 pt, iPhone Dynamic Type-scaled 17 pt before the session text-size preference. |
| Nodes | Quiet green-tinted content fill, restrained edge, product radius family. Authored circles, decisions, databases and UML shapes retain semantic geometry. |
| Relationships | Neutral green-grey ink and clear arrowheads; dashed relationships retain their meaning. |
| Groups | Faint neutral-green fill, clear group title, restrained boundary; avoid nesting cards around the diagram. |
| Notes | Existing warm auxiliary surface with its matching foreground; warm yellow is not a general node or message fill. |
| Multi-series charts | Small categorical palette coordinated with Pine; never reuse assistant identity colors or running/waiting/unread colors as arbitrary series meanings. |
| Explicit author styling | Keep safe per-element colors, line types, labels and shapes. A diagram-wide theme/font directive cannot override the application appearance/security configuration, and an explicit semantic color is never silently recolored. |

The study uses concrete light/dark samples, not final named-color assets; production resolves semantic colors under the actual platform appearance, message role and Increase Contrast state, and those resolved values participate in rendering identity. It must not rely on a CSS color name or the palette's green label to establish contrast.

Mermaid uses `base` plus explicit role values, geometry and typography, with each supported type checked. Because Mermaid documents both global and per-diagram theme/look precedence, protecting only a top-level theme is insufficient: strip disallowed configuration overrides from render input, including nested per-type overrides, while retaining original source ([Mermaid theming](https://mermaid.js.org/config/theming.html)). Study correction: Mermaid 12.0.0's mindmap root still used black text on a derived green in dark appearance despite the generic foreground configuration, so the preview explicitly maps its scoped `.section-root` fill/foreground and branch rules to the intended roles — verify per-type output, including root labels, rather than treating a themed flowchart as proof for every diagram. The study has no authored color overrides; their precedence remains an implementation fixture.

PlantUML uses equivalent skin/style values, applying Corral defaults before user element-style declarations so safe author styling wins. For bundled C4, apply the Corral element/boundary/relationship defaults after the library include and before authored `Update*Style` declarations, using the same neutral ink and quiet fills as other diagrams.

Drawings have no entrance or repeating animation; sheet transitions stay system-owned, and Reduce Motion/Reduce Transparency follow existing native client behavior.

## Recognition and source preservation

Reuse Foundation's bounded native Markdown parse with source positions; the [shared Swift guidance](~/Codes/_standards/swift.md#markdown-source-positions-and-streaming-boundaries) owns the public API and unfinished-fence caveat. The implementation adds diagram classification to the existing parsed-message result, not a second full-message parse in every view body.

| Input | Classification |
| --- | --- |
| Fence tagged `mermaid` / `mmd` | Explicit Mermaid; never reinterpret as PlantUML. |
| Fence tagged `plantuml` / `puml` / `uml` | Explicit PlantUML; missing `@startuml`/`@enduml` may be added to render input only. |
| Unlabelled fence | Candidate only if the whole block matches a registered Mermaid opening or paired PlantUML start/end marker and the pinned engine accepts it. |
| Whole message containing only diagram source | Same content checks; no leading/trailing prose may be absorbed as a graph. |
| Other language fence, inline code, quoted example | Retain normal text/code presentation; a nested block quote is not auto-rendered. |
| Diagram inside a list | Use the native block/list context and indentation; do not detect a new top-level block with a regex over unrelated text. |
| Mixed prose and an unfenced Mermaid fragment | Ordinary Markdown — Mermaid has no reliable source end marker in mixed text. |

Register only syntax supported by the pinned engines, independent of Corral's five-runtime allowlist; an unsupported diagram type retains its source. For free-text Mermaid types (mindmap, timeline, journey, kanban, treemap) an inferred candidate also needs a nonblank indented outline after its opening, so a prose note starting with `timeline` stays prose; explicit language labels need no such heuristic.

Store both original source range/fence and the engine-input projection. Unicode, CRLF, longer backtick/tilde fences, nested lists and escaped fence-like text need fixtures. Engine-specific wrapper insertion, blocked directives and style defaults affect only render input; never write that projection into `RichMessage.text`, a history file, a transcript export or the source clipboard representation.

### Streaming and asynchronous ownership

`RichMessage` carries no per-message `isFinal` field; diagram rendering must not invent one from a timeout or the activity footer, and this proposal needs no wire extension.

- A fenced block renders only after a matching closing delimiter exists — the native Markdown parser accepts an unclosed fence, so code-block intent alone is insufficient.
- A complete paired PlantUML source can be drawn as soon as its pair arrives, without waiting for the whole assistant turn.
- A bare whole-message Mermaid candidate is a progressive preview of current source, not proof of completion: use a cancellable 500 ms quiet interval followed by full-source engine validation, cancel eligibility on a new revision, and keep source until the current candidate succeeds. Historical candidates need no artificial debounce.
- Identify a block by host identity, canonical session key, history generation, message sequence, block position and source hash; every returned drawing, failure and loading cleanup rechecks that identity and the renderer generation.
- Reusing a cell, replacing history, removing a diagram, changing hosts, cancelling pairing or stopping the view invalidates pending application; an identical later message does not inherit another message's presentation state.
- Queue once per content/style key, not once per token, geometry callback or view body evaluation; a stable earlier diagram in a streaming message is not redrawn when prose below changes.

## Rendering architecture

The shipped inline attachment is a transparent canvas PNG, and the Diagram sheet uses a raster PDF of that PNG over the resolved surface color. An earlier vector-PDF proposal was not used: WebKit's print PDF and PDFKit's page backing are opaque, and `NSImage`'s SVG-to-PDF path misrendered complex Mermaid markers.

The first implementation bundles Mermaid, PlantUML's JavaScript engine, its Graphviz runtime and the permitted C4 bundle inside both apps; rendering stays on the device with no new JVM, localhost daemon, cloud service, relay message or dependency on a reachable paired host. A host/server renderer remains a future measured alternative only if the physical-phone budget below fails — never an automatic fallback or a reason to send source to a public service.

Local reference assets total about 10.5 MiB of raw JavaScript: 5,457,829 bytes for Mermaid's minified entry/module family (105 files), 5,393,006 bytes for PlantUML plus Graphviz and 181,698 bytes for C4. That is a one-time bundled-resource cost, not a measured IPA/DMG download increase or native memory footprint; the production manifest, packaging compression and renderer-process peak still need measurement.

```text
Original message → bounded native Markdown result + diagram ranges
                 → host-scoped drawing cache
                 → one lazy, serial WebKit renderer on a cache miss
                 → validated SVG + native PDF + sized inline bitmap
                 → native text attachment / native PDF viewer
```

### Renderer lifecycle and resource limits

One process-wide renderer coordinator owns at most one active `WKWebView`; ordinary chat rows retain no WebViews. Create it when an eligible visible diagram needs drawing, load only the required engine, serialize draw calls because PlantUML shares rendering state, prioritize visible blocks over a single nearby prefetch window, coalesce identical jobs, and cap the waiting queue at 16 while retaining source for deferred work.

Initial bounds (tuning limits to verify on supported devices, not established performance): 20,000 source characters, 500 Mermaid edges, 10 seconds per draw/export operation, 4 MiB SVG/PDF output per result, 4 million pixels per inline bitmap. Oversized input, nonfinite/invalid dimensions and exceeded limits retain source.

Cancel a waiting job immediately. For an active engine, invalidate native result ownership — cooperative Swift cancellation cannot prove JavaScript stopped. On native watchdog expiry, retire that WebView/context, reject every callback from its generation and create a replacement only for a different eligible request; never repeatedly retry the same failing source. Release the renderer after 60 idle seconds and on background/memory pressure, verifying WebKit-process resource release rather than assuming a deallocated Swift reference proves it.

### Output and native integration

Render in a fixed local document, wait for its actual engine/font promises, validate finite DOM dimensions, sanitize the SVG, then produce a bounded PDF with `WKWebView.createPDF`/`pdf(configuration:)`. Static export must not wait for display animation frames ([WebKit export readiness](~/Codes/_standards/workspace-docs/swift-docs/webkit-integration.md#offscreen-document-rendering-readiness)). Retain the PDF as vector source and rasterize only the actual inline size/display scale; width changes reuse vector output. Large diagrams open `PDFView` through a standard SwiftUI sheet. Do not promise vector rendering from `UIImage(data: pdfData)` or private framework descendants.

Use public `NSTextAttachment` image/bounds APIs inside the existing `UITextView`/`NSTextView` flow. Mac keeps its shared `NSTextStorage`/layout-manager network and stable message identity; drawing revisions participate in the row-content and height-cache keys, update only the affected native text range and reuse the existing deferred row-height correction/reading-anchor path — never invalidate every row when one drawing finishes. iPhone applies attachment changes outside `sizeThatFits`, with the existing detached sizing contract authoritative.

Selection/copy is a prerequisite, not optional polish. A selected attachment maps back to its original block; plain-text Copy spanning it expands that position to the source, including the original fence where applicable, while adjacent rendered prose keeps its existing copy behavior. Preserve native RTF/image representations where supported; customize menus through public text-view copy/export hooks rather than replacing the system edit menu. Verify selection endpoints across asynchronous replacement and source/drawing toggles. If the attachment cannot preserve these paths on either platform, resolve that integration before shipping instead of splitting a message into disconnected selectable views.

### Public API and inspected references

| Reference | Inspected behavior to reuse | Adaptation / limit |
| --- | --- | --- |
| `Shared/UI/Chat/ChatMarkdown.swift` | Bounded cached native Markdown parsing and source text | Add source ranges/classification to its cached result; retain the large-message safety limit. |
| `MessageBubbleView.swift`, `SelectableAttributedText.swift` | Native selection, typography, iPhone inner-scroll cap and deferred sizing | Put drawings in native text flow; do not duplicate the body as HTML. |
| `MacConversationTextDocument.swift`, `MacConversationTable.swift` | Cross-message native selection, changed-range updates, row identity and deferred height corrections | Drawing revisions invalidate precisely the affected attachment/row and preserve the reading anchor. |
| `MessageImagesView.swift` | Known cached geometry before first layout and explicit native media opening | Reuse that behavior; diagram media is generated locally, with source-copy mapping and a PDF viewer. |
| WaterfallNotes `src/md/diagram/detect.ts`, `render.ts`, `Diagram.tsx`, `styles/diagram.css` | Conservative classification, serialized engine calls, C4 restyling and separate render-input projection | Adapt rules and API usage; do not copy its React editor, backend/auth service, CSS skin or palette. |
| PlantUML `@plantuml/core@1.2026.8/GITHUB_INTEGRATION.md` and example HTML | `renderToString` callback, Graphviz requirement and shared-state serialization | Reuse one local engine context; the upstream iframe-per-diagram example is not the native app's lifecycle. |

The inspected Xcode 27.2 beta 2 SDK declares these APIs within Corral's iOS 17 / macOS 26 deployment scope; the study runtime is macOS 27.2, which does not establish oldest-OS behavior.

- [WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler) supplies allowlisted bundle resources; the study loaded both engines and C4 through a custom local scheme, so no product HTTP listener is needed.
- [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview) provides `callAsyncJavaScript` and PDF export: typed arguments carry source rather than interpolating it into code, and a nonpersistent website data store separates rendering from paired-host credentials and cookies.
- [NSTextAttachment](https://developer.apple.com/documentation/uikit/nstextattachment) provides the inline image/bounds primitive; its production selection, click and copy integration remained unverified at study time.
- [PDFView](https://developer.apple.com/documentation/pdfkit/pdfview) provides the native inspection container; native sheet/picker/toolbar APIs retain standard dismissal and accessibility behavior, and the HTML preview's dialog is only a study control.

## Cache, privacy and failure containment

Keep a bounded process memory cache (initial 32 MiB decoded-image cost) and a derived disk cache (initial 64 MiB LRU across hosts) under `AppStorageLocation.cachesDirectory/diagrams/`, so Mac uses its existing XDG/app root and iPhone its sandbox cache location. Files are derived, excluded from backup where applicable and safe to evict; eviction never removes original conversation content.

Partition by the paired host's stable cryptographic identity, not name/address. The vector key includes engine versions, rendering-policy/skin version, language, source hash, resolved font metrics, appearance, contrast and any surface-dependent colors; the bitmap key adds vector identity, actual bounds and display scale. Width changes reuse vectors; content/style/policy changes invalidate drawings; appearance changes never overwrite an author-styled source.

The message/block ownership map includes session/history generation, so removing cached history drops its unreferenced drawing associations. Unpairing cancels that host's jobs and clears its memory/disk drawings immediately, and a late result cannot recreate an unpaired namespace. Coalescing is host-scoped and never leaks a drawing to another paired host. Sources stay only in existing message storage; diagnostic logs record bounded type/timing/failure categories, never source, labels, SVG, credentials or paired-host addresses.

Diagram input is untrusted even from an assistant. Mermaid uses `securityLevel: strict`, a locked `secure` policy and filtered render-only configuration. PlantUML permits only bundled standard-library includes: network/filesystem includes, imports, environment/file/URL reads, remote themes, links and external images cannot reach the renderer, and a directive requiring blocked external content falls back to source rather than presenting a misleading incomplete diagram. Author source remains intact. [Mermaid security configuration](https://mermaid.js.org/config/schema-docs/config.html#securitylevel).

The resource handler serves an exact packaged manifest with canonicalized paths, never arbitrary device files, plus a restrictive content security policy and native navigation/request restrictions: no external connections, popups, local-file access or bridge exposure beyond render/export operations. Sanitize parsed SVG before PDF export (scripts/events, external hrefs/URLs, unsafe styles and elements) and keep CSS scoped to that drawing. `foreignObject` may carry only the tightly constrained label content the pinned engine requires, otherwise fail safely. The study's fixed trusted fixtures are not an adversarial-input test.

## Performance targets and observed study

Proposed acceptance budgets, measured separately from native app launch:

| Path | Target |
| --- | --- |
| Cached inline drawing | Present with first message layout; add no synchronous engine work. |
| Typical cold first drawing | Within 1 second for a modest flow/sequence diagram on the test phone; report engine load, drawing, PDF and native placement separately. |
| Warm drawing after a completed block | Within 250 ms for the same modest fixture; C4/large layouts are a separate workload. |
| Scrolling / resizing / session switch | Preserve existing main-thread/selection/reading contracts: no waiting for a renderer before showing text and no engine execution on width changes. |
| Background / no diagrams | No renderer before first use and no periodic redraw/poll timer; verify idle CPU and WebKit footprint, including after the idle release. |

The Mac study rendered Mermaid flowchart, sequence, class and Chinese mindmap plus PlantUML sequence, Chinese activity, class and C4 in both appearances: 16/16 returned drawings, and local-scheme runs also returned all 16. After correcting the mindmap style and removing a stalled animation-frame readiness wait, the final run completed with the temporary HTTP server stopped — all 16 drawings exported to PDF and PDFKit reopened them with expected labels, including Chinese (PDF text normalization/order differs from source, so it is not the source-copy contract).

The initial Mac HTTP-loopback study measured engine calls after their scripts loaded: Mermaid 10–265 ms, ordinary PlantUML 21–167 ms, C4 634–815 ms. These are individual synthetic samples in a separate native harness, not percentiles, cold-engine startup, iPhone timings, installed-client performance or permission to relax the existing conversation budget.

`Mermaid 12.0.0` and `@plantuml/core 1.2026.8` were the locally inspected study versions, not a claim that they are the latest production choices. Their package/license files state MIT; inspect and pin the selected production artifacts, Graphviz and bundled C4 notices, lock their complete checksums and add actual distributed components to `THIRD_PARTY_NOTICES.md`. The [official PlantUML JavaScript project](https://github.com/plantuml/plantuml-core) establishes that the browser engine does not require a JVM; the exact redistributed artifact is the licensing authority.

Captured with the window-screenshot skill: PlantUML sequence in light/dark at Mac 640 pt and a simulated 390 pt reading column, Mermaid flow in light, and the corrected Chinese mindmap in dark. These are fresh screenshots of a separate native WebKit study window showing product-color treatment and geometry only; the installed Mac app was also captured without changing state and showed an empty conversation, so it does not verify a chat renderer. No diagram feature was installed, no physical iPhone screen was exercised and no production user interaction passed that turn.

Private raw study material: `~/.config/corral/development/chat-diagrams-20261024/` (Foundation source-position probe, native Swift/WebKit probes, exact fixture/engine data, generated SVG/PDF outputs, PDF label readback). Public-safe review output lives in `design/chat-diagrams/` with synthetic messages only and no bundled engines; the offline preview carries the exact fixture sources and study palette values for reproduction.

## Implementation boundaries and acceptance

This is Corral presentation ownership: SessKit's native history interpretation, completion evidence and normalized source are unchanged, no new diagram parsing belongs in `cli/scan`, no transport-side rendering is added and no raw-history repair is implied.

Implement in bounded increments while delivering both Apple clients together when shared production UI changes:

1. Extend the bounded parsed-message result with source ranges, diagram classification and deterministic render ownership; test normalization and streaming boundaries without WebKit.
2. Bundle pinned resources; implement the serial renderer, hard failure containment and host-scoped cache. Verify ordinary/invalid/hostile input, offline behavior, cancellation, unpair cleanup and lifecycle/resource limits through the native harness.
3. Prove native attachment selection/copy/activation on iPhone and Mac before enabling diagrams in chat, covering mixed prose, lists, tables, two diagrams, source fallback and original clipboard content.
4. Integrate drawing revisions, exact geometry and existing reading-anchor recovery; verify async insertion while reading old messages, following latest, changing text size/appearance and switching chat/terminal or sessions.
5. Run complete affected compiler/analyzer/tests with full diagnostics; install/release the reproducible shared change on both clients and verify the actual changed screen. Phone unavailability is a reported acceptance limit with the existing delivery fallback, not a reason to claim a pass.

| Acceptance group | Required evidence before calling the feature complete |
| --- | --- |
| Recognition | Label aliases; explicit-language precedence; unlabelled/whole-message candidates; prose beginning `timeline`; inline/quoted examples; nested lists; CRLF/CJK/emoji; longer/nested/unclosed fences; multiple diagrams. |
| Rendering | Flow, sequence, class/state/ER, mindmap, pie/gantt and representative PlantUML activity/class/component/C4; unsupported syntax and blocked includes preserve source; author styles and per-type theme override containment. |
| Native reading | First and cached display; native selection/copy across diagram boundaries and multiple messages; reading position under height changes; iPhone bubble cap; Mac four-pane resize and 80/100/150% zoom; large Dynamic Type and safe areas. |
| Viewing | Native open/close, keyboard/Esc where appropriate, source picker/copy, pinch/trackpad zoom and pan, accessible labels/actions, increased contrast, Reduce Motion and Reduce Transparency. |
| Ownership | Old renderer callback, reused cell, replaced message, history generation change, host switch, cancelled pairing, background, memory pressure and deadline/context recovery. |
| Privacy / resources | No external request or raw-source diagnostics; bounded queue/cache/output; no renderer for text-only use; idle WebKit cleanup; eviction retains original messages. |
| Cross-client boundary | iPhone chat and Mac chat render through their installed native hosts; iPhone/Mac terminal and TUI keep original assistant output and have no Corral transcript diagram renderer to accept. |

The study validates a concrete design and the local engine/PDF route. Native attachment/copy behavior, physical-phone performance, minimum-OS compatibility, hostile-input containment and complete installed-client acceptance remain implementation gates.

<!-- 该文档整理/压缩于 2026-11-15 -->
