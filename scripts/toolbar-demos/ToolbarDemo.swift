import AppKit

enum Demo: String {
    case a, b, c
    var name: String { "Corral Demo " + rawValue.uppercased() }
    var index: Int { self == .a ? 0 : self == .b ? 1 : 2 }
}

@MainActor
func symbol(_ name: String, _ description: String, size: CGFloat = 14) -> NSImage {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description) else {
        fatalError("Missing system symbol: " + name)
    }
    return image.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? image
}

@MainActor
func iconButton(_ image: String, _ name: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(image: symbol(image, name), target: target, action: action)
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.bezelStyle = .accessoryBarAction
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = name
    button.setAccessibilityLabel(name)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 26),
        button.heightAnchor.constraint(equalToConstant: 28)
    ])
    return button
}

@MainActor
func label(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

@MainActor
func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    parent.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

@MainActor
final class DemoPane: NSViewController, NSPopoverDelegate {
    weak var owner: DemoController?
    let number: Int
    var terminal = false
    var promptsOpen = false
    var pinned = false
    var isFocused = false
    var messages = "You\nMake the toolbar feel simpler.\n\nAssistant\nKeep the controls quiet and let the conversation lead.\n\nGroup related actions, keep familiar icons and make the selected view easy to recognize."
    let bodyText = NSTextView()
    let composer = NSTextField()
    let promptPopover = NSPopover()
    let mode = NSSegmentedControl()
    var terminalButton: NSButton?
    var promptsButton: NSButton!
    var moreButton: NSPopUpButton!
    var focusLine = NSView()
    var sessionMenu: NSMenu!
    var headerView: NSStackView!
    var contentStack: NSStackView!
    let bodyScroll = NSScrollView()
    let inputRow = NSStackView()

    init(number: Int, owner: DemoController) {
        self.number = number
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = NSView()
        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .width
        contentStack.distribution = .fill
        pin(contentStack, in: view)

        let header = NSStackView()
        headerView = header
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 10)
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = label(number == 1 ? "Corral" : "Session \(number)", size: 12, weight: .semibold)
        let project = label("Design", size: 11, color: .tertiaryLabelColor)
        let titleGroup = NSStackView(views: [title, project])
        titleGroup.distribution = .fill
        titleGroup.alignment = .centerY
        titleGroup.spacing = 6
        titleGroup.addArrangedSubview(NSView())
        titleGroup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureMode()
        promptsButton = iconButton("list.bullet.rectangle", "Your prompts", target: self,
                                   action: #selector(togglePrompts))
        sessionMenu = makeSessionMenu()
        moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
        moreButton.menu = sessionMenu
        moreButton.isBordered = false
        moreButton.imagePosition = .imageOnly
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.contentTintColor = .secondaryLabelColor
        (moreButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        moreButton.toolTip = "Session actions"
        moreButton.setAccessibilityLabel("Session actions")
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            moreButton.widthAnchor.constraint(equalToConstant: 26),
            moreButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        let close = iconButton("xmark", "Close pane", target: self, action: #selector(closePane))

        if owner?.demo != .b {
            header.addArrangedSubview(titleGroup)
            if owner?.demo == .c {
                let toggle = iconButton("terminal", "Toggle terminal view", target: self,
                                        action: #selector(toggleTerminal))
                toggle.setButtonType(.toggle)
                toggle.isBordered = true
                toggle.bezelStyle = .rounded
                terminalButton = toggle
                header.addArrangedSubview(toggle)
            } else {
                header.addArrangedSubview(mode)
            }
            header.setCustomSpacing(14, after: header.arrangedSubviews.last!)
            header.addArrangedSubview(promptsButton)
            header.addArrangedSubview(moreButton)
            header.setCustomSpacing(12, after: moreButton)
            header.addArrangedSubview(close)
            contentStack.addArrangedSubview(header)
        } else {
            header.addArrangedSubview(titleGroup)
            header.addArrangedSubview(NSView())
            // With several panes, the title remains the focus target. All actions
            // in candidate B stay in the actual window toolbar.
            contentStack.addArrangedSubview(header)
        }
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        focusLine.wantsLayer = true
        focusLine.heightAnchor.constraint(equalToConstant: 1).isActive = true
        contentStack.addArrangedSubview(focusLine)
        configureConversation()
        promptPopover.delegate = self
        contentStack.addArrangedSubview(bodyScroll)
        configureComposer()
        contentStack.addArrangedSubview(inputRow)
        render()
    }

    func configureMode() {
        mode.segmentCount = 2
        mode.setImage(symbol("bubble.left.and.bubble.right", "Chat"), forSegment: 0)
        mode.setImage(symbol("terminal", "Terminal"), forSegment: 1)
        mode.setToolTip("Chat", forSegment: 0)
        mode.setToolTip("Terminal", forSegment: 1)
        mode.setWidth(31, forSegment: 0)
        mode.setWidth(31, forSegment: 1)
        mode.trackingMode = .selectOne
        mode.segmentStyle = .rounded
        mode.selectedSegmentBezelColor = .tertiaryLabelColor
        mode.controlSize = .small
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(changeMode(_:))
        mode.setAccessibilityLabel("Conversation view")
        mode.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configureConversation() {
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.isVerticallyResizable = true
        bodyText.isHorizontallyResizable = false
        bodyText.autoresizingMask = [.width]
        bodyText.textContainer?.widthTracksTextView = true
        bodyText.textContainerInset = NSSize(width: 24, height: 28)
        bodyScroll.documentView = bodyText
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        bodyScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let click = NSClickGestureRecognizer(target: self, action: #selector(focusPane))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
    }

    func configureComposer() {
        composer.placeholderString = "Message…"
        composer.bezelStyle = .roundedBezel
        composer.font = .systemFont(ofSize: 13)
        composer.target = self
        composer.action = #selector(sendMessage)
        composer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composer.setAccessibilityLabel("Message")
        let send = iconButton("arrow.up.circle.fill", "Send", target: self, action: #selector(sendMessage))
        send.contentTintColor = NSColor(red: 0.18, green: 0.43, blue: 0.34, alpha: 1)
        inputRow.orientation = .horizontal
        inputRow.distribution = .fill
        inputRow.spacing = 8
        inputRow.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 18, right: 18)
        inputRow.addArrangedSubview(composer)
        inputRow.addArrangedSubview(send)
    }

    func render() {
        guard isViewLoaded else { return }
        mode.selectedSegment = terminal ? 1 : 0
        terminalButton?.state = terminal ? .on : .off
        terminalButton?.toolTip = terminal ? "Return to chat" : "Show terminal"
        promptsButton.contentTintColor = promptsOpen ? .labelColor : .secondaryLabelColor
        let text: String
        if terminal {
            text = "╭─ Corral · local preview\n│\n│  Toolbar design\n│  Keep familiar icons.\n│  Group related controls.\n│\n╰──────────────────────────\n\n› Continue the conversation\n\n  This is a local terminal fixture."
        } else {
            text = messages
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = terminal ? 4 : 6
        paragraph.paragraphSpacing = terminal ? 0 : 5
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: terminal ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        if !terminal {
            for name in ["You", "Assistant"] {
                let nsText = text as NSString
                var range = nsText.range(of: name)
                while range.location != NSNotFound {
                    attributed.addAttributes([.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                              .foregroundColor: NSColor.secondaryLabelColor], range: range)
                    let start = range.location + range.length
                    range = nsText.range(of: name, range: NSRange(location: start, length: nsText.length - start))
                }
            }
        }
        bodyText.textStorage?.setAttributedString(attributed)
        inputRow.isHidden = terminal
        focusLine.layer?.backgroundColor = (isFocused
            ? NSColor(red: 0.18, green: 0.43, blue: 0.34, alpha: 1)
            : NSColor.separatorColor).cgColor
    }

    @objc func focusPane() { owner?.focus(self) }

    @objc func changeMode(_ sender: NSSegmentedControl) {
        terminal = sender.selectedSegment == 1
        owner?.focus(self)
        render()
    }

    @objc func toggleTerminal() {
        terminal.toggle()
        owner?.focus(self)
        render()
    }

    @objc func togglePrompts() {
        let wasShown = promptPopover.isShown
        owner?.focus(self)
        if wasShown {
            promptPopover.close()
            promptsOpen = false
        } else {
            let controller = NSViewController()
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
            stack.addArrangedSubview(label("Your prompts", size: 12, weight: .semibold))
            stack.addArrangedSubview(label("1   Make the toolbar feel simpler.", size: 12))
            stack.addArrangedSubview(label("2   Keep the controls icon-only.", size: 12))
            controller.view = stack
            controller.preferredContentSize = NSSize(width: 300, height: 124)
            promptPopover.contentViewController = controller
            promptPopover.behavior = .semitransient
            let anchor = owner?.demo == .b ? owner?.toolbarPromptAnchor : promptsButton
            if let anchor {
                promptPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                promptsOpen = true
            }
        }
        render()
    }

    @objc func closePane() { owner?.close(self) }

    func popoverDidClose(_ notification: Notification) {
        promptsOpen = false
        render()
    }

    @objc func sendMessage() {
        let message = composer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        owner?.focus(self)
        messages += "\n\nYou\n" + message + "\n\nAssistant\nThis reply stays inside the demo."
        composer.stringValue = ""
        render()
        bodyText.scrollToEndOfDocument(nil)
    }

    func makeSessionMenu() -> NSMenu {
        let menu = NSMenu()
        let first = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        first.image = symbol("ellipsis", "Session actions")
        menu.addItem(first)
        let pin = NSMenuItem(title: "Pin session", action: #selector(togglePin(_:)), keyEquivalent: "")
        pin.target = self
        pin.image = symbol("pin", "Pin")
        menu.addItem(pin)
        let duplicate = NSMenuItem(title: "Duplicate pane", action: #selector(duplicatePane), keyEquivalent: "")
        duplicate.target = self
        duplicate.image = symbol("doc.on.doc", "Duplicate")
        menu.addItem(duplicate)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close pane", action: #selector(closePane), keyEquivalent: "")
        close.target = self
        close.image = symbol("xmark", "Close")
        menu.addItem(close)
        return menu
    }

    @objc func togglePin(_ sender: NSMenuItem) {
        pinned.toggle()
        sender.state = pinned ? .on : .off
    }

    @objc func duplicatePane() { owner?.addPane() }
}

@MainActor
final class DemoController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let demo: Demo
    let window: NSWindow
    let split = NSSplitViewController()
    var panes: [DemoPane] = []
    var focused: DemoPane?
    var modeItem: NSToolbarItemGroup?
    var searchItem: NSSearchToolbarItem?
    var toolbarPromptAnchor: NSView?
    var shellWindow: NSWindow?
    var nextPane = 1

    init(demo: Demo) {
        self.demo = demo
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 450),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = demo.name
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 430, height: 300)
        split.splitView.isVertical = true
        window.contentViewController = split
        let toolbar = NSToolbar(identifier: "corral.demo." + demo.rawValue)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        addPane()
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let width = min(480, (frame.width - 48) / 3)
            window.setFrame(NSRect(x: frame.minX + 12 + CGFloat(demo.index) * (width + 10),
                                   y: frame.maxY - 500, width: width, height: 460), display: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    @objc func addPane() {
        guard panes.count < 3 else { return }
        let pane = DemoPane(number: nextPane, owner: self)
        nextPane += 1
        let item = NSSplitViewItem(viewController: pane)
        item.minimumThickness = 230
        split.addSplitViewItem(item)
        panes.append(pane)
        focus(pane)
        if panes.count > 1, window.frame.width < 760 {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY,
                                   width: 900, height: window.frame.height), display: true)
        }
    }

    func focus(_ pane: DemoPane) {
        if focused !== pane { focused?.promptPopover.close() }
        focused = pane
        for candidate in panes {
            candidate.isFocused = candidate === pane
            candidate.render()
        }
        modeItem?.selectedIndex = pane.terminal ? 1 : 0
        window.toolbar?.validateVisibleItems()
    }

    func close(_ pane: DemoPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        pane.promptPopover.close()
        split.removeSplitViewItem(split.splitViewItems[index])
        panes.remove(at: index)
        if let next = panes.first { focus(next) } else { focused = nil }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if demo == .b {
            return [.init("mode"), .init("prompts"), .flexibleSpace,
                    .init("shell"), .init("searchButton"), .init("add"), .init("more"), .space, .init("close")]
        }
        return [.flexibleSpace, .init("shell"), .init("searchButton"), .space, .init("add")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.init("search")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let id = identifier.rawValue
        if id == "mode" {
            let item = NSToolbarItemGroup(itemIdentifier: identifier,
                images: [symbol("bubble.left.and.bubble.right", "Chat"), symbol("terminal", "Terminal")],
                selectionMode: .selectOne, labels: nil, target: self, action: #selector(toolbarMode(_:)))
            item.label = "Conversation view"
            item.controlRepresentation = .expanded
            item.selectedIndex = 0
            item.subitems[0].toolTip = "Chat"
            item.subitems[1].toolTip = "Terminal"
            modeItem = item
            return item
        }
        if id == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Search"
            item.toolTip = "Search conversation"
            item.preferredWidthForSearchField = 150
            item.searchField.placeholderString = "Search"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(search(_:))
            item.searchField.delegate = self
            searchItem = item
            return item
        }
        if id == "add" || id == "more" {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = id == "add" ? "Add pane" : "Session actions"
            item.image = symbol(id == "add" ? "rectangle.split.2x1" : "ellipsis", item.label)
            item.showsIndicator = id == "add"
            let menu = NSMenu()
            if id == "add" {
                let add = NSMenuItem(title: "Add session pane", action: #selector(addPane), keyEquivalent: "")
                add.target = self
                menu.addItem(add)
                let shell = NSMenuItem(title: "Open project terminal", action: #selector(openShell), keyEquivalent: "")
                shell.target = self
                menu.addItem(shell)
            } else {
                let pin = NSMenuItem(title: "Pin session", action: #selector(pinFocused), keyEquivalent: "")
                pin.target = self
                menu.addItem(pin)
                let duplicate = NSMenuItem(title: "Duplicate pane", action: #selector(addPane), keyEquivalent: "")
                duplicate.target = self
                menu.addItem(duplicate)
            }
            item.menu = menu
            item.toolTip = item.label
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        if id == "shell" {
            item.label = "Project terminal"
            item.image = symbol("terminal", item.label)
            item.action = #selector(openShell)
        } else if id == "searchButton" {
            item.label = "Search"
            item.image = symbol("magnifyingglass", item.label)
            item.action = #selector(beginSearch)
        } else if id == "prompts" {
            item.label = "Your prompts"
            let button = iconButton("list.bullet.rectangle", item.label, target: self,
                                    action: #selector(toolbarPrompts))
            item.view = button
            toolbarPromptAnchor = button
        } else if id == "close" {
            item.label = "Close pane"
            item.image = symbol("xmark", item.label)
            item.action = #selector(closeFocused)
        }
        item.toolTip = item.label
        return item
    }

    @objc func toolbarMode(_ sender: NSToolbarItemGroup) {
        guard let pane = focused else { return }
        pane.terminal = sender.selectedIndex == 1
        focus(pane)
    }
    @objc func toolbarPrompts() { focused?.togglePrompts() }
    @objc func closeFocused() { if let pane = focused { close(pane) } }
    @objc func pinFocused() { focused?.pinned.toggle() }

    @objc func beginSearch() {
        guard let toolbar = window.toolbar,
              let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == "searchButton" }) else { return }
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: .init("search"), at: index)
        searchItem?.beginSearchInteraction()
    }

    func endSearch() {
        guard let toolbar = window.toolbar,
              let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == "search" }) else { return }
        searchItem?.endSearchInteraction()
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: .init("searchButton"), at: index)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        DispatchQueue.main.async { self.endSearch() }
    }

    @objc func search(_ sender: NSSearchField) {
        guard let text = focused?.bodyText else { return }
        let range = (text.string as NSString).range(of: sender.stringValue, options: .caseInsensitive)
        if range.location != NSNotFound, range.length > 0 {
            text.setSelectedRange(range)
            text.scrollRangeToVisible(range)
        } else {
            text.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    @objc func openShell() {
        if let shellWindow { shellWindow.makeKeyAndOrderFront(nil); return }
        let shell = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        shell.title = demo.name + " · Project terminal"
        shell.isReleasedWhenClosed = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let text = NSTextView()
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.string = "~/project\n\n$ git status\nOn branch main\n\n$ ▌\n\nLocal preview · no commands are executed."
        scroll.documentView = text
        shell.contentView = scroll
        shell.center()
        shell.makeKeyAndOrderFront(nil)
        shellWindow = shell
    }

    func inspect(_ scenario: String) {
        switch scenario {
        case "terminal": focused?.toggleTerminal()
        case "prompts": focused?.togglePrompts()
        case "split": addPane()
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    func verify(to path: String) async {
        guard let pane = focused else { return }
        var checks: [String: Bool] = [:]
        pane.toggleTerminal()
        checks["terminalRendered"] = pane.terminal && pane.bodyText.string.contains("local preview") && pane.inputRow.isHidden
        pane.toggleTerminal()
        checks["chatRestored"] = !pane.terminal && pane.bodyText.string.contains("Make the toolbar") && !pane.inputRow.isHidden
        pane.togglePrompts()
        try? await Task.sleep(for: .milliseconds(300))
        checks["promptsPresented"] = pane.promptPopover.isShown
        pane.togglePrompts()
        for _ in 0..<20 {
            if !pane.promptPopover.isShown { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        checks["promptsClosed"] = !pane.promptPopover.isShown
        let originalMessages = pane.messages
        pane.composer.stringValue = "Local verification"
        pane.sendMessage()
        checks["localSendRendered"] = pane.bodyText.string.contains("Local verification") && pane.composer.stringValue.isEmpty
        pane.messages = originalMessages
        pane.render()
        addPane()
        checks["splitAdded"] = panes.count == 2 && split.splitViewItems.count == 2
        if let second = focused {
            second.toggleTerminal()
            focus(pane)
            checks["paneModesIndependent"] = !pane.terminal && second.terminal && modeItem?.selectedIndex != 1
            close(second)
        }
        checks["paneClosed"] = panes.count == 1 && split.splitViewItems.count == 1
        beginSearch()
        searchItem?.searchField.stringValue = "familiar"
        if let searchItem { search(searchItem.searchField) }
        checks["searchSelectedMatch"] = pane.bodyText.selectedRange().length == 8
        pane.bodyText.setSelectedRange(NSRange(location: 0, length: 0))
        searchItem?.searchField.stringValue = ""
        endSearch()
        openShell()
        checks["projectTerminalOpened"] = shellWindow?.isVisible == true
        shellWindow?.close()
        checks["iconOnlyToolbar"] = window.toolbar?.displayMode == .iconOnly
        let commands = pane.sessionMenu.items.filter { !$0.title.isEmpty && !$0.isSeparatorItem }
        checks["menusHaveActions"] = commands.count == 3 && commands.allSatisfy { $0.action != nil && $0.target === pane }
        show()
        window.contentView?.layoutSubtreeIfNeeded()
        checks["headerFillsPane"] = abs(pane.headerView.frame.width - pane.view.frame.width) < 1
        checks["headerControlsVisible"] = pane.headerView.arrangedSubviews.allSatisfy {
            $0.frame.minX >= 0 && $0.frame.maxX <= pane.headerView.bounds.width
        }
        let frames = pane.headerView.arrangedSubviews.map { child -> [String: Any] in
            ["class": String(describing: type(of: child)), "frame": NSStringFromRect(child.frame),
             "hidden": child.isHidden]
        }
        let source = Bundle.main.object(forInfoDictionaryKey: "SourceCommit") as? String ?? "development"
        let receipt: [String: Any] = ["demo": demo.rawValue, "sourceCommit": source,
                                     "checks": checks, "passed": checks.values.allSatisfy { $0 },
                                     "physicalInputDriven": false, "headerFrames": frames,
                                     "headerBounds": NSStringFromRect(pane.headerView.bounds),
                                     "menuCommands": commands.map { $0.title }]
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Cannot write verification receipt: \(error)\n".utf8))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: DemoController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let rawDemo = Bundle.main.object(forInfoDictionaryKey: "DemoVariant") as? String ?? "a"
        let demo = Demo(rawValue: rawDemo) ?? .a
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit " + demo.name, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        let controller = DemoController(demo: demo)
        self.controller = controller
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        let args = ProcessInfo.processInfo.arguments
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let index = args.firstIndex(of: "--verify"), args.indices.contains(index + 1) {
                Task { await controller.verify(to: args[index + 1]) }
            }
            if let index = args.firstIndex(of: "--scenario"), args.indices.contains(index + 1) {
                controller.inspect(args[index + 1])
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ToolbarDemoApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
