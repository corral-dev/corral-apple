import AppKit

// Local AppKit fixture: no product preferences, host data or terminal execution.
enum Candidate: String, CaseIterable {
    case a, b, c
    var title: String {
        switch self {
        case .a: "A · Current rule"
        case .b: "B · Title first"
        case .c: "C · Quiet title bar"
        }
    }
}

@MainActor
func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
          color: NSColor = .labelColor) -> NSTextField {
    let result = NSTextField(labelWithString: value)
    result.font = .systemFont(ofSize: size, weight: weight)
    result.textColor = color
    result.lineBreakMode = .byTruncatingTail
    return result
}

@MainActor
func icon(_ name: String, target: AnyObject?, action: Selector?, help: String) -> NSButton {
    let result = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: help)!,
                          target: target, action: action)
    result.isBordered = false
    result.contentTintColor = .secondaryLabelColor
    result.focusRingType = .none
    result.toolTip = help
    result.setAccessibilityLabel(help)
    return result
}

@MainActor
final class Surface: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var radius: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

@MainActor
final class Pane: NSView {
    weak var owner: Study?
    let index: Int
    let header = Surface()
    let rule = Surface()
    let title: NSTextField
    let project: NSTextField
    let logo = NSImageView()
    let dot = Surface()
    let mode = NSSegmentedControl()
    let prompts: NSButton
    let more: NSButton
    let close: NSButton
    let scroll = NSScrollView()
    let conversation = NSTextView()
    let composerSurface = Surface()
    let composer = NSTextField()
    let add: NSButton
    let send: NSButton
    var isTerminal = false
    var active = false
    var dark = false
    var candidate: Candidate = .a
    var localMessages: [String] = []
    static let names = ["重做会话分屏顶栏", "修复断线后的会话恢复", "审查客户端发布流程", "优化长对话的阅读体验"]
    static let projects = ["Corral", "Relay", "SessKit", "Corral"]
    static let runtimes = ["claude", "codex", "opencode", "pi"]

