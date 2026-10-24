import Foundation
import AppKit
import Observation
import os

/// Transport double deliberately ignores cancellation, like an in-flight RPC.
@MainActor
final class RemoteClient {
    var calls: [(String, [String: Any])] = []
    struct Capabilities {
        var sessionCreateReceipts = false
        var desktopLayout = true
        var terminalPrompt = true
        var terminalPromptDirect = false
    }
    var hostCapabilities = Capabilities()
    var readyHandlers: [UUID: @MainActor () -> Void] = [:]
    var subscriptions: [String: AsyncStream<RemoteEvent>.Continuation] = [:]
    func subscribe(channel: String) -> AsyncStream<RemoteEvent> {
        AsyncStream { subscriptions[channel] = $0 }
    }
    func addReadyHandler(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); readyHandlers[id] = handler; return id
    }
    func removeReadyHandler(_ id: UUID) { readyHandlers[id] = nil }
    func emit(_ payload: [String: Any], channel: String) { subscriptions[channel]?.yield(RemoteEvent(data: payload)) }
    func ready() { for handler in Array(readyHandlers.values) { handler() } }
    var handler: (@MainActor (String, [String: Any]) async throws -> Any)?

    @discardableResult
    func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        calls.append((method, params))
        return try await handler?(method, params) ?? [:]
    }

    func call<T: Decodable>(_ method: String, params: [String: Any] = [:], as type: T.Type) async throws -> T {
        let value = try await call(method, params: params)
        if let typed = value as? T { return typed }
        return try RemoteJSONDecoder.decode(type, from: value)
    }
}

struct RemoteCallError: Error { let message: String; var code = "" }

struct RemoteEvent: @unchecked Sendable { let data: [String: Any] }
enum WireProtocol {
    static let mShellList = "shell.list", mShellOpen = "shell.open", mShellClose = "shell.close"
    static let mSearchFulltext = "search.fulltext", chLayout = "layout", eUsage = "usage_error"
    static let mLayoutRemoveSession = "layout.removeSession", mLayoutSetFocus = "layout.setFocus"
    static let mLayoutSetGroup = "layout.setGroup", mLayoutWatch = "layout.watch", mLayoutUnwatch = "layout.unwatch"
    static let mLayoutRenameGroup = "layout.renameGroup"
    static let mLayoutPin = "layout.pin", mLayoutPinGroup = "layout.pinGroup", mLayoutCollapse = "layout.collapse"
    static let mRuntimesList = "runtimes.list", mSessionCopy = "session.copy", mSessionHandoff = "session.handoff"
    static let mSessionRestart = "session.restart", mSessionStop = "session.stop", mSessionResume = "session.resume"
    static let mSessionUserPrompts = "session.userPrompts"
    static let mSessionNew = "session.new", mSessionGet = "session.get", mSessionDelete = "session.delete"
    static let mTerminalAttach = "terminal.attach", mTerminalDetach = "terminal.detach"
    static let mTerminalResize = "terminal.resize", mTerminalInput = "terminal.input"
    static let mTerminalResync = "terminal.resync", mInputText = "input.text"
    static let mTerminalTheme = "terminal.theme"
    static func terminalChannel(sessionKey: String) -> String { "term:" + sessionKey }
}
struct SessionSummary: Codable { var key: String; var cwd = ""; var hosted = false }
struct SessionUserPromptsResponse: Decodable {
    struct Prompt: Decodable { let seq: Int; let text: String? }
    let prompts: [Prompt]
    let generation: Int
}
enum ActiveRuntimeVisibility { static func isListVisible(_ session: SessionSummary) -> Bool { true } }
struct RuntimeEntry: Decodable { var id: String; var isActive: Bool { true } }
@MainActor final class AppModel {
    var client: RemoteClient?
    let restarts = SessionRestartTracker()
}
@MainActor final class SessionListStore {
    var sessions: [String: SessionSummary] = [:]
    var windowSessions: [SessionSummary] { Array(sessions.values) }
    var opened: Set<String> = []
    func patchSession(_ session: SessionSummary) { sessions[session.key] = session }
    func applySessionEvent(_ session: SessionSummary) { sessions[session.key] = session }
    func rememberOpened(_ session: SessionSummary) { opened.insert(session.key) }
    func revealSession(_ session: SessionSummary) { rememberOpened(session); patchSession(session) }
    func isDeleted(_ key: String) -> Bool { false }
    func session(for key: String) -> SessionSummary? { sessions[key] }
    func resolvedKey(_ key: String) -> String { key }
    func removeSession(key: String) { sessions[key] = nil }
}
@MainActor final class HostSessionFeed { var listStore = SessionListStore() }
@MainActor final class MacPaneSurfaceCache {
    func reset() {}
    func evict(_ key: String) {}
}

