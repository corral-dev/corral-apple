import CryptoKit
import PDFKit
import WebKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class ChatDiagramDrawing: NSObject {
    let pdf: Data
    /// Original transparent canvas bitmap; the PDF page carries the viewer
    /// surface color so PDFKit never paints a white page behind a dark drawing.
    let png: Data?
    let size: CGSize
    let image: PlatformImage

    init?(pdf: Data, size: CGSize, image: PlatformImage? = nil, png: Data? = nil) {
        guard pdf.count <= 4 * 1024 * 1024, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let document = PDFDocument(data: pdf), let page = document.page(at: 0) else { return nil }
        self.pdf = pdf
        self.png = png
        self.size = size
        let factor = min(2, sqrt(4_000_000 / (size.width * size.height)))
        self.image = image ?? page.thumbnail(
            of: CGSize(width: size.width * factor, height: size.height * factor), for: .mediaBox
        )
    }

    /// The canvas bitmap keeps its transparent background inline. The viewer
    /// PDF paints the matching light/dark surface because PDFKit paints opaque
    /// white paper behind a transparent page. WebKit's print PDF is only a
    /// last-resort fallback for the same reason.
    static func make(png: Data?, fallbackPDF: Data?, size: CGSize, dark: Bool) -> ChatDiagramDrawing? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let inline = png.flatMap { PlatformImage(data: $0) }
        var pdf: Data?
        if let inline { pdf = rasterPDF(image: inline, size: size, dark: dark) }
        if pdf == nil { pdf = fallbackPDF }
        guard let pdf else { return nil }
        return ChatDiagramDrawing(pdf: pdf, size: size, image: inline, png: png)
    }

    private static func rasterPDF(image: PlatformImage, size: CGSize, dark: Bool) -> Data? {
        guard let cgImage = image.corralCGImage else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        // PDFKit paints an opaque white page behind transparent PDF content.
        // Match the viewer surface so a dark drawing never sits in a white box.
        context.setFillColor(platformSurfaceColor(dark: dark).cgColor)
        context.fill(box)
        context.draw(cgImage, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func platformSurfaceColor(dark: Bool) -> PlatformColor {
        #if canImport(UIKit)
        return UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        #else
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
        var resolved = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
        }
        return resolved
        #endif
    }
}