    init(index: Int, owner: Study) {
        self.index = index
        self.owner = owner
        title = text(Self.names[index], size: 13, weight: .semibold)
        project = text(Self.projects[index], size: 11, color: .tertiaryLabelColor)
        prompts = icon("text.bubble", target: nil, action: nil, help: "Your prompts")
        more = icon("ellipsis", target: nil, action: nil, help: "Session actions")
        close = icon("xmark", target: nil, action: nil, help: "Close pane")
        add = icon("plus", target: nil, action: nil, help: "Attach a file")
        send = icon("arrow.up.circle.fill", target: nil, action: nil, help: "Send local message")
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(header)
        for child in [dot, logo, title, project, mode, prompts, more, close] { header.addSubview(child) }
        addSubview(rule)
        addSubview(scroll)
        addSubview(composerSurface)
        for child in [composer, add, send] { composerSurface.addSubview(child) }
        // Context-only fixture controls do not expose unimplemented actions.
        for control in [prompts, close, add] { control.isEnabled = false }
        dot.radius = 3
        mode.segmentCount = 2
        mode.setImage(NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Chat"), forSegment: 0)
        mode.setImage(NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal"), forSegment: 1)
        mode.setWidth(28, forSegment: 0)
        mode.setWidth(28, forSegment: 1)
        mode.trackingMode = .selectOne
        mode.segmentStyle = .rounded
        mode.controlSize = .small
        mode.selectedSegmentBezelColor = .tertiaryLabelColor
        mode.focusRingType = .none
        mode.target = self
        mode.action = #selector(togglePaneMode)
        mode.setAccessibilityLabel("Conversation view")
        conversation.isEditable = false
        conversation.isSelectable = true
        conversation.drawsBackground = false
        conversation.isVerticallyResizable = true
        conversation.isHorizontallyResizable = false
        conversation.autoresizingMask = [.width]
        conversation.textContainer?.widthTracksTextView = true
        conversation.textContainerInset = NSSize(width: 28, height: 28)
        conversation.focusRingType = .none
        scroll.documentView = conversation
        scroll.contentView.clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        composer.isBordered = false
        composer.drawsBackground = false
        composer.focusRingType = .none
        composer.font = .systemFont(ofSize: 14)
        composer.placeholderString = "Message…"
        composer.target = self
        composer.action = #selector(sendLocal)
        composer.setAccessibilityLabel("Message in " + Self.names[index])
        more.target = self
        more.action = #selector(showSessionMenu)
        send.target = self
        send.action = #selector(sendLocal)
        composerSurface.radius = 16
        let click = NSClickGestureRecognizer(target: self, action: #selector(focus))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc func focus() { owner?.focus(index) }
    @objc func togglePaneMode() { isTerminal = mode.selectedSegment == 1; owner?.focus(index); refresh() }
    @objc func sendLocal() {
        guard !composer.stringValue.isEmpty else { return }
        localMessages.append(composer.stringValue)
        composer.stringValue = ""
        owner?.focus(index)
    }

    @objc func showSessionMenu() {
        let menu = NSMenu()
        for title in [Self.names[index], Self.projects[index] + " / " + Self.runtimes[index]] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Your prompts (\([8, 4, 12, 6][index]))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Close pane", action: nil, keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: more.bounds.maxX, y: more.bounds.minY), in: more)
    }

    func refresh() {
        let accent = NSColor(srgbRed: 0.24, green: 0.46, blue: 0.34, alpha: 1)
        let headerDark = dark
        header.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        header.color = candidate == .c
            ? (dark ? NSColor(white: active ? 0.23 : 0.14, alpha: 1)
                    : NSColor(white: active ? 1.0 : 0.94, alpha: 1)) : .clear
        rule.color = active && candidate == .a ? accent : .separatorColor
        title.textColor = active ? .labelColor : .secondaryLabelColor
        title.font = .systemFont(ofSize: candidate == .a ? 13 : (candidate == .c ? 15 : 22),
                                 weight: active ? .semibold : .medium)
        project.textColor = .secondaryLabelColor
        project.stringValue = Self.projects[index]
        title.alignment = .left
        logo.isHidden = candidate == .c
        dot.isHidden = candidate == .c
        project.isHidden = candidate == .c
        prompts.isHidden = candidate == .c
        close.isHidden = candidate == .c
        dot.color = index == 1 ? .systemOrange : (index == 2 ? .tertiaryLabelColor : .systemGreen)
        mode.setLabel(candidate == .c ? "对话" : "", forSegment: 0)
        mode.setLabel(candidate == .c ? "终端" : "", forSegment: 1)
        mode.setImage(candidate == .c ? nil : NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Chat"), forSegment: 0)
        mode.setImage(candidate == .c ? nil : NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal"), forSegment: 1)
        mode.setWidth(candidate == .c ? 38 : 28, forSegment: 0)
        mode.setWidth(candidate == .c ? 38 : 28, forSegment: 1)
        mode.segmentStyle = candidate == .c ? .texturedRounded : .rounded
        mode.cell?.isBordered = candidate != .c
        mode.font = .systemFont(ofSize: 12)

        prompts.title = ""
        prompts.imagePosition = .imageOnly
        for button in [prompts, more, close] { button.contentTintColor = .secondaryLabelColor }
        let resource = Bundle.main.resourceURL!.appendingPathComponent("runtime\(Self.runtimes[index])-\(headerDark ? "dark" : "light")@2x.png")
        logo.image = NSImage(contentsOf: resource)
        logo.imageScaling = .scaleProportionallyDown
        composerSurface.color = dark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1)
                                    : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        // Focus belongs to the header; the owner rejected composer coloring.
        composer.textColor = .labelColor
        send.contentTintColor = accent
        composerSurface.isHidden = isTerminal
        mode.selectedSegment = isTerminal ? 1 : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = isTerminal ? 4 : 5
        paragraph.paragraphSpacing = isTerminal ? 3 : 12
        let chat = [
            "You\nKeep the session list simple, but make the active conversation easy to recognize.\n\nAssistant\nI’ll keep the existing layout and focus on the visual hierarchy.\n\nA quieter sidebar\nSessions stay in a flat list. Project names help you scan, while status remains a small, separate signal.\n\nClear input ownership\nThe selected conversation should be visible at a glance, even with several sessions open side by side.\n\nThe content in neighbouring panes stays fully readable so you can follow parallel work.",
            "You\nCheck what happens when the connection drops during a response.\n\nAssistant\nThe draft and conversation stay available while the client reconnects.\n\nRecovery checks\n• Preserve the pending response.\n• Resume from the last confirmed event.\n• Avoid duplicate messages.\n\nThe transport recovers independently from the selected pane.\n\nI’m checking the interrupted-stream case next.",
            "You\nReview the release workflow and keep the change small.\n\nAssistant\nThe current workflow builds from a committed source snapshot.\n\nWhat I checked\nThe signed archive, update feed and download all refer to the same version.\n\nOne useful improvement\nRecord the downloaded checksum alongside the release receipt, so the shipped artifact can be checked directly.\n\nThe existing install path stays the same.",
            "You\nImprove the spacing without making the conversation feel sparse.\n\nAssistant\nI’ve kept the text size and adjusted the rhythm between blocks.\n\nReading comfortably\nParagraphs have a little more breathing room. Lists stay together, and headings have a clear relationship to the text below them.\n\nCode and tables keep their compact geometry.\n\nThis preserves the amount of useful information visible in each pane."
        ][index]
        let terminal = "❯ Review the recovery path\n\n• Reading connection state\n  Shared/Core/Network\n\n• Checking reconnect behavior\n\n  ✓ keeps the local draft\n  ✓ resumes confirmed events\n  ✓ avoids duplicate delivery\n\nAll checks passed.\n\nThe client can recover without\ninterrupting neighbouring sessions.\n\n────────────────────────────\n❯ \(active ? "▌" : "")\n\n  fixture · no process running"
        let string = isTerminal ? terminal : chat + localMessages.map { "\n\nYou\n" + $0 }.joined()
        let attributed = NSMutableAttributedString(string: string, attributes: [
            .font: isTerminal ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        if !isTerminal {
            for heading in ["You", "Assistant", "A quieter sidebar", "Clear input ownership", "Recovery checks", "What I checked", "One useful improvement", "Reading comfortably"] {
                let range = (string as NSString).range(of: heading)
                if range.location != NSNotFound { attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: heading == "You" || heading == "Assistant" ? 12 : 14, weight: .semibold), range: range) }
            }
        }
        conversation.textStorage?.setAttributedString(attributed)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let headerHeight: CGFloat = candidate == .a ? 44 : (candidate == .b ? 88 : 48)
        header.frame = NSRect(x: 0, y: h - headerHeight, width: w, height: headerHeight)
        rule.frame = NSRect(x: 0, y: h - headerHeight - 2, width: w, height: active && candidate == .a ? 2 : 0.5)
        dot.frame = NSRect(x: 12, y: 19, width: 6, height: 6)
        logo.frame = NSRect(x: 25, y: 13, width: 18, height: 18)
        close.frame = NSRect(x: w - 32, y: 10, width: 22, height: 24)
        more.frame = NSRect(x: w - 60, y: 10, width: 22, height: 24)
        mode.frame = NSRect(x: w - 130, y: 11, width: 62, height: 22)
        prompts.frame = NSRect(x: w - 160, y: 10, width: 22, height: 24)
        let available = w - 219
        title.frame = NSRect(x: 51, y: 14, width: max(40, available - 48), height: 18)
        project.frame = NSRect(x: title.frame.maxX + 5, y: 14, width: 45, height: 17)
        if candidate == .b {
            title.frame = NSRect(x: 24, y: 44, width: w - 74, height: 30)
            close.frame = NSRect(x: w - 39, y: 48, width: 22, height: 24)
            logo.frame = NSRect(x: 24, y: 14, width: 16, height: 16)
            project.frame = NSRect(x: 47, y: 14, width: max(40, w - 240), height: 17)
            dot.frame = NSRect(x: project.frame.maxX + 8, y: 19, width: 6, height: 6)
            mode.frame = NSRect(x: w - 150, y: 11, width: 62, height: 22)
            prompts.frame = NSRect(x: w - 76, y: 10, width: 22, height: 24)
            more.frame = NSRect(x: w - 40, y: 10, width: 22, height: 24)
        } else if candidate == .c {
            title.frame = NSRect(x: 28, y: 13, width: w - 166, height: 22)
            mode.frame = NSRect(x: w - 126, y: 12, width: 82, height: 24)
            more.frame = NSRect(x: w - 36, y: 12, width: 22, height: 24)
        }
        title.toolTip = Self.names[index] + "\n" + Self.projects[index] + " / " + Self.runtimes[index]
        project.toolTip = Self.projects[index]
        let footer: CGFloat = isTerminal ? 0 : 114
        scroll.frame = NSRect(x: 0, y: footer, width: w, height: h - headerHeight - 2 - footer)
        conversation.frame.size.width = scroll.contentSize.width
        conversation.textContainer?.containerSize = NSSize(width: max(1, scroll.contentSize.width - 56), height: .greatestFiniteMagnitude)
        if let container = conversation.textContainer { conversation.layoutManager?.ensureLayout(for: container) }
        conversation.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        conversation.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composerSurface.frame = NSRect(x: 24, y: 22, width: w - 48, height: 84)
        composer.frame = NSRect(x: 15, y: 43, width: w - 85, height: 24)
        add.frame = NSRect(x: 10, y: 8, width: 25, height: 25)
        send.frame = NSRect(x: composerSurface.bounds.width - 38, y: 8, width: 27, height: 27)
    }
}

@MainActor
final class Study: NSObject, NSToolbarDelegate {
    let window = NSWindow(contentRect: NSRect(x: 30, y: 70, width: 1960, height: 1040),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let root = Surface()
    let sidebar = Surface()
    let split = NSSplitView()
    var panes: [Pane] = []
    var candidate: Candidate = .c
    var count = 4
    var dark = false
    var focused = 2
    var mixed = false
    let variants = NSSegmentedControl(labels: ["A", "B", "C"], trackingMode: .selectOne, target: nil, action: nil)
    let counts = NSSegmentedControl(labels: ["2 panes", "4 panes"], trackingMode: .selectOne, target: nil, action: nil)
    let appearances = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)

    override init() {
        super.init()
        window.contentView = root
        root.color = .textBackgroundColor
        sidebar.color = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.title = "Corral · Split Focus Study"
        window.toolbarStyle = .unifiedCompact
        window.contentMinSize = NSSize(width: 1100, height: 680)
        root.addSubview(sidebar)
        root.addSubview(split)
        split.isVertical = true
        split.dividerStyle = .thin
        let toolbar = NSToolbar(identifier: "focus.study.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        for control in [variants, counts, appearances] {
            control.controlSize = .small
            control.focusRingType = .none
            control.target = self
            control.action = #selector(settings(_:))
        }
        variants.setAccessibilityLabel("Focus treatment")
        for (index, candidate) in Candidate.allCases.enumerated() { variants.setToolTip(candidate.title, forSegment: index) }
        counts.setAccessibilityLabel("Pane count")
        appearances.setAccessibilityLabel("Appearance")
        rebuild()
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("title"), .flexibleSpace, .init("variant"), .space, .init("count"), .space, .init("appearance")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "title": item.view = text("Corral   /   Focus study", size: 12, weight: .medium)
        case "variant": item.view = variants
        case "count": item.view = counts
        case "appearance": item.view = appearances
        default: return nil
        }
        return item
    }
    @objc func settings(_ sender: NSSegmentedControl) {
        candidate = Candidate.allCases[max(0, variants.selectedSegment)]
        count = counts.selectedSegment == 0 ? 2 : 4
        dark = appearances.selectedSegment == 1
        focused = min(focused, count - 1)
        rebuild()
    }
    func rebuild() {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentMinSize = NSSize(width: count == 4 ? 1560 : 1100, height: 680)
        window.backgroundColor = .textBackgroundColor
        variants.selectedSegment = Candidate.allCases.firstIndex(of: candidate)!
        counts.selectedSegment = count == 2 ? 0 : 1
        appearances.selectedSegment = dark ? 1 : 0
        split.subviews.forEach { $0.removeFromSuperview() }
        panes = (0..<count).map { Pane(index: $0, owner: self) }
        for pane in panes {
            pane.candidate = candidate
            pane.dark = dark
            pane.isTerminal = mixed && pane.index % 2 == 1
            split.addArrangedSubview(pane)
        }
        focus(focused)
        layout()
        renderSidebar()
    }
    func renderSidebar() {
        sidebar.subviews.forEach { $0.removeFromSuperview() }
        let top = text("Sessions", size: 20, weight: .semibold)
        top.frame = NSRect(x: 21, y: root.bounds.height - 52, width: 220, height: 28)
        top.autoresizingMask = [.minYMargin]
        sidebar.addSubview(top)
        let search = NSSearchField(frame: NSRect(x: 18, y: root.bounds.height - 92, width: 220, height: 28))
        search.placeholderString = "Search sessions"
        search.focusRingType = .none
        search.autoresizingMask = [.minYMargin]
        sidebar.addSubview(search)
        let group = text("Today", size: 11, weight: .semibold, color: .secondaryLabelColor)
        group.frame = NSRect(x: 23, y: root.bounds.height - 133, width: 200, height: 18)
        group.autoresizingMask = [.minYMargin]
        sidebar.addSubview(group)
        for i in 0..<8 {
            let y = root.bounds.height - 190 - CGFloat(i) * 68
            let name = text(Pane.names[i % 4], size: 13, weight: i == focused ? .semibold : .regular)
            name.frame = NSRect(x: 23, y: y + 16, width: 210, height: 19)
            name.autoresizingMask = [.minYMargin]
            let project = text(Pane.projects[i % 4] + "  ·  " + (i < 4 ? "Open" : "Yesterday"), size: 11, color: .secondaryLabelColor)
            project.frame = NSRect(x: 23, y: y - 4, width: 210, height: 17)
            project.autoresizingMask = [.minYMargin]
            sidebar.addSubview(name)
            sidebar.addSubview(project)
        }
        let connected = text("●  Mac Studio    Connected", size: 11, color: .secondaryLabelColor)
        connected.frame = NSRect(x: 23, y: 22, width: 220, height: 20)
        sidebar.addSubview(connected)
    }
    func layout() {
        let size = root.bounds.size
        sidebar.frame = NSRect(x: 0, y: 0, width: 256, height: size.height)
        split.frame = NSRect(x: 256, y: 0, width: size.width - 256, height: size.height)
        let width = (split.bounds.width - CGFloat(count - 1) * split.dividerThickness) / CGFloat(count)
        for (index, pane) in panes.enumerated() {
            pane.frame = NSRect(x: CGFloat(index) * (width + split.dividerThickness), y: 0, width: width, height: split.bounds.height)
            pane.layoutSubtreeIfNeeded()
        }
    }
    func focus(_ index: Int) {
        focused = index
        for pane in panes { pane.active = pane.index == index; pane.refresh() }
    }
    func export(_ url: URL, rect: NSRect? = nil) throws {
        layout()
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let region = rect ?? root.bounds
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: region) else { throw CocoaError(.coderInvalidValue) }
        root.cacheDisplay(in: region, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    func verifyActions() throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        variants.selectedSegment = 1
        variants.sendAction(variants.action!, to: variants.target)
        result["nativeVariantAction"] = candidate == .b
        counts.selectedSegment = 0
        counts.sendAction(counts.action!, to: counts.target)
        result["nativePaneCountAction"] = panes.count == 2
        appearances.selectedSegment = 1
        appearances.sendAction(appearances.action!, to: appearances.target)
        result["nativeAppearanceAction"] = dark
        let first = panes[0]
        first.mode.selectedSegment = 1
        first.mode.sendAction(first.mode.action!, to: first.mode.target)
        result["nativeModeAction"] = first.isTerminal && focused == 0 && first.composerSurface.isHidden
        first.mode.selectedSegment = 0
        first.mode.sendAction(first.mode.action!, to: first.mode.target)
        first.composer.stringValue = "Local action verification"
        first.send.sendAction(first.send.action!, to: first.send.target)
        result["nativeLocalSendAction"] = first.composer.stringValue.isEmpty && first.conversation.string.contains("Local action verification")
        result["noControlFocusRings"] = panes.allSatisfy { $0.composer.focusRingType == .none && $0.mode.focusRingType == .none }
        result["neutralComposers"] = panes.allSatisfy { $0.composerSurface.color.isEqual(panes[0].composerSurface.color) }
        guard result.values.allSatisfy({ $0 }) else {
            FileHandle.standardError.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return result
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    var study: Study?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = Study()
        study = controller
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export"), args.count > i + 1 {
            let output = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            controller.window.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Task { @MainActor in
                do {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let actions = try controller.verifyActions()
                    try JSONSerialization.data(withJSONObject: actions, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent("native-action-receipt.json"))
                    var receipts: [[String: Any]] = []
                    for variant in Candidate.allCases {
                        for count in [2, 4] {
                            for dark in [false, true] {
                                controller.candidate = variant; controller.count = count
                                controller.dark = dark; controller.focused = count == 2 ? 0 : 2
                                controller.mixed = false
                                controller.rebuild()
                                try await Task.sleep(for: .milliseconds(100))
                                let name = "\(variant.rawValue)-\(count)-\(dark ? "dark" : "light")"
                                try controller.export(output.appendingPathComponent(name + ".png"))
                                if variant == .c, count == 4 {
                                    let rect = NSRect(x: 256, y: controller.root.bounds.height - 60,
                                                      width: controller.root.bounds.width - 256, height: 60)
                                    try controller.export(output.appendingPathComponent("c-header-\(dark ? "dark" : "light").png"), rect: rect)
                                }
                                let selected = controller.panes.filter(\.active)
                                let valid = selected.count == 1 && selected[0].index == controller.focused
                                    && controller.panes.allSatisfy { pane in
                                        let views = pane.header.subviews.filter { !$0.isHidden }
                                        let contained = views.allSatisfy { pane.header.bounds.contains($0.frame) }
                                        let disjoint = views.enumerated().allSatisfy { index, view in
                                            views.dropFirst(index + 1).allSatisfy { !view.frame.intersects($0.frame) }
                                        }
                                        return contained && disjoint && pane.header.bounds.width > 300
                                            && pane.title.frame.width > 40 && pane.composer.focusRingType == .none
                                            && pane.composerSurface.color.isEqual(controller.panes[0].composerSurface.color)
                                    }
                                guard valid else { throw CocoaError(.validationMissingMandatoryProperty) }
                                receipts.append(["scenario": name, "focus": controller.focused + 1, "nativeStatePass": valid,
                                                 "paneWidth": controller.panes[0].bounds.width, "evidence": "NSView native content export; not WindowServer screenshot"])
                            }
                        }
                    }
                    controller.candidate = .c; controller.count = 4; controller.mixed = true
                    for dark in [false, true] {
                        controller.dark = dark
                        for index in 0..<4 {
                            controller.focused = index; controller.rebuild()
                            try await Task.sleep(for: .milliseconds(100))
                            let name = "c-mixed-\(dark ? "dark" : "light")-focus\(index + 1)"
                            try controller.export(output.appendingPathComponent(name + ".png"))
                            let valid = controller.panes.filter(\.active).count == 1
                                && controller.panes[index].active
                                && controller.panes.allSatisfy { $0.composerSurface.isHidden == $0.isTerminal }
                            guard valid else { throw CocoaError(.validationMissingMandatoryProperty) }
                            receipts.append(["scenario": name, "focus": index + 1, "nativeStatePass": valid,
                                             "paneWidth": controller.panes[0].bounds.width,
                                             "evidence": "NSView native content export; not WindowServer screenshot"])
                        }
                    }
                    let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: output.appendingPathComponent("native-state-receipt.json"))
                    NSApplication.shared.terminate(nil)
                } catch {
                    FileHandle.standardError.write(Data("Focus study failed: \(error)\n".utf8))
                    exit(1)
                }
                }
            }
        } else {
            if let i = args.firstIndex(of: "--variant"), args.count > i + 1 {
                controller.candidate = Candidate(rawValue: args[i + 1]) ?? .c
            }
            controller.dark = args.contains("--dark")
            controller.count = args.contains("--two") ? 2 : 4
            controller.focused = controller.count == 2 ? 0 : 2
            controller.rebuild()
            if let screen = NSScreen.screens.max(by: { $0.visibleFrame.width < $1.visibleFrame.width }) {
                let area = screen.visibleFrame
                let size = NSSize(width: min(2060, area.width - 80), height: min(1100, area.height - 80))
                controller.window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                                  width: size.width, height: size.height), display: true)
            }
            if args.contains("--preview") { controller.window.toolbar = nil }
            controller.layout()
            controller.renderSidebar()
            controller.window.makeKeyAndOrderFront(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