// This transport-only harness has no mounted views. Native reading restoration
// is verified by the real app/table scenario instead.
extension MacWorkspace { func rememberReadingPosition() {} }

// The standalone lifecycle probe does not link the SwiftTerm view. Its
// workspace fixtures have no laid-out terminal body; fitting is an Xcode/runtime check.
enum TerminalAppearance {
    static func fittingGrid(for size: CGSize, interfaceScale: CGFloat = 1) -> TerminalGrid? {
        preconditionFailure("Terminal geometry requires the native app acceptance path")
    }
}

enum SessionActionsMenu {
    static func decodeNewSession(from value: Any) throws -> SessionSummary {
        if let session = value as? SessionSummary { return session }
        guard let payload = value as? [String: Any], let session = payload["session"] else { throw ProbeError.failed }
        return try RemoteJSONDecoder.decode(SessionSummary.self, from: session)
    }
    static func failureMessage(for error: Error) -> String { error.localizedDescription }
}

@MainActor
final class Gate {
    struct Value: @unchecked Sendable { let raw: Any }
    var continuation: CheckedContinuation<Value, any Error>?
    func wait() async throws -> Any {
        try await withCheckedThrowingContinuation { continuation = $0 }.raw
    }
    func succeed(_ value: Any) { continuation?.resume(returning: Value(raw: value)); continuation = nil }
    func fail() { continuation?.resume(throwing: ProbeError.failed); continuation = nil }
}
enum ProbeError: Error { case failed }
@MainActor final class Flag { var value = false }
@MainActor final class Sink: TerminalStreamSink {
    var reveals: [String] = []
    var revealResult = true
    func terminalRevealPrompt(_ query: String) -> Bool { reveals.append(query); return revealResult }
    var resets = 0, outputs = 0
    func terminalReset(grid: TerminalGrid, data: Data) { resets += 1 }
    func terminalFeed(_ data: Data) { outputs += 1 }
}

