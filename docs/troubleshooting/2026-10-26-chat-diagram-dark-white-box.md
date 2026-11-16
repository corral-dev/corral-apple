# Chat diagram white box in dark appearance

Symptom: a Mermaid/PlantUML diagram in a dark conversation sits inside a white rectangle; light appearance looks normal. Both the inline attachment and the Diagram sheet can show it.

## Cause

Two platform behaviors were treated as transparent:

- `WKWebView.pdf` exports an opaque print page even when the document and WebView background are transparent; the PDF page is white.
- PDFKit paints an opaque white page behind transparent PDF content; filling the WebView with a dark background does not change that page backing.
- On macOS, converting the sanitized SVG to a vector PDF with `NSImage`/`_NSSVGImageRep` kept text but misrendered complex Mermaid markers (thick black wedges), so it was not a safe replacement.

## Remedy

The production path keeps transparent artwork only for the inline attachment:

1. The renderer serializes its sanitized SVG into a transparent canvas PNG and returns the PNG to Swift.
2. The inline `NSTextAttachment` uses that PNG directly, so it stays transparent in both appearances.
3. The Diagram sheet gets a PDF made from the PNG; before drawing, the PDF page is filled with the resolved light/dark window surface color, and `PDFView.backgroundColor` uses the same color so PDFKit's white backing is never visible.
4. The PNG is cached beside the viewer PDF; cache reads use the PNG for inline rendering, with a PDF thumbnail only as fallback for old or corrupt entries.

The diagram cache key includes renderer version, engine versions, host, appearance and source hash; changing the output format requires a key-version bump so old white-page PDFs are not reused.

## Verification

Mac Debug production chat fixture: two native attachments in light and dark, 11 Mermaid/PlantUML types in both appearances, two unsafe/invalid sources retained as text, source copy preserved, Diagram/Source sheet inspected in both appearances, and a live host-backed image message displayed in a conversation row. Current acceptance: [chat diagram rendering](../design/CHAT_DIAGRAM_RENDERING_DESIGN.md).

Do not "fix" this by forcing a white background, by a private WebKit `drawsBackground` override, or by replacing native text selection with a WebView.

<!-- 该文档整理/压缩于 2026-11-15 -->
