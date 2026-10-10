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
        .interfaceFrame(width: 640, height: 460)
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

    private func matchRow(_ match: FulltextMatch) -> some View {
        VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
            HStack {
                Text(verbatim: match.title.isEmpty ? match.key : match.title)
                    .interfaceFont(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if match.totalHits > 0 {
                    Text("mac.search.hits \(match.totalHits)")
                        .interfaceFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(match.lines, id: \.self) { line in
                highlighted(line)
                    .interfaceFont(.callout)
                    .lineLimit(2)
            }
        }
        .interfacePadding(.vertical, Space.xs)
    }

    private func highlighted(_ line: FulltextLine) -> Text {
        var attributed = AttributedString((line.role == "user" ? "› " : "") + line.text)
        let offset = line.role == "user" ? 2 : 0
        let characters = Array(attributed.characters.indices)
        for span in line.spans where span.count == 2 {
            let start = span[0] + offset, end = span[1] + offset
            guard start >= 0, end <= characters.count, start < end else { continue }
            let range = characters[start]..<(end < characters.count ? characters[end] : attributed.endIndex)
            attributed[range].foregroundColor = Palette.accent
            attributed[range].font = .callout.weight(.semibold)
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
        guard openingKey == nil, !searchStore.isSearching else { return }
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