@main
struct LifecycleProbe {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    @MainActor static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
    @MainActor static func response(_ key: String) throws -> FulltextSearchResponse {
        try RemoteJSONDecoder.decode(FulltextSearchResponse.self, from: [
            "total": 1, "matches": [["key": key, "title": key, "lines": []]],
        ])
    }
    @MainActor static func searchRegressions() async throws {
        let client = RemoteClient(), store = FulltextSearchStore(), old = Gate(), fresh = Gate()
        client.handler = { _, params in try await (params["q"] as? String == "old" ? old : fresh).wait() }
        let a = Task { await store.search("old", client: client) { $0 === client } }
        await settle()
        store.invalidate()
        let b = Task { await store.search("new", client: client) { $0 === client } }
        await settle()
        fresh.succeed(try response("new")); await b.value
        old.fail(); await a.value
        check(store.result?.matches.first?.key == "new" && store.errorMessage == nil,
              "old failure replaced a newer successful search")

        let pending = Gate()
        client.handler = { _, _ in try await pending.wait() }
        let c = Task { await store.search("same", client: client) { $0 === client } }
        await settle(); store.invalidate()
        check(!store.isSearching && store.result == nil && store.errorMessage == nil,
              "clearing/dismissing a search retained old presentation")
        pending.succeed(try response("stale")); await c.value
        check(store.result == nil, "late response repopulated cleared search")

        let canceled = Gate()
        client.handler = { _, _ in try await canceled.wait() }
        let d = Task { await store.search("cancel", client: client) { $0 === client } }
        await settle(); d.cancel(); canceled.fail(); await d.value
        check(store.errorMessage == nil && !store.isSearching, "cancelled failure became a visible error")

        let replaced = Gate(); var current = true
        client.handler = { _, _ in try await replaced.wait() }
        let e = Task { await store.search("host", client: client) { _ in current } }
        await settle(); current = false
        replaced.succeed(try response("other-host")); await e.value
        check(store.result == nil, "replaced client's response was accepted")
        var attempts = 0
        client.handler = { _, _ in
            attempts += 1
            if attempts == 1 { throw ProbeError.failed }
            return try response("recovered")
        }
        await store.search("retry", client: client) { $0 === client }
        check(attempts == 2 && store.result?.matches.first?.key == "recovered" && store.errorMessage == nil,
              "transient read-only search failure was not retried")
        let calls = client.calls.count
        store.prepare("  retry  ", client: client)
        check(!store.isSearching && store.result != nil, "equal trimmed query discarded completed result")
        await store.search("  retry  ", client: client) { $0 === client }
        check(client.calls.count == calls, "equal trimmed query repeated remote search")
        store.prepare("edited", client: client)
        check(store.isSearching && store.result == nil, "debounce interval has no loading feedback")
        store.prepare("  ", client: client)
        check(!store.isSearching && store.result == nil, "blank query retained loading")

        // Hosts before search.fulltext answer usage_error: no retries, no error, no repeat calls.
        let legacy = RemoteClient(), legacyStore = FulltextSearchStore()
        legacy.handler = { _, _ in throw RemoteCallError(message: "unsupported", code: "usage_error") }
        await legacyStore.search("body", client: legacy) { $0 === legacy }
        check(legacyStore.isUnsupported && legacyStore.errorMessage == nil && legacy.calls.count == 1,
              "older host was retried or reported as a failure")
        legacyStore.prepare("next", client: legacy)
        await legacyStore.search("next", client: legacy) { $0 === legacy }
        check(!legacyStore.isSearching && legacy.calls.count == 1, "known older host was asked again")
        print("PASS search: stale failure, cleared query, cancellation, replaced client, transient retry, older host")
    }
    @MainActor static func searchOpeningRegressions() async throws {
        let model = AppModel(), client = RemoteClient(), feed = HostSessionFeed(), workspace = MacWorkspace()
        model.client = client
        workspace.attach(appModel: model)
        workspace.selectHost("a")
        workspace.feed = feed
        client.handler = { _, _ in SessionSummary(key: "old-history", cwd: "acceptance") }
        let opened = try await workspace.openSearchResult("old-history")
        check(opened && workspace.focusedKey == "old-history" && feed.listStore.session(for: "old-history") != nil,
              "uncached full-text hit opened a pane without a summary")
        check(feed.listStore.opened.contains("old-history"), "opened history was not retained")
        let calls = client.calls.count
        _ = try await workspace.openSearchResult("old-history")
        check(client.calls.count == calls, "cached history repeated session.get")
        let pending = Gate()
        client.handler = { _, _ in try await pending.wait() }
        let task = Task { try await workspace.openSearchResult("other-history") }
        await settle()
        workspace.selectHost("b")
        pending.succeed(SessionSummary(key: "other-history"))
        let staleOpened = try await task.value
        check(!staleOpened && workspace.paneKeys.isEmpty && feed.listStore.session(for: "other-history") == nil,
              "late lookup opened history on another host")
        workspace.feed = feed
        let canceled = Gate()
        client.handler = { _, _ in try await canceled.wait() }
        let canceledTask = Task { try await workspace.openSearchResult("canceled") }
        await settle(); canceledTask.cancel()
        canceled.succeed(SessionSummary(key: "canceled"))
        let canceledOpened = try await canceledTask.value
        check(!canceledOpened && workspace.paneKeys.isEmpty, "dismissed search still navigated")
        client.handler = { _, _ in throw ProbeError.failed }
        do {
            _ = try await workspace.openSearchResult("missing")
            preconditionFailure("lookup failure opened a pane")
        } catch { check(workspace.paneKeys.isEmpty, "lookup failure changed workspace") }
        print("PASS search opening: uncached history, cached fast path, host switch, cancellation, failure")
    }
    @MainActor static func resumeRegressions() async throws {
        let model = AppModel(), client = RemoteClient(), feed = HostSessionFeed(), workspace = MacWorkspace()
        model.client = client; workspace.attach(appModel: model); workspace.selectHost("a"); workspace.feed = feed
        feed.listStore.patchSession(SessionSummary(key: "ended"))
        client.handler = { _, _ in ["session": ["key": "ended", "cwd": "acceptance", "hosted": true]] }
        let resumed = await workspace.resume("ended")
        check(resumed && feed.listStore.session(for: "ended")?.hosted == true,
              "successful resume waited for a list broadcast to mark the pane hosted")
        feed.listStore.patchSession(SessionSummary(key: "ended"))
        await workspace.restart("ended")
        check(feed.listStore.session(for: "ended")?.hosted == true,
              "explicit restart waited for a list broadcast to mark the pane hosted")
        let pending = Gate()
        client.handler = { _, _ in try await pending.wait() }
        let old = Task { await workspace.resume("ended") }
        await settle(); workspace.selectHost("b")
        let next = HostSessionFeed(); workspace.feed = next
        pending.succeed(["session": ["key": "ended", "cwd": "acceptance", "hosted": true]])
        let accepted = await old.value
        check(!accepted && next.listStore.session(for: "ended") == nil,
              "a late resume response changed the next host's feed")
        print("PASS resume: immediate hosted state, explicit restart, stale host response")
    }
    @MainActor static func workspaceRegressions() async throws {
        let model = AppModel(), workspace = MacWorkspace(), a = RemoteClient(), b = RemoteClient()
        let oldLayout = Gate(), fork = Gate()
        let delayed = Flag()
        a.handler = { method, _ in
            if method == WireProtocol.mLayoutWatch {
                if delayed.value { return try await oldLayout.wait() }
                return DesktopLayout(revision: 100, groups: [], pinnedSessions: ["a": 1])
            }
            if method == WireProtocol.mSessionCopy { return try await fork.wait() }
            return ["runtimes": []] as [String: Any]
        }
        b.handler = { method, _ in
            if method == WireProtocol.mLayoutWatch {
                return DesktopLayout(revision: 5, groups: [], pinnedSessions: ["b": 1])
            }
            return ["runtimes": []] as [String: Any]
        }
        model.client = a; workspace.attach(appModel: model); workspace.selectHost("a")
        workspace.startLayoutWatch(); await settle()
        check(workspace.layout.revision == 100, "host A layout did not load")
        workspace.restorePanes(["same", "a"]); workspace.setMode(.terminal, for: "same")
        workspace.promptsOpen = ["a": true]
        delayed.value = true; a.ready(); await settle()
        let creating = Task { await workspace.fork(SessionSummary(key: "a")) }
        await settle()
        model.client = b; workspace.selectHost("b"); workspace.startLayoutWatch(); await settle()
        check(workspace.layout.revision == 5 && workspace.layout.pinnedSessions["b"] != nil,
              "lower revision on host B was rejected")
        check(workspace.paneKeys.isEmpty && workspace.focusedKey == nil
              && workspace.promptsOpen.isEmpty && workspace.mode(for: "same") == .chat,
              "switching hosts retained another machine's workspace state")
        oldLayout.succeed(DesktopLayout(revision: 200, groups: [], pinnedSessions: ["a": 1]))
        fork.succeed(SessionSummary(key: "late-a")); await creating.value; await settle()
        check(workspace.layout.revision == 5 && workspace.paneKeys.isEmpty,
              "obsolete host response changed new host layout or panes")
        // A queued background layout change must not execute on the next host.
        model.client = b; workspace.selectHost("b"); workspace.restorePanes(["b"])
        workspace.addPane("b2", project: "b-project")
        let writesBefore = a.calls.count
        model.client = a; workspace.selectHost("a"); await settle()
        check(a.calls.count == writesBefore, "queued host B group write ran on host A")
        check(workspace.mode(for: "same") == .terminal, "host-scoped pane mode was not remembered")
        workspace.stopLayoutWatch()
        print("PASS workspace: lower host revision, clean switch, late layout/fork, scoped modes")
    }
    @MainActor static func terminalRegressions() async throws {
        let client = RemoteClient(), stream = RemoteTerminalStream(sessionKey: "reconnect", client: client), sink = Sink()
        stream.sink = sink; stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        let snapshot: [String: Any] = ["kind": "snapshot", "seq": 100, "cols": 80, "rows": 24,
                                        "data": Data("screen".utf8).base64EncodedString()]
        client.emit(snapshot, channel: "term:reconnect"); await settle()
        check(stream.phase == .live, "initial snapshot was not live")
        client.ready(); await settle()
        check(client.calls.filter { $0.0 == WireProtocol.mTerminalAttach }.count == 2,
              "connection recovery did not reattach")
        check(stream.phase == .connecting, "reconnect retained a stale live state")
        var fresh = snapshot; fresh["seq"] = 1
        client.emit(fresh, channel: "term:reconnect"); await settle()
        check(sink.resets == 2 && stream.phase == .live, "reconnect rejected reset stream sequence")
        stream.stop(); await settle()
        check(client.readyHandlers.isEmpty, "stopped terminal retained a ready handler")

        let slow = RemoteClient(), gate = Gate()
        slow.handler = { method, _ in
            if method == WireProtocol.mTerminalAttach { return try await gate.wait() }
            return [:] as [String: Any]
        }
        let closed = RemoteTerminalStream(sessionKey: "close", client: slow)
        closed.start(); closed.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        closed.stop(); gate.succeed([:] as [String: Any]); await settle()
        check(slow.calls.map(\.0) == [WireProtocol.mTerminalAttach, WireProtocol.mTerminalDetach],
              "close during attach did not release the host subscription")

        let replacementClient = RemoteClient(), firstAttach = Gate()
        let delayedAttach = Flag()
        replacementClient.handler = { method, _ in
            if method == WireProtocol.mTerminalAttach, !delayedAttach.value {
                delayedAttach.value = true; return try await firstAttach.wait()
            }
            return [:] as [String: Any]
        }
        let old = RemoteTerminalStream(sessionKey: "replace", client: replacementClient)
        old.start(); old.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle(); old.stop()
        let new = RemoteTerminalStream(sessionKey: "replace", client: replacementClient)
        new.start(); new.updateFit(TerminalGrid(cols: 90, rows: 30)); await settle()
        firstAttach.succeed([:] as [String: Any]); await settle()
        check(replacementClient.calls.map(\.0) == [WireProtocol.mTerminalAttach, WireProtocol.mTerminalDetach,
                                                  WireProtocol.mTerminalAttach],
              "old view detached a replacement attachment")
        new.stop(); await settle()

        let resizing = RemoteClient(), failed = Flag()
        resizing.handler = { method, _ in
            if method == WireProtocol.mTerminalResize, !failed.value { failed.value = true; throw ProbeError.failed }
            return [:] as [String: Any]
        }
        let fitted = RemoteTerminalStream(sessionKey: "resize", client: resizing)
        fitted.start(); fitted.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        fitted.updateFit(TerminalGrid(cols: 100, rows: 30))
        try? await Task.sleep(for: .milliseconds(600)); await settle()
        check(resizing.calls.filter { $0.0 == WireProtocol.mTerminalResize }.count == 2,
              "transient resize failure did not retry unchanged fit")
        fitted.updateFit(TerminalGrid(cols: 100, rows: 30))
        try? await Task.sleep(for: .milliseconds(200))
        check(resizing.calls.filter { $0.0 == WireProtocol.mTerminalResize }.count == 2,
              "successful resize acknowledgement was not retained")
        fitted.stop(); await settle()
        print("PASS terminal: reattach/snapshot, close during attach, replacement ordering, resize retry")
    }
    @MainActor static func promptNavigationRegressions() async {
        let client = RemoteClient(), stream = RemoteTerminalStream(sessionKey: "prompt", client: client), sink = Sink()
        stream.sink = sink; stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        client.emit(["kind": "snapshot", "seq": 1, "cols": 80, "rows": 24,
                     "data": Data("screen".utf8).base64EncodedString()], channel: "term:prompt")
        await settle()
        client.handler = { _, _ in ["query": "host resolved text"] }
        let error = await stream.navigatePrompt(seq: 7, historyGeneration: 9)
        check(error == .landed && sink.reveals == ["host resolved text"], "local navigation did not use host identity")
        check(!client.calls.contains { $0.1["native"] as? Bool == true }, "local jump sent agent input")
        sink.revealResult = false
        let attempts = sink.reveals.count
        let miss = await stream.navigatePrompt(seq: 8, historyGeneration: 9)
        check(miss == .failed, "missing buffer did not report a row-level failure")
        check(sink.reveals.count == attempts + 1, "unavailable host text was repeatedly searched without a new snapshot")
        check(!client.calls.contains { $0.1["native"] as? Bool == true }, "history miss sent native navigation")
        // The offset proves the host still retains the target. Only an
        // ordered snapshot supplies it; a resolve response cannot move a view.
        let resets = sink.resets
        client.handler = { method, params in
            if method == "terminal.prompt" { return ["query": "older retained text", "offset": 1800] }
            if method == WireProtocol.mTerminalResync {
                check(params["history"] as? Int == 10_000, "prompt resync did not request retained history")
                sink.revealResult = true
                client.emit(["kind": "snapshot", "seq": 2, "cols": 80, "rows": 24,
                             "data": Data("older history".utf8).base64EncodedString()], channel: "term:prompt")
            }
            return [:]
        }
        let retainedResult = await stream.navigatePrompt(seq: 8, historyGeneration: 9)
        check(retainedResult == .landed, "retained history did not report arrival")
        check(sink.resets > resets && sink.reveals.last == "older retained text", "extended snapshot was not revealed")
        client.handler = { _, _ in throw NSError(domain: "fixture", code: 1) }
        let failedResult = await stream.navigatePrompt(seq: 8, historyGeneration: 9)
        check(failedResult == .failed && stream.phase == .live,
              "optional lookup failure affected the live terminal")
        let gate = Gate()
        client.handler = { method, _ in
            if method == "terminal.prompt" { return try await gate.wait() }
            return [:]
        }
        let pending = Task { await stream.navigatePrompt(seq: 9, historyGeneration: 9) }
        await settle()
        let reveals = sink.reveals.count
        stream.stop()
        gate.succeed(["query": "late old session"])
        _ = await pending.value
        check(sink.reveals.count == reveals, "late resolve navigated a retired terminal")
        stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        client.emit(["kind": "snapshot", "seq": 1, "cols": 80, "rows": 24,
                     "data": Data("screen".utf8).base64EncodedString()], channel: "term:prompt")
        await settle()
        let older = Gate()
        client.handler = { method, params in
            if method == "terminal.prompt", params["seq"] as? Int == 10 { return try await older.wait() }
            return ["query": "new selection"]
        }
        sink.revealResult = true
        let oldRequest = Task { await stream.navigatePrompt(seq: 10, historyGeneration: 9) }
        await settle()
        _ = await stream.navigatePrompt(seq: 11, historyGeneration: 9)
        let latestReveals = sink.reveals
        older.succeed(["query": "obsolete selection"])
        _ = await oldRequest.value
        check(sink.reveals == latestReveals, "older selection navigated after a newer selection")
        let typingGate = Gate()
        client.handler = { method, _ in
            if method == "terminal.prompt" { return try await typingGate.wait() }
            return [:]
        }
        let beforeTyping = sink.reveals
        let interrupted = Task { await stream.navigatePrompt(seq: 12, historyGeneration: 9) }
        await settle()
        stream.input.send(Array("next ordinary message\r".utf8)[...])
        await settle()
        typingGate.succeed(["query": "old selection", "offset": 1800])
        _ = await interrupted.value
        check(sink.reveals == beforeTyping, "late prompt lookup took over after ordinary input")
        check(client.calls.contains { $0.0 == WireProtocol.mTerminalInput }, "prompt lookup blocked ordinary input")
        client.hostCapabilities.terminalPromptDirect = true
        let nativeStart = client.calls.count
        let localReveals = sink.reveals
        client.handler = { _, params in
            if params["native"] as? Bool == true { return [:] }
            return ["query": "fullscreen native prompt", "occurrence": 2, "total": 3]
        }
        _ = await stream.navigatePrompt(seq: 35, historyGeneration: 9)
        let nativeCalls = Array(client.calls.dropFirst(nativeStart)).filter { $0.0 == "terminal.prompt" }
        check(nativeCalls.count == 2, "fullscreen host was not asked to locate the selected prompt")
        check(nativeCalls.last?.1["native"] as? Bool == true, "native capability was ignored")
        check(nativeCalls[0].1["navigation"] as? String == nativeCalls[1].1["navigation"] as? String,
              "native phase lost navigation identity")
        check(nativeCalls[1].1["seq"] as? Int == 35 && nativeCalls[1].1["generation"] as? Int == 9,
              "native phase used card text instead of history identity")
        check(sink.reveals == localReveals, "fullscreen target was falsely resolved from a pinned local header")
        client.handler = { _, params in
            if params["native"] as? Bool == true { throw NSError(domain: "native fixture", code: 2) }
            return ["query": "native miss"]
        }
        let nativeMiss = await stream.navigatePrompt(seq: 36, historyGeneration: 9)
        check(nativeMiss == .failed && stream.phase == .live, "native failure damaged the terminal")
        stream.input.send(Array("ordinary typing after native failure".utf8)[...])
        await settle()
        check(client.calls.last?.0 == WireProtocol.mTerminalInput, "native failure blocked ordinary typing")
        stream.stop()
        print("PASS prompt lifecycle: host identity, local read-only path, silent miss, retired response")
    }

