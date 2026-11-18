import Foundation

/// Structured Markdown document representation for full-screen file reading.
/// Reuses Foundation's `AttributedString(markdown:)` AST (`presentationIntent`)
/// without adding a second Markdown parser.
nonisolated struct MarkdownDocument: Sendable {
    static let maxParsedUTF8Bytes = 512 * 1024

    struct ListItem: Identifiable, Sendable {
        let id: Int
        let ordered: Bool
        let ordinal: Int
        let depth: Int
        let checked: Bool?
        let text: AttributedString
    }

    enum Block: Identifiable, Sendable {
        case heading(id: Int, level: Int, text: AttributedString)
        case paragraph(id: Int, text: AttributedString)
        case list(id: Int, items: [ListItem])
        case codeBlock(id: Int, language: String?, code: String, diagram: ChatDiagramBlock?)
        case blockQuote(id: Int, text: AttributedString)
        case table(
            id: Int,
            alignments: [PresentationIntent.TableColumn.Alignment],
            headers: [AttributedString],
            rows: [[AttributedString]]
        )
        case thematicBreak(id: Int)

        var id: Int {
            switch self {
            case .heading(let id, _, _): id
            case .paragraph(let id, _): id
            case .list(let id, _): id
            case .codeBlock(let id, _, _, _): id
            case .blockQuote(let id, _): id
            case .table(let id, _, _, _): id
            case .thematicBreak(let id): id
            }
        }
    }

    let blocks: [Block]
    let truncatedToSource: Bool

    static func parse(_ source: String) -> MarkdownDocument {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            return MarkdownDocument(blocks: [], truncatedToSource: false)
        }
        guard source.utf8.count <= maxParsedUTF8Bytes else {
            return MarkdownDocument(blocks: [], truncatedToSource: true)
        }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.appliesSourcePositionAttributes = true
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        return MarkdownDocument(blocks: buildBlocks(from: parsed), truncatedToSource: false)
    }

    // MARK: - Block extraction

    private enum ActiveGroup {
        case heading(id: Int, level: Int, text: AttributedString)
        case paragraph(id: Int, text: AttributedString)
        case list(id: Int, items: [PendingListItem])
        case codeBlock(id: Int, language: String?, lines: [String])
        case blockQuote(id: Int, text: AttributedString, lastParagraphID: Int?)
        case table(id: Int, alignments: [PresentationIntent.TableColumn.Alignment], cells: [TableCoord: AttributedString])
    }

    private struct PendingListItem {
        let id: Int
        let ordered: Bool
        let ordinal: Int
        let depth: Int
        var text: AttributedString
        var lastParagraphID: Int?
    }

    private struct TableCoord: Hashable {
        let row: Int
        let column: Int
    }

    private static func buildBlocks(from parsed: AttributedString) -> [Block] {
        var output: [Block] = []
        var active: ActiveGroup?
        var syntheticID = -1

        func nextID() -> Int {
            defer { syntheticID -= 1 }
            return syntheticID
        }

        func flushActive() {
            guard let group = active else { return }
            active = nil
            switch group {
            case .heading(let id, let level, let text):
                let cleaned = trimmedAttributed(text)
                if !cleaned.characters.isEmpty {
                    output.append(.heading(id: id, level: level, text: cleaned))
                }
            case .paragraph(let id, let text):
                let cleaned = trimmedAttributed(text)
                if !cleaned.characters.isEmpty {
                    output.append(.paragraph(id: id, text: cleaned))
                }
            case .list(let id, let pendingItems):
                let items = pendingItems.compactMap { item -> ListItem? in
                    let cleaned = trimmedAttributed(item.text)
                    guard !cleaned.characters.isEmpty else { return nil }
                    let (checked, body) = extractTaskPrefix(from: cleaned)
                    return ListItem(
                        id: item.id,
                        ordered: item.ordered,
                        ordinal: item.ordinal,
                        depth: item.depth,
                        checked: checked,
                        text: body
                    )
                }
                if !items.isEmpty {
                    output.append(.list(id: id, items: items))
                }
            case .codeBlock(let id, let language, let lines):
                let code = lines.joined().replacingOccurrences(
                    of: #"\n$"#, with: "", options: .regularExpression
                )
                let diagramKind = ChatDiagramBlock.classify(label: language ?? "", source: code)
                let diagram = diagramKind.map {
                    ChatDiagramBlock(
                        kind: $0,
                        source: code,
                        original: code,
                        codeIdentity: id,
                        progressive: false
                    )
                }
                output.append(.codeBlock(id: id, language: language, code: code, diagram: diagram))
            case .blockQuote(let id, let text, _):
                let cleaned = trimmedAttributed(text)
                if !cleaned.characters.isEmpty {
                    output.append(.blockQuote(id: id, text: cleaned))
                }
            case .table(let id, let alignments, let cells):
                let columnCount = max(alignments.count, (cells.keys.map(\.column).max() ?? -1) + 1)
                let rowCount = (cells.keys.map(\.row).max() ?? -1) + 1
                guard columnCount > 0, rowCount > 0 else { return }
                let headers = (0 ..< columnCount).map { col in
                    trimmedAttributed(cells[TableCoord(row: 0, column: col)] ?? AttributedString())
                }
                var bodyRows: [[AttributedString]] = []
                for row in 1 ..< rowCount {
                    let built = (0 ..< columnCount).map { col in
                        trimmedAttributed(cells[TableCoord(row: row, column: col)] ?? AttributedString())
                    }
                    if built.contains(where: { !$0.characters.isEmpty }) {
                        bodyRows.append(built)
                    }
                }
                output.append(.table(id: id, alignments: alignments, headers: headers, rows: bodyRows))
            }
        }

        for run in parsed.runs {
            let slice = AttributedString(parsed[run.range])
            guard let intent = run.presentationIntent, !intent.components.isEmpty else {
                if !slice.characters.allSatisfy(\.isWhitespace) {
                    if case .paragraph(let id, var existing) = active {
                        existing.append(slice)
                        active = .paragraph(id: id, text: existing)
                    } else {
                        flushActive()
                        active = .paragraph(id: nextID(), text: slice)
                    }
                }
                continue
            }

            let components = intent.components
            if components.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
                flushActive()
                let id = components.first(where: { if case .thematicBreak = $0.kind { return true }; return false })?.identity ?? nextID()
                output.append(.thematicBreak(id: id))
                continue
            }

            // 1. Table
            if let tableComp = components.last(where: { if case .table = $0.kind { return true }; return false }),
               case .table(let columns) = tableComp.kind {
                var rowIndex: Int?
                var colIndex: Int?
                for comp in components {
                    switch comp.kind {
                    case .tableHeaderRow: rowIndex = 0
                    case .tableRow(let idx): rowIndex = idx
                    case .tableCell(let idx): colIndex = idx
                    default: break
                    }
                }
                if let rowIndex, let colIndex {
                    let coord = TableCoord(row: rowIndex, column: colIndex)
                    if case .table(let id, let alignments, var cells) = active, id == tableComp.identity {
                        var current = cells[coord] ?? AttributedString()
                        current.append(slice)
                        cells[coord] = current
                        active = .table(id: id, alignments: alignments, cells: cells)
                    } else {
                        flushActive()
                        active = .table(
                            id: tableComp.identity,
                            alignments: columns.map(\.alignment),
                            cells: [coord: slice]
                        )
                    }
                    continue
                }
            }

            // 2. BlockQuote (topmost)
            if let quoteComp = components.last(where: { if case .blockQuote = $0.kind { return true }; return false }) {
                let paraID = components.first(where: { if case .paragraph = $0.kind { return true }; return false })?.identity
                if case .blockQuote(let id, var existing, let lastParaID) = active, id == quoteComp.identity {
                    if let paraID, let lastParaID, paraID != lastParaID {
                        existing.append(AttributedString("\n\n"))
                    }
                    existing.append(slice)
                    active = .blockQuote(id: id, text: existing, lastParagraphID: paraID ?? lastParaID)
                } else {
                    flushActive()
                    active = .blockQuote(id: quoteComp.identity, text: slice, lastParagraphID: paraID)
                }
                continue
            }

            // 3. Code block
            if let codeComp = components.first(where: { if case .codeBlock = $0.kind { return true }; return false }),
               case .codeBlock(let lang) = codeComp.kind {
                let text = String(slice.characters)
                if case .codeBlock(let id, let existingLang, var lines) = active, id == codeComp.identity {
                    lines.append(text)
                    active = .codeBlock(id: id, language: existingLang, lines: lines)
                } else {
                    flushActive()
                    let cleanedLang = lang?.trimmingCharacters(in: .whitespacesAndNewlines)
                    active = .codeBlock(
                        id: codeComp.identity,
                        language: (cleanedLang?.isEmpty == false) ? cleanedLang : nil,
                        lines: [text]
                    )
                }
                continue
            }

            // 4. List (supports nested lists by keeping outermost list as group and computing depth)
            if let outerList = components.last(where: {
                switch $0.kind {
                case .unorderedList, .orderedList: return true
                default: return false
                }
            }), let innerItem = components.first(where: {
                if case .listItem = $0.kind { return true }; return false
            }), case .listItem(let ordinal) = innerItem.kind {
                let listKinds = components.filter {
                    switch $0.kind {
                    case .unorderedList, .orderedList: return true
                    default: return false
                    }
                }
                let isOrdered: Bool = {
                    if case .orderedList = listKinds.first?.kind { return true }
                    return false
                }()
                let depth = max(0, listKinds.count - 1)
                let paraID = components.first(where: { if case .paragraph = $0.kind { return true }; return false })?.identity

                if case .list(let id, var items) = active, id == outerList.identity {
                    if let idx = items.lastIndex(where: { $0.id == innerItem.identity }) {
                        if let paraID, let prevPara = items[idx].lastParagraphID, paraID != prevPara {
                            items[idx].text.append(AttributedString("\n"))
                        }
                        items[idx].text.append(slice)
                        items[idx].lastParagraphID = paraID ?? items[idx].lastParagraphID
                    } else {
                        items.append(PendingListItem(
                            id: innerItem.identity,
                            ordered: isOrdered,
                            ordinal: ordinal,
                            depth: depth,
                            text: slice,
                            lastParagraphID: paraID
                        ))
                    }
                    active = .list(id: id, items: items)
                } else {
                    flushActive()
                    active = .list(id: outerList.identity, items: [
                        PendingListItem(
                            id: innerItem.identity,
                            ordered: isOrdered,
                            ordinal: ordinal,
                            depth: depth,
                            text: slice,
                            lastParagraphID: paraID
                        ),
                    ])
                }
                continue
            }

            // 5. Heading
            if let headComp = components.first(where: { if case .header = $0.kind { return true }; return false }),
               case .header(let level) = headComp.kind {
                if case .heading(let id, let existingLevel, var existing) = active, id == headComp.identity {
                    existing.append(slice)
                    active = .heading(id: id, level: existingLevel, text: existing)
                } else {
                    flushActive()
                    active = .heading(id: headComp.identity, level: level, text: slice)
                }
                continue
            }

            // 6. Paragraph (default)
            if let paraComp = components.last(where: { if case .paragraph = $0.kind { return true }; return false }) {
                if case .paragraph(let id, var existing) = active, id == paraComp.identity {
                    existing.append(slice)
                    active = .paragraph(id: id, text: existing)
                } else {
                    flushActive()
                    active = .paragraph(id: paraComp.identity, text: slice)
                }
                continue
            }
        }

        flushActive()
        return output
    }

    private static func trimmedAttributed(_ text: AttributedString) -> AttributedString {
        let chars = text.characters
        guard let first = chars.firstIndex(where: { !$0.isWhitespace }),
              let last = chars.lastIndex(where: { !$0.isWhitespace }) else {
            return AttributedString()
        }
        var copy = AttributedString(text[first ... last])
        // Individual blocks are already separated into headings, lists, quotes,
        // and grid cells; clearing `presentationIntent` prevents downstream
        // bubble-level passes like `MobileMarkdownTable` from re-transforming them.
        copy.presentationIntent = nil
        return copy
    }

    private static func extractTaskPrefix(from text: AttributedString) -> (Bool?, AttributedString) {
        let raw = String(text.characters)
        if raw.hasPrefix("[ ] ") {
            let idx = text.index(text.startIndex, offsetByCharacters: 4)
            return (false, AttributedString(text[idx...]))
        }
        if raw.hasPrefix("[x] ") || raw.hasPrefix("[X] ") {
            let idx = text.index(text.startIndex, offsetByCharacters: 4)
            return (true, AttributedString(text[idx...]))
        }
        return (nil, text)
    }
}
