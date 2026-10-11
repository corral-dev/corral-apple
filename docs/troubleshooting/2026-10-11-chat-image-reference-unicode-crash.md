# Chat image reference Unicode crash

## Evidence and scope

The installed Mac client 0.3.76 (80) crashed twice on 2026-10-11 at 21:34:43 and 21:35:16. Matching arm64 release symbols resolve the main-thread frames to `ChatImageReference.normalize`, `references(in:)`, the image-reference cache and `MessageBubbleView`. The Swift Unicode-scalar assertion is reached through Foundation whitespace trimming.

The parser is shared by iPhone and Mac. Corral owns this image-preview projection; it is not native session-history interpretation and does not belong in SessKit. The TUI does not call this Swift parser.

## Root cause and required behavior

`maskFencedCode` replaces fenced lines with one ASCII space per grapheme cluster. Unicode has variable UTF-8 length, so match indices in the masked copy cannot index the original message. The parser nevertheless slices the original with those indices. A standalone executable using the unchanged source reproduces an out-of-bounds String assertion with a family emoji inside a fenced block followed by `/tmp/result.png`; smaller Unicode cases silently lose references.

Match bare references in the original text and exclude original-string fenced line ranges. Never transfer indices from reconstructed or transformed text. Preserve existing behavior: ignore bare image mentions inside fenced code, retain explicit Markdown/HTML image references, preserve verbatim targets, reading order, deduplication and the per-message cap. Unicode before or inside a fence, CRLF and unterminated fences must remain safe.

## Verification status

Original-source reproduction: failed with SIGTRAP (exit 133). The corrected parser passes all 640 standalone combinations of CJK, emoji, combining marks, family emoji and post-fence prefixes, retaining the exact `/tmp/result.png` reference each time. Regression tests also cover CRLF, multiple/unterminated fences and explicit images inside fences. All 370 portable Core tests and five client-diagnostic tests pass; localization validates all 462 usages. Installed-client acceptance is pending. The exact user message has not been extracted; the symbolicated reports establish the failing parser path, while the minimal fixture establishes the index defect.

Swift string indices follow encoded storage rather than an integer grapheme count; substrings retain their original indices. Reference: [Swift strings and characters](https://docs.swift.org/swift-book/LanguageGuide/StringsAndCharacters.html).