/// One lazy, serial, credential-free browser for the process. Native deadlines
/// retire the JS context, not just its Swift task, and release every waiter.
@MainActor
final class ChatDiagramRenderer: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    static let shared = ChatDiagramRenderer()
    private struct Job {
        let key: String
        let host: String
        let block: ChatDiagramBlock
        let dark: Bool
        var waiters: [UUID: CheckedContinuation<ChatDiagramDrawing?, Never>]
    }
    private let memory = NSCache<NSString, ChatDiagramDrawing>()
    private var queue: [Job] = []
    private var active: Job?
    private var web: WKWebView?
    private var loading: CheckedContinuation<WKWebView?, Never>?
    private var generation = 0
    private var watchdog: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var failed = Set<String>()
    private var blockedHosts = Set<String>()
    private let root: URL?
    private let allowed: Set<String>

    override init() {
        root = Bundle.main.url(forResource: "ChatDiagrams", withExtension: nil)
        let manifest = root.flatMap { try? Data(contentsOf: $0.appendingPathComponent("manifest.json")) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        allowed = Set((manifest?["files"] as? [String: String] ?? [:]).keys)
            .union(["renderer.html", "renderer.js"])
        super.init()
        memory.totalCostLimit = 32 * 1024 * 1024
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseContext),
                                              name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryPressure),
                                              name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #endif
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func key(host: String, block: ChatDiagramBlock, dark: Bool) -> String {
        Self.digest("v5|12.0.0|1.2026.8|\(host)|\(block.kind.rawValue)|\(dark)|\(block.source)")
    }

    func cached(host: String, block: ChatDiagramBlock, dark: Bool) -> ChatDiagramDrawing? {
        guard !blockedHosts.contains(host) else { return nil }
        let key = key(host: host, block: block, dark: dark)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let file = diskURL(host: host, key: key)
        guard let data = try? Data(contentsOf: file), data.count <= 4 * 1024 * 1024,
              let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        let png = try? Data(contentsOf: pngURL(host: host, key: key))
        guard let drawing = ChatDiagramDrawing(
            pdf: data, size: page.bounds(for: .mediaBox).size,
            image: png.flatMap { PlatformImage(data: $0) }, png: png
        ) else { return nil }
        retain(drawing, key: key)
        return drawing
    }

    func render(host: String, block: ChatDiagramBlock, dark: Bool) async -> ChatDiagramDrawing? {
        guard !Task.isCancelled, !blockedHosts.contains(host) else { return nil }
        if let hit = cached(host: host, block: block, dark: dark) { return hit }
        let key = key(host: host, block: block, dark: dark)
        guard !failed.contains(key), queue.count < 16 else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                if active?.key == key {
                    active?.waiters[id] = continuation
                } else if let index = queue.firstIndex(where: { $0.key == key }) {
                    queue[index].waiters[id] = continuation
                } else {
                    queue.append(Job(key: key, host: host, block: block, dark: dark, waiters: [id: continuation]))
                }
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func allow(host: String) { blockedHosts.remove(host) }

    func forget(host: String) {
        blockedHosts.insert(host)
        memory.removeAllObjects()
        let removed = queue.filter { $0.host == host }
        queue.removeAll { $0.host == host }
        removed.forEach { $0.waiters.values.forEach { $0.resume(returning: nil) } }
        if active?.host == host { finish(nil) }
        try? FileManager.default.removeItem(at: diskURL(host: host, key: "").deletingLastPathComponent())
    }

    private func cancel(_ id: UUID) {
        if let waiter = active?.waiters.removeValue(forKey: id) {
            waiter.resume(returning: nil)
            if active?.waiters.isEmpty == true { finish(nil) }
            return
        }
        for index in queue.indices {
            if let waiter = queue[index].waiters.removeValue(forKey: id) {
                waiter.resume(returning: nil)
                if queue[index].waiters.isEmpty { queue.remove(at: index) }
                return
            }
        }
    }

    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        idle?.cancel()
        active = queue.removeFirst()
        generation &+= 1
        let ticket = generation
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.generation == ticket else { return }
            self.finish(nil)
        }
        Task { [weak self] in
            guard let self, let job = self.active, let web = await self.browser(), self.generation == ticket else { return }
            do {
                let value = try await web.callAsyncJavaScript(
                    "return await window.renderDiagram(kind, source, dark);",
                    arguments: ["kind": job.block.kind.rawValue, "source": job.block.source, "dark": job.dark],
                    in: nil, contentWorld: .page
                )
                guard self.generation == ticket, let result = value as? [String: Any],
                      let width = (result["width"] as? NSNumber)?.doubleValue,
                      let height = (result["height"] as? NSNumber)?.doubleValue,
                      width.isFinite, height.isFinite, width > 0, height > 0,
                      width <= 16000, height <= 16000 else {
                    if self.generation == ticket { self.finish(nil) }; return
                }
                let size = CGSize(width: width, height: height)
                let png = (result["png"] as? String).flatMap { Data(base64Encoded: $0) }
                var fallback: Data?
                #if !canImport(AppKit)
                if png == nil {
                    let config = WKPDFConfiguration()
                    config.rect = CGRect(origin: .zero, size: size)
                    fallback = try? await web.pdf(configuration: config)
                }
                #endif
                guard self.generation == ticket else { return }
                self.finish(ChatDiagramDrawing.make(png: png, fallbackPDF: fallback, size: size, dark: job.dark))
            } catch {
                if self.generation == ticket { self.finish(nil) }
            }
        }
    }

    private func browser() async -> WKWebView? {
        if let web { return web }
        guard root != nil else { finish(nil); return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: "corral-diagram")
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), configuration: config)
        browser.navigationDelegate = self
        web = browser
        return await withCheckedContinuation { continuation in
            loading = continuation
            guard let url = URL(string: "corral-diagram://bundle/renderer.html") else {
                loading = nil
                continuation.resume(returning: nil)
                return
            }
            browser.load(URLRequest(url: url))
        }
    }

    private func finish(_ drawing: ChatDiagramDrawing?) {
        guard let job = active else { return }
        watchdog?.cancel()
        watchdog = nil
        generation &+= 1
        active = nil
        if let drawing, !blockedHosts.contains(job.host) {
            retain(drawing, key: job.key)
            let file = diskURL(host: job.host, key: job.key)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? drawing.pdf.write(to: file, options: .atomic)
            if let png = drawing.png { try? png.write(to: pngURL(host: job.host, key: job.key), options: .atomic) }
            pruneDisk()
        } else {
            failed.insert(job.key)
            if failed.count > 512 { failed = [job.key] }
            retireBrowser()
        }
        job.waiters.values.forEach { $0.resume(returning: drawing) }
        if queue.isEmpty {
            idle = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.retireBrowser()
            }
        } else { pump() }
    }

    @objc private func memoryPressure() { memory.removeAllObjects(); releaseContext() }
    @objc private func releaseContext() {
        let pending = queue
        queue.removeAll()
        pending.forEach { $0.waiters.values.forEach { $0.resume(returning: nil) } }
        if active != nil { finish(nil) }
        retireBrowser()
    }

    private func retireBrowser() {
        loading?.resume(returning: nil)
        loading = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        web = nil
    }

    private func retain(_ drawing: ChatDiagramDrawing, key: String) {
        let pixels = drawing.image.size.width * drawing.image.size.height * 4
        memory.setObject(drawing, forKey: key as NSString, cost: drawing.pdf.count + Int(pixels))
    }

    private func diskURL(host: String, key: String) -> URL {
        AppStorageLocation.cachesDirectory.appendingPathComponent("diagrams", isDirectory: true)
            .appendingPathComponent(Self.digest(host), isDirectory: true).appendingPathComponent(key + ".pdf")
    }

    private func pngURL(host: String, key: String) -> URL {
        diskURL(host: host, key: key).deletingPathExtension().appendingPathExtension("png")
    }

    private func pruneDisk() {
        let folder = AppStorageLocation.cachesDirectory.appendingPathComponent("diagrams")
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var grouped: [URL: (size: Int, date: Date)] = [:]
        for case let url as URL in files {
            guard url.pathExtension == "pdf" || url.pathExtension == "png",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let base = url.deletingPathExtension()
            let current = grouped[base] ?? (size: 0, date: .distantPast)
            grouped[base] = (current.size + (values.fileSize ?? 0), max(current.date, values.contentModificationDate ?? .distantPast))
        }
        let entries = grouped.map { (base: $0.key, size: $0.value.size, date: $0.value.date) }.sorted { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > 64 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: entry.base.appendingPathExtension("pdf"))
            try? FileManager.default.removeItem(at: entry.base.appendingPathExtension("png"))
            total -= entry.size
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        loading?.resume(returning: webView)
        loading = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { if webView === web { finish(nil) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { if webView === web { finish(nil) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === web { finish(nil); retireBrowser() } }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "corral-diagram://bundle/renderer.html" ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "bundle", let root,
              !url.pathComponents.contains("..") else { urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        let path = String(url.path.dropFirst())
        guard allowed.contains(path), let data = try? Data(contentsOf: root.appendingPathComponent(path)) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = path.hasSuffix(".html") ? "text/html" : "text/javascript"
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
