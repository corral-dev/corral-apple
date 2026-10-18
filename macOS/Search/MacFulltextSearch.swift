import AppKit
import SwiftUI

/// ⌘F: search every session's conversation text on the host (the TUI's Ctrl+F
/// index) and open a hit. The sidebar filter only narrows by title/project/group.
struct MacFulltextSearch: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var onOpen: (String) async throws -> Bool

    @State private var query = ""
    @State private var retrySerial = 0
    @State private var searchStore = MacFulltextSearchStore()
    /// Highlighted hit: first by default, moved by ↑/↓ in the field, opened
    /// by Return. A click selects and opens a hit directly.
    @State private var selection: String?
    @State private var openingKey: String?
    @State private var openingGeneration = UUID()
    @State private var openingTask: Task<Void, Never>?
    @State private var openingError: String?
    @FocusState private var fieldFocused: Bool
    #if DEBUG
    @Environment(MacWorkspace.self) private var workspace
    @State private var inspectionStarted = Date()
    @State private var inspectionClaimed = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm * interfaceScale) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("mac.search.placeholder", text: Binding(get: { query }, set: editQuery))
                    .textFieldStyle(.plain)
                    .interfaceFont(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openSelection() }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                if searchStore.isSearching || openingKey != nil {
                    ProgressView().interfaceControlSize(.small)
                }
                Button {
                    dismissSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .interfaceFont(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                // Escape stays with onExitCommand, after any input method.
                .help(Text("action.dismiss"))
                .accessibilityLabel(Text("action.dismiss"))
            }
            .interfacePadding(Space.md)
            Divider()
            // States crossfade; rows inside the results do not animate while typing.
            ZStack { results }
                .animation(MacMotion.crossfade, value: resultsState)
            if let openingError {
                Text(verbatim: openingError)
                    .foregroundStyle(.red)
                    .interfacePadding(Space.md)
            }
        }
        .interfaceFrame(width: SearchMetrics.panelWidth, height: SearchMetrics.panelHeight)
        .onAppear {
            fieldFocused = true
            #if DEBUG
            if let preset = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SEARCH"] {
                query = preset
            }
            #endif
        }
        .task(id: SearchConnectionKey(query: query, client: appModel.clientIdentity, ready: appModel.connectionState == .connected, retry: retrySerial)) {
            searchStore.prepare(query, client: appModel.client)
            #if DEBUG
            inspectionStarted = Date()
            if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SEARCH_ACTION"] == "loading" {
                try? await Task.sleep(for: .seconds(6))
            }
            #endif
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await searchStore.search(query, client: appModel.client) { client in appModel.client === client }
        }
        .onChange(of: appModel.clientIdentity) { _, _ in cancelOpening(); searchStore.invalidate(); searchStore.prepare(query, client: appModel.client) }
        .onChange(of: appModel.connectionState) { _, _ in cancelOpening(); searchStore.invalidate(); searchStore.prepare(query, client: appModel.client) }
        .onDisappear { cancelOpening(); searchStore.invalidate() }
        .onExitCommand { dismissSearch() }
        #if DEBUG
        .onChange(of: searchStore.result?.matches.map(\.key)) { _, keys in
            guard !inspectionClaimed, let keys, !keys.isEmpty,
                  ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SEARCH_ACTION"] == "open" else { return }
            inspectionClaimed = true
            let target = keys.first { workspace.feed?.listStore.session(for: $0) == nil } ?? keys[0]
            writeInspection(["search_ms": Date().timeIntervalSince(inspectionStarted) * 1000,
                "matches": keys.count, "uncached": workspace.feed?.listStore.session(for: target) == nil])
            Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, searchStore.result?.matches.contains(where: { $0.key == target }) == true else { return }
                selection = target
                openSelection()
            }
        }
        #endif
    }

    @ViewBuilder
    private var results: some View {
        if let errorMessage = searchStore.errorMessage {
            ContentUnavailableView {
                Label("mac.search.failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: errorMessage)
            } actions: {
                Button("action.retry") { retrySearch() }
            }
            .interfaceFrame(maxHeight: .infinity)
            .transition(.opacity)
        } else if let result = searchStore.result, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if result.matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .interfaceFrame(maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(result.matches) { match in
                        Button { openMatch(match.key) } label: { matchRow(match) }
                            .buttonStyle(.plain)
                            .disabled(openingKey != nil)
                            .tag(match.key).id(match.key)
                    }
                    if result.total > result.matches.count {
                        Text("mac.search.more \(result.total - result.matches.count)")
                            .interfaceFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .onKeyPress(.return) { openSelection(); return .handled }
                .focusEffectDisabled()
                .onChange(of: selection) { _, key in
                    if let key { proxy.scrollTo(key) }
                }
                }
                .onAppear { highlightFirst(of: result) }
                .onChange(of: result.matches.map(\.key)) { _, _ in highlightFirst(of: result) }
                .transition(.opacity)
            }
        } else if searchStore.isSearching {
            ProgressView()
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else {
            Text("mac.search.hint")
                .foregroundStyle(.secondary)
                .interfaceFrame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        }
    }

    private enum ResultsState: Equatable { case hint, searching, failed, empty, matches }

    /// Which of the four result states `results` shows (mirrors its branches).
    private var resultsState: ResultsState {
        if searchStore.errorMessage != nil { return .failed }
        if searchStore.isSearching { return .searching }
        guard let result = searchStore.result, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return .hint }
        return result.matches.isEmpty ? .empty : .matches
    }

    /// Glyph column, then the session line, project/hits line and snippets.
    /// Design: docs/design/MACOS_CLIENT_DESIGN.md, full-text search presentation.
    private func matchRow(_ match: FulltextMatch) -> some View {
        HStack(alignment: .top, spacing: Space.sm * interfaceScale) {
            RuntimeGlyph(runtimeID: match.session?.runtime, size: SearchMetrics.glyph)
                .interfaceFrame(height: SearchMetrics.titleLineHeight, alignment: .center)
                .help(Text(verbatim: Palette.runtimeDisplayName(match.session?.runtime)))
            VStack(alignment: .leading, spacing: SearchMetrics.snippetSpacing * interfaceScale) {
                VStack(alignment: .leading, spacing: SearchMetrics.metaSpacing * interfaceScale) {
                    titleLine(match)
                    metaLine(match)
                }
                ForEach(Array(match.lines.enumerated()), id: \.offset) { _, line in
                    snippet(line, runtime: match.session?.runtime)
                }
            }
        }
        .interfacePadding(.vertical, Space.sm)
        .accessibilityElement(children: .combine)
    }

    private func titleLine(_ match: FulltextMatch) -> some View {
        HStack(spacing: Space.sm * interfaceScale) {
            Text(verbatim: match.title.isEmpty ? match.key : match.title)
                .interfaceFont(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Space.sm * interfaceScale)
            if let session = match.session, session.mtime > 0 {
                Text(verbatim: MacSidebarMetrics.compactTime(for: session, now: Date()))
                    .interfaceFont(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .interfaceFrame(height: SearchMetrics.titleLineHeight)
    }

    /// Project in the sidebar's project ink, then the hit count.
    @ViewBuilder
    private func metaLine(_ match: FulltextMatch) -> some View {
        let project = match.session.map(SessionPresentation.projectName(from:)) ?? ""
        HStack(spacing: Space.xs * interfaceScale) {
            if !project.isEmpty {
                Text(verbatim: project == "~" ? String(localized: "sessions.project.home") : project)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.sessionProject(selected: selection == match.key))
                    .lineLimit(1)
                if match.totalHits > 0 {
                    Text(verbatim: "·")
                }
            }
            if match.totalHits > 0 {
                Text("mac.search.hits \(match.totalHits)")
                    .fixedSize()
            }
        }
        .interfaceFont(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    /// One hit line: role mark, then up to three lines with the keywords marked.
    private func snippet(_ line: FulltextLine, runtime: String?) -> some View {
        HStack(alignment: .top, spacing: Space.sm * interfaceScale) {
            Group {
                if line.role == "user" {
                    Image(systemName: "person.fill")
                        .interfaceFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("chat.role.user"))
                } else {
                    RuntimeGlyph(runtimeID: runtime, size: SearchMetrics.roleGlyph)
                        .accessibilityLabel(Text("chat.role.assistant"))
                }
            }
            .interfaceFrame(width: SearchMetrics.roleGlyph, height: SearchMetrics.snippetLineHeight)
            highlighted(line)
                .interfaceFont(.system(size: 14))
                .foregroundStyle(line.role == "user" ? Color.primary : Color.secondary)
                .lineSpacing(SearchMetrics.lineSpacing * interfaceScale)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Server spans count Unicode scalars (Python string offsets). A first hit
    /// beyond the visible start reopens the line shortly before it.
    private func highlighted(_ line: FulltextLine) -> Text {
        let spans = line.spans.filter { $0.count == 2 && $0[0] >= 0 && $0[0] < $0[1] }
        var scalars = Array(line.text.unicodeScalars)
        var shift = 0
        if let first = spans.first?[0], first > SearchMetrics.maxLeadScalars {
            let start = first - SearchMetrics.windowLead
            scalars = Array("…".unicodeScalars) + scalars[start...]
            shift = 1 - start
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars)
        var attributed = AttributedString(String(text))
        let view = attributed.unicodeScalars
        for span in spans {
            let start = span[0] + shift, end = span[1] + shift
            guard start >= 0, end <= scalars.count else { continue }
            let lower = view.index(view.startIndex, offsetBy: start)
            let upper = view.index(view.startIndex, offsetBy: end)
            attributed[lower..<upper].foregroundColor = Palette.accent
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    private func editQuery(_ text: String) {
        cancelOpening()
        query = text
        selection = nil
        openingError = nil
        searchStore.prepare(text, client: appModel.client)
    }

    private func dismissSearch() {
        cancelOpening()
        searchStore.invalidate()
        dismiss()
    }

    private func retrySearch() {
        searchStore.invalidate()
        searchStore.prepare(query, client: appModel.client)
        retrySerial += 1
    }

    private func openSelection() {
        if searchStore.errorMessage != nil { retrySearch(); return }
        guard let matches = searchStore.result?.matches, !matches.isEmpty else { return }
        let key = matches.first { $0.key == selection }?.key ?? matches[0].key
        openMatch(key)
    }

    private func openMatch(_ key: String) {
        guard openingKey == nil else { return }
        // Opening wins over a running search: cancel the search first so
        // Return never looks dead while results stream in.
        if searchStore.isSearching { searchStore.invalidate() }
        openingKey = key
        openingError = nil
        let mine = UUID()
        openingGeneration = mine
        openingTask = Task {
            defer {
                if openingGeneration == mine { openingKey = nil; openingTask = nil }
            }
            do {
                #if DEBUG
                let started = Date()
                #endif
                if try await onOpen(key), !Task.isCancelled {
                    #if DEBUG
                    if inspectionClaimed {
                        writeInspection(["open_ms": Date().timeIntervalSince(started) * 1000,
                            "opened": workspace.focusedKey == key,
                            "summary_resolved": workspace.feed?.listStore.session(for: key) != nil])
                    }
                    #endif
                    dismiss()
                }
            } catch {
                guard !Task.isCancelled, openingGeneration == mine else { return }
                openingError = SessionActionsMenu.failureMessage(for: error)
            }
        }
    }

    #if DEBUG
    private func writeInspection(_ values: [String: Any]) {
        let url = URL(fileURLWithPath: "/tmp/corral-search-acceptance.json")
        var record = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        record.merge(values) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif

    private func cancelOpening() {
        openingGeneration = UUID()
        openingTask?.cancel()
        openingTask = nil
        openingKey = nil
    }

    private func highlightFirst(of result: FulltextSearchResponse) {
        guard let first = result.matches.first?.key, selection != first else { return }
        selection = first
    }

    /// ↑/↓ while typing. An input method composing text keeps the arrow keys
    /// (candidate selection), so they pass through untouched.
    private func moveHighlight(by step: Int) -> KeyPress.Result {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return .ignored
        }
        guard let matches = searchStore.result?.matches, !matches.isEmpty else { return .ignored }
        let index = matches.firstIndex { $0.key == selection } ?? -1
        let next = min(max(index + step, 0), matches.count - 1)
        guard matches[next].key != selection else { return .handled }
        selection = matches[next].key
        return .handled
    }

}

private struct SearchConnectionKey: Hashable {
    let query: String
    let client: ObjectIdentifier?
    let ready: Bool
    let retry: Int
}

/// Result geometry (owner request 2026-10-18); sizes follow interface zoom.
private enum SearchMetrics {
    static let panelWidth: CGFloat = 760
    static let panelHeight: CGFloat = 560
    static let glyph: CGFloat = 16
    static let roleGlyph: CGFloat = 13
    static let titleLineHeight: CGFloat = 20
    static let snippetLineHeight: CGFloat = 18
    static let metaSpacing: CGFloat = 2
    static let snippetSpacing: CGFloat = 6
    static let lineSpacing: CGFloat = 3
    /// A first hit later than this many scalars (about two CJK lines) is moved into view…
    static let maxLeadScalars = 90
    /// …keeping this much context before it.
    static let windowLead = 20
}

