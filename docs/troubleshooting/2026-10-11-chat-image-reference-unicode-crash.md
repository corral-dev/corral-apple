# Chat image reference Unicode crash

## Evidence and scope

The installed Mac client 0.3.76 (80) crashed at 21:34:43 and 21:35:16 on 2026-10-11; a third 21:45 report has the identical exception and app offsets. The owner confirms the trigger was selecting a sidebar session. Matching arm64 release symbols resolve the main-thread frames to `ChatImageReference.normalize`, `references(in:)`, the image-reference cache and `MessageBubbleView`. The Swift Unicode-scalar assertion is reached through Foundation whitespace trimming.

The parser is shared by iPhone and Mac. Corral owns this image-preview projection; it is not native session-history interpretation and does not belong in SessKit. The TUI does not call this Swift parser.

## Root cause and required behavior

`maskFencedCode` replaces fenced lines with one ASCII space per grapheme cluster. Unicode has variable UTF-8 length, so match indices in the masked copy cannot index the original message. The parser nevertheless slices the original with those indices. A standalone executable using the unchanged source reproduces an out-of-bounds String assertion with a family emoji inside a fenced block followed by `/tmp/result.png`; smaller Unicode cases silently lose references.

Match bare references in the original text and exclude original-string fenced line ranges. Never transfer indices from reconstructed or transformed text. Preserve existing behavior: ignore bare image mentions inside fenced code, retain explicit Markdown/HTML image references, preserve verbatim targets, reading order, deduplication and the per-message cap. Unicode before or inside a fence, CRLF and unterminated fences must remain safe.

## Verification and delivery

- Original-source fixture: SIGTRAP (exit 133). Corrected Debug and optimized Release fixtures: all 640 Unicode combinations retain the exact image path. Three regression tests also cover CRLF, multiple/unterminated fences and explicit images inside fences.
- All 370 portable Core tests, five diagnostic-tool tests and 462 localization usages pass. All 1124 locally cached messages parse without a crash; none contains both a fence and an image extension, so the cached corpus cannot reproduce the triggering message.
- Mac 0.3.77 (81), source `6925b41`, is installed. Its executable hash matches the prepared universal Developer ID artifact. The active installed client reports ready local transport with data attached, and the actual main window was captured and inspected. A later capture of that same installed Release PID shows the owner-selected current crash-investigation conversation with rendered messages and composer, while the client remains connected; this verifies a real installed conversation opening, but does not identify the originally crashing session.
- The same-source Debug client completes 24 real-host workspace-open/presentation checks across one, two and four panes, with visible conversation timelines every time and an inspected conversation-window screenshot. Debug is closed afterwards and only the installed Release remains. This is automated application-action acceptance, not a physical pointer click on the owner's unidentified session.
- iPhone 1.0.146 (156) is installed, launched and independently uploaded to the private install shelf. Device app metadata confirms its market/build versions. Its real Machines screen was captured and inspected; the affected phone conversation was not opened, so no phone conversation acceptance is claimed.
- TUI: no matching Swift image-parser implementation; no TUI change is needed for this root cause.

The exact user message has not been extracted. The symbolicated reports establish the failing parser path, while the minimal fixture establishes the index defect. The older sidebar-native inspection produced no completion receipt and left the conversation empty; it is not a successful check. The existing workspace-open inspector supplied the subsequent real-host evidence. Follow-up: the native selection inspector should report a missing native table/window explicitly instead of silently returning; this task does not change that inspection tool.

The fresh universal Mac and generic-device iPhone Release logs retain only the individually assessed native Markdown, capture-queue and trait-callback diagnostics in [compiler diagnostics](../PERFORMANCE_KNOWLEDGE_BASE.md#new-session-delivery-diagnostic-review). The changed parser introduces no diagnostic. The Mac Debug build introduces none either. Complete logs and delivery receipts remain private.

Swift indices follow encoded storage rather than integer grapheme counts; substrings retain their original indices. Reference: [Swift strings and characters](https://docs.swift.org/swift-book/LanguageGuide/StringsAndCharacters.html).

The signed Mac app and DMG have accepted notarization submissions; download/update publication runs through the maintained detached pipeline. Its first tag push classified the private source repository as public because background environment filtering removed the authentication token. Authenticated visibility reports `private=True`; pushing the exact tag through the authenticated hook passes, and the publication resumption reads the hook's token from Keychain in-process. No gate bypass, warning suppression or history rewrite is used. Public export is separately sanitized and scanned with the public profile.

<!-- 该文档整理/压缩于 2026-10-20 -->
