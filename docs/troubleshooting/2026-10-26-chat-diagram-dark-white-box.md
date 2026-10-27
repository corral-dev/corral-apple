# Chat diagram white box in dark appearance

Symptom: a Mermaid/PlantUML diagram in a dark conversation sits inside a white rectangle; light appearance looks normal. The inline attachment and the Diagram sheet may both show it.

## Cause

Two independent platform behaviors were treated as transparent:

- `WKWebView.pdf` exports an opaque print page even when the document and WebView background are transparent. The PDF page is white.
- PDFKit paints an opaque white page behind transparent PDF content. Filling the WebView with a dark background does not change that page backing.
- On macOS, using `NSImage`/`_NSSVGImageRep` to convert the sanitized SVG to a vector PDF kept text but misrendered complex Mermaid markers (thick black wedges), so it was not a safe replacement.

## Remedy

The production path keeps the transparent artwork only for the inline attachment:

1. The renderer serializes its sanitized SVG into a transparent canvas PNG and returns the PNG to Swift.
2. The inline `NSTextAttachment` uses that PNG directly. It stays transparent in both appearances.
3. The Diagram sheet gets a PDF made from the PNG. Before drawing, the PDF page is filled with the resolved light/dark window surface color. `PDFView.backgroundColor` uses the same surface color, so PDFKit's white backing is never visible.
4. The PNG is cached beside the viewer PDF. Reading the cache uses the PNG for inline rendering; a PDF thumbnail is only a fallback for old/corrupt cache entries.

The diagram cache key includes the renderer version, engine versions, host, appearance and source hash. Changing this output format requires a key-version bump so old white-page PDFs are not reused.

## Verification

Mac Debug production chat fixture: two native attachments in light and dark, 11 Mermaid/PlantUML types rendered in both appearances, two unsafe/invalid sources retained as text, source copy preserved, Diagram/Source sheet inspected in both appearances, and a live host-backed image message displayed in a conversation row. See [chat diagram rendering](../design/CHAT_DIAGRAM_RENDERING_DESIGN.md) for current acceptance.

Do not "fix" this by forcing a white background, by using a private WebKit `drawsBackground` override, or by replacing native text selection with a WebView.