    @MainActor static func selectionCopyRegressions() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 2000))
        text.isEditable = false
        text.isSelectable = true
        text.string = "Selected message range\n" + String(repeating: "Long reply\n", count: 200)
        scroll.documentView = text
        window.contentView = scroll
        check(window.makeFirstResponder(text), "message text could not become responder")
        let workspace = MacWorkspace()
        workspace.paneFrames["message"] = CGRect(x: 0, y: 0, width: 640, height: 400)
        let serial = workspace.keyFocusSerial
        text.setSelectedRange(NSRange(location: 0, length: 0))
        workspace.claimKeysAfterClick(in: "message", window: window)
        check(workspace.keyFocusSerial == serial && window.firstResponder === text,
              "starting a message selection requested composer focus")
        text.setSelectedRange(NSRange(location: 0, length: 8))
        workspace.claimKeysAfterClick(in: "message", window: window)
        check(workspace.keyFocusSerial == serial && window.firstResponder === text,
              "long clipped message selection requested composer focus")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        let copied = text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes)
        check(copied && pasteboard.string(forType: .string) == "Selected",
              "native selection did not copy exactly the selected range")
        window.makeFirstResponder(nil)
        workspace.claimKeysAfterClick(in: "message", window: window)
        check(workspace.keyFocusSerial == serial + 1,
              "non-text pane click stopped requesting composer focus")
        print("PASS selection: drag start, long clipped text, native range copy, blank-pane focus")
    }

    @MainActor static func splitProjectRegressions() async {
        _ = NSApplication.shared
        let model = AppModel(), client = RemoteClient(), feed = HostSessionFeed(), workspace = MacWorkspace()
        model.client = client
        workspace.attach(appModel: model)
        workspace.selectHost("host")
        workspace.feed = feed
        let a = SessionSummary(key: "a", cwd: "/tmp/project-a/")
        let a2 = SessionSummary(key: "a2", cwd: "/tmp/project-a")
        let b = SessionSummary(key: "b", cwd: "/tmp/project-b")
        for session in [a, a2, b] { feed.listStore.patchSession(session) }
        workspace.restorePanes([a.key])
        check(!workspace.canAddSessionToSplit(b), "another project's session was offered for this split")
        workspace.addPane(b.key, project: a.cwd)
        check(workspace.paneKeys == [a.key], "a mismatched session entered a split")
        workspace.addPane(a2.key, project: a2.cwd)
        check(workspace.paneKeys == [a.key, a2.key], "matching project path with trailing slash was rejected")
        workspace.addPane("shell:12345678", project: b.cwd)
        check(workspace.splitAgentProject == a.cwd, "focused terminal changed the split's agent project")
        client.handler = { method, _ in
            if method == WireProtocol.mSessionNew {
                return ["session": ["key": "new", "cwd": "/tmp/project-a", "hosted": true]]
            }
            return [:]
        }
        await workspace.newSessionPane(runtimeID: "claude")
        let creation = client.calls.first { $0.0 == WireProtocol.mSessionNew }
        check(creation?.1["cwd"] as? String == a.cwd, "quick Add Pane ignored the existing agent project")
        check(workspace.paneKeys.contains("new"), "same-project quick session did not join the split")
        workspace.openCreated(b, asPane: true)
        check(workspace.paneKeys == [b.key], "cross-project creation mixed agents in one split")
        let legacy = DesktopGroup(id: "legacy", name: "", project: a.cwd,
                                  members: [a.key, b.key, a2.key], focus: a.key)
        workspace.openGroup(legacy, sessions: [a, b, a2])
        check(workspace.paneKeys == [a.key, a2.key], "legacy mixed group opened cross-project panes")
        var otherFocused = legacy
        otherFocused.focus = b.key
        workspace.openGroup(otherFocused, sessions: [a, b, a2])
        check(workspace.paneKeys == [b.key], "legacy group ignored its focused agent project")
        workspace.restorePanes([a.key, b.key, a2.key])
        check(workspace.paneKeys == [a.key, a2.key], "restoration reopened cross-project panes")
        print("PASS split project: membership, terminal focus, quick creation, cross-project result, legacy group")
    }

    @MainActor static func sidebarSplitRestorationRegressions() async {
        let model = AppModel(), client = RemoteClient(), workspace = MacWorkspace()
        let a = SessionSummary(key: "flat-a", cwd: "/tmp/flat-project")
        let b = SessionSummary(key: "flat-b", cwd: "/tmp/flat-project")
        let c = SessionSummary(key: "flat-c", cwd: "/tmp/other-project")
        let split = DesktopGroup(id: "flat-split", name: "", project: a.cwd,
                                 members: [a.key, b.key], focus: a.key, collapsed: true)
        client.handler = { method, _ in
            if method == WireProtocol.mLayoutWatch {
                return DesktopLayout(revision: 1, groups: [split], pinnedSessions: [:])
            }
            return [:]
        }
        model.client = client
        workspace.attach(appModel: model)
        workspace.selectHost("flat-sidebar-fixture")
        workspace.startLayoutWatch()
        await settle()
        workspace.open(a.key, sessions: [a, b, c], takeKeys: false)
        check(workspace.paneKeys == [a.key, b.key] && workspace.focusedKey == a.key,
              "flat member did not restore its collapsed host split")
        workspace.open(b.key, sessions: [a, b, c], takeKeys: false)
        check(workspace.paneKeys == [a.key, b.key] && workspace.focusedKey == b.key,
              "selecting another flat member replaced the existing split")
        workspace.open(c.key, sessions: [a, b, c], takeKeys: false)
        check(workspace.paneKeys == [c.key], "standalone session did not open alone")
        workspace.open(b.key, sessions: [a, b, c], takeKeys: false)
        check(workspace.paneKeys == [a.key, b.key] && workspace.focusedKey == b.key,
              "returning to a flat member did not restore its saved split")
        workspace.stopLayoutWatch()
        print("PASS flat sidebar: collapsed split restoration, member focus, standalone, saved split return")
    }

    @MainActor static func modeObservationRegressions() {
        let suiteKey = "corral.mac.paneModes"
        let saved = UserDefaults.standard.object(forKey: suiteKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: suiteKey) }
            else { UserDefaults.standard.removeObject(forKey: suiteKey) }
        }
        for initial in [MacWorkspace.PaneMode.chat, .terminal] {
            let host = "mode-observation-fixture"
            UserDefaults.standard.set(["\(host):subject": initial.rawValue], forKey: suiteKey)
            let workspace = MacWorkspace()
            workspace.selectHost(host)
            let changes = ModeChangeCounter()
            withObservationTracking {
                check(workspace.mode(for: "subject") == initial, "initial persisted mode was lost")
            } onChange: { changes.increment() }
            workspace.setMode(initial == .chat ? .terminal : .chat, for: "subject")
            check(changes.value == 1, "first persisted-mode toggle did not notify its observer")
            let peer = ModeChangeCounter()
            withObservationTracking { _ = workspace.mode(for: "peer") }
                onChange: { peer.increment() }
            workspace.setMode(initial, for: "subject")
            check(peer.value == 0, "one pane's mode toggle invalidated its peer")
        }
        print("PASS first mode toggle: persisted Chat/Terminal observation and pane isolation")
    }

    @MainActor static func paneActivationRegressions() {
        let workspace = MacWorkspace()
        workspace.restorePanes(["first", "second"])
        let initial = workspace.paneFocusSerial
        let same = ModeChangeCounter()
        withObservationTracking { _ = workspace.paneFocusSerial }
            onChange: { same.increment() }
        workspace.focus("first")
        check(same.value == 1 && workspace.paneFocusSerial == initial + 1,
              "reactivating the focused pane did not notify sidebar selection")
        check(workspace.focusedKey == "first", "reactivation changed the focused identity")
        workspace.focusPane(at: 1)
        check(workspace.focusedKey == "second" && workspace.paneFocusSerial == initial + 2,
              "pane shortcut did not reconcile sidebar selection")
        workspace.composerDidGainFocus("second")
        check(workspace.paneFocusSerial == initial + 3,
              "returning to the focused composer did not reconcile sidebar selection")
        workspace.restorePanes(["first", "second"])
        check(workspace.paneFocusSerial == initial + 3,
              "passive pane restoration synthesized explicit activation")
        print("PASS pane activation: repeated focus, pane shortcut, composer and passive restoration")
    }

    @MainActor static func main() async throws {
        paneActivationRegressions()
        await sessionBatchRegressions()
        modeObservationRegressions()
        await sidebarSplitRestorationRegressions()
        await splitProjectRegressions()
        selectionCopyRegressions()
        try await searchRegressions()
        try await searchOpeningRegressions()
        try await resumeRegressions()
        try await workspaceRegressions()
        try await terminalRegressions()
        await promptNavigationRegressions()
    }
}

@MainActor enum SessionCreationCoordinator {
    static func create(hostID: String, runtimeID: String, cwd: String, supportsReceipts: Bool,
                       call: (String, [String: Any]) async throws -> Any) async throws -> SessionSummary {
        let payload = try await call(WireProtocol.mSessionNew, ["runtime": runtimeID, "cwd": cwd])
        return try SessionActionsMenu.decodeNewSession(from: payload)
    }
}


/// Observation callbacks are Sendable; count synchronously under a lock.
private final class ModeChangeCounter: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    nonisolated func increment() { lock.withLock { $0 += 1 } }
    nonisolated var value: Int { lock.withLock { $0 } }
}
