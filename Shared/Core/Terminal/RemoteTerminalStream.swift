import Foundation

/// Receiver of a pane's terminal stream: the emulator view.
@MainActor
protocol TerminalStreamSink: AnyObject {
    /// Reset the emulator to `grid` and draw the host snapshot.
    func terminalReset(grid: TerminalGrid, data: Data)
    /// Append live output in host order.
    func terminalFeed(_ data: Data)
    func terminalRevealPrompt(_ query: String) -> Bool
    func terminalRevealPrompt(_ query: String, occurrence: Int, total: Int) -> Bool
}

extension TerminalStreamSink {
    func terminalRevealPrompt(_ query: String) -> Bool { false }
    func terminalRevealPrompt(_ query: String, occurrence: Int, total: Int) -> Bool {
        occurrence == 0 && total == 1 && terminalRevealPrompt(query)
    }
}

struct TerminalGrid: Equatable, Sendable {
    let cols: Int
    let rows: Int
}

/// The emulator's background and foreground as `#rrggbb`.
struct TerminalTheme: Equatable, Sendable {
    let background: String
    let foreground: String
}

/// One raw terminal stream from the host (`terminal.*`, channel `term:<key>`):
/// an agent pane (Mac terminal view) or a project shell (`shell:<id>`, Mac
/// panel and iPhone). A snapshot comes first, then output in sequence. A
/// sequence gap asks the host for a fresh snapshot; the emulator never guesses.
///
/// The view reports the grid it fits; the host sizes the tmux pane to the
/// viewer the user used most recently (TUI windows included for agent panes)
/// and every resize arrives here as a new snapshot. Attach and resize say
/// whether this view's window is in front; a background window only renews
/// its size, and `claimSize()` takes the pane back when the window returns.
@MainActor
@Observable
final class RemoteTerminalStream {
    enum Phase: Equatable {
        case connecting
        case live
        case ended
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    /// A snapshot arrived on this stream at least once.
    private(set) var hasBeenLive = false

    @ObservationIgnored let sessionKey: String
    @ObservationIgnored let input: TerminalInputSender
    @ObservationIgnored private(set) weak var client: RemoteClient?
    @ObservationIgnored weak var sink: TerminalStreamSink? {
        didSet { replayBacklog() }
    }

    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var synced = false
    @ObservationIgnored private var resyncing = false
    /// Snapshot plus later output that arrived before the view existed.
    @ObservationIgnored private var backlog: (grid: TerminalGrid, data: [Data])?
    @ObservationIgnored private var backlogBytes = 0
    /// The retained backlog was dropped at its byte ceiling; the next attached
    /// view must start from a fresh snapshot rather than a truncated stream.
    @ObservationIgnored private var backlogNeedsResync = false
    /// Raw output retained while no view is attached. A snapshot plus a burst
    /// fits; beyond that the screen is rebuilt from a fresh snapshot instead of
    /// retaining every byte produced while the pane was hidden.
    static let backlogByteLimit = 4 * 1024 * 1024
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var attachGeneration: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var promptNavigation = UUID()
    @ObservationIgnored private var readyHandlerID: UUID?
    @ObservationIgnored private var wanted: TerminalGrid?
    @ObservationIgnored private var theme: TerminalTheme?
    @ObservationIgnored private var sentGrid: TerminalGrid?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeGeneration = UUID()
    @ObservationIgnored private var snapshotRecovery: Task<Void, Never>?
    /// Whether the hosting window is in front (Mac: key window of the active
    /// app). Platforms without background windows keep the default.
    @ObservationIgnored var isInFront: @MainActor () -> Bool = { true }

    init(sessionKey: String, client: RemoteClient) {
        self.sessionKey = sessionKey
        self.client = client
        input = TerminalInputSender(sessionKey: sessionKey, client: client)
    }

    var clientIdentity: ObjectIdentifier? { client.map(ObjectIdentifier.init) }

    #if DEBUG
    static weak var inspectionStream: RemoteTerminalStream?
    var inspectionAcknowledgedGrid: TerminalGrid? { sentGrid }
    var inspectionEpoch: UUID { generation }
    /// Retained raw output while no view is attached, and whether the ceiling
    /// already discarded it in favour of a fresh snapshot.
    var inspectionBacklogBytes: Int { backlogBytes }
    var inspectionNeedsResync: Bool { backlogNeedsResync }
    func inspectionHandle(_ payload: [String: Any]) { handle(payload) }
    #endif

    /// Local subscriptions survive reconnect; the host subscription does not.
    func start() {
        guard events == nil, let client else { return }
        let stream = client.subscribe(channel: WireProtocol.terminalChannel(sessionKey: sessionKey))
        events = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.handle(event.data)
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"] == sessionKey {
            Self.inspectionStream = self
        }
        #endif
        readyHandlerID = client.addReadyHandler { [weak self] in self?.recover() }
        recover()
    }

    func stop() {
        let wasRunning = events != nil
        generation = UUID()
        cancelSnapshotRecovery()
        events?.cancel()
        events = nil
        resizeTask?.cancel()
        resizeTask = nil
        attachGeneration = nil
        attached = false
        synced = false
        backlog = nil
        backlogBytes = 0
        backlogNeedsResync = false
        if let readyHandlerID, let client { client.removeReadyHandler(readyHandlerID) }
        readyHandlerID = nil
        guard wasRunning, let client else { return }
        let key = sessionKey
        // Detach jumps the queue (see TerminalLifecycleQueue.detach): a failing
        // attach must not hold the host channel for tens of seconds.
        TerminalLifecycleQueue.detach(client: client, key: key) {
            _ = try? await client.call(WireProtocol.mTerminalDetach, params: ["key": key])
        }
    }

    func updateFit(_ grid: TerminalGrid) {
        guard wanted != grid else {
            if attached, grid != sentGrid, resizeTask == nil { scheduleResize() }
            return
        }
        wanted = grid
        if attached {
            if grid != sentGrid { scheduleResize() }
        } else {
            attachIfReady()
        }
    }

    /// Retire a pending prompt reveal synchronously when the person chooses latest.
    func cancelPromptNavigation() { promptNavigation = UUID() }

    /// The host owns fullscreen history. A local emulator scroll alone cannot
    /// return it to live output. Late replies never take over after newer input.
    func returnToLatest() async -> Bool {
        let request = UUID()
        promptNavigation = request
        let mine = generation
        let inputRevision = input.revision
        guard phase == .live, let client, client.hostCapabilities.terminalLatest else { return false }
        do {
            _ = try await client.call(WireProtocol.mTerminalLatest,
                                      params: ["key": sessionKey, "navigation": request.uuidString])
            return !Task.isCancelled && generation == mine && promptNavigation == request
                && input.revision == inputRevision && phase == .live
        } catch {
            debugTrace("terminal latest: \(error)")
            return false
        }
    }

    /// Resolve full host text by identity; card previews are never search input.
    /// The outcome feeds only the clicked row's status (owner decision 2026-10-19).
    /// `text` enables one retry when the host rebuilt the history after the
    /// prompt list was fetched: the same seq must still carry the same prompt.
    func navigatePrompt(seq: Int, historyGeneration: Int, text: String? = nil) async -> TerminalPromptOutcome {
        let request = UUID()
        let inputRevision = input.revision
        promptNavigation = request
        // Owner requirement (2026-10-17): a prompt jump stays in the live
        // terminal — never switch to the chat renderer, never show a History
        // preview or Return to live terminal control. Guarded native location
        // is host-owned and never submits.
        guard let client, client.hostCapabilities.terminalPrompt else {
            debugTrace("terminal prompt: host lacks terminal_prompt")
            return .failed
        }
        func superseded() -> Bool {
            let replaced = Task.isCancelled || promptNavigation != request || input.revision != inputRevision
            if replaced { debugTrace("terminal prompt: superseded (input \(input.revision != inputRevision))") }
            return replaced
        }
        // The sheet can close before the pane has its live snapshot. Wait
        // briefly for it instead of dropping the selection on the floor.
        var waited = 0
        while !(phase == .live && synced), waited < 40 {
            if superseded() { return .superseded }
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        if superseded() { return .superseded }
        guard phase == .live, synced else {
            debugTrace("terminal prompt: stream not live (\(phase), synced \(synced))")
            return .failed
        }
        let mine = generation
        let params: [String: Any] = ["key": sessionKey, "seq": seq, "generation": historyGeneration,
                                   "navigation": request.uuidString]
        do {
            let value = try await client.call("terminal.prompt", params: params)
            if superseded() || generation != mine { return .superseded }
            guard let payload = value as? [String: Any], let query = payload["query"] as? String else {
                return .failed
            }
            let occurrence = payload["occurrence"] as? Int ?? 0
            let total = payload["total"] as? Int ?? 1
            if payload["offset"] as? Int == nil, client.hostCapabilities.terminalPromptDirect {
                var native = params
                native["native"] = true
                _ = try await client.call("terminal.prompt", params: native)
                if superseded() || generation != mine { return .superseded }
                // The host suppresses intermediate editor frames and emits
                // the verified native viewport through its ordered snapshot.
                return .landed
            }
            if sink?.terminalRevealPrompt(query, occurrence: occurrence, total: total) == true { return .landed }
            // A resolve never moves the host. Fetch its retained terminal text
            // through the existing ordered snapshot barrier, without agent keys.
            guard payload["offset"] as? Int != nil else {
                debugTrace("terminal prompt: no offset and no direct capability")
                return .failed
            }
            var seen = snapshotRevision
            _ = try await client.call(WireProtocol.mTerminalResync, params: ["key": sessionKey, "history": 10_000])
            for _ in 0..<60 {
                if superseded() || generation != mine { return .superseded }
                if snapshotRevision != seen {
                    seen = snapshotRevision
                    if sink?.terminalRevealPrompt(query, occurrence: occurrence, total: total) == true { return .landed }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .failed
        } catch let error as RemoteCallError {
            // This auxiliary action never changes stream/input error state.
            debugTrace("terminal prompt: host error \(error.code): \(error.message)")
            if superseded() { return .superseded }
            // A host "stale" is not this client's newer selection or typing:
            // retry once on the current history, otherwise report it.
            if error.code == "stale", let text,
               let current = await currentGeneration(seq: seq, text: text), current != historyGeneration {
                return await navigatePrompt(seq: seq, historyGeneration: current)
            }
            return error.code == "absent" ? .absent : .failed
        } catch {
            debugTrace("terminal prompt: call failed \(error)")
            return superseded() ? .superseded : .failed
        }
    }

    /// The host's current history generation when `seq` is still the same prompt.
    private func currentGeneration(seq: Int, text: String) async -> Int? {
        guard let client,
              let response = try? await client.call(WireProtocol.mSessionUserPrompts, params: ["key": sessionKey],
                                                    as: SessionUserPromptsResponse.self),
              let listed = response.prompts.first(where: { $0.seq == seq }) else { return nil }
        // The host list may shorten long texts; compare a whitespace-free opening.
        func opening(_ value: String?) -> String { String((value ?? "").filter { !$0.isWhitespace }.prefix(32)) }
        let mine = opening(text), theirs = opening(listed.text)
        guard !mine.isEmpty, mine.hasPrefix(theirs.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
                || theirs.hasPrefix(mine) else { return nil }
        return response.generation
    }

    func retry() { recover() }

    /// The user came back to this view (its window became key): the host pane
    /// takes this view's grid again. Typing claims it on the host by itself.
    func claimSize() {
        guard attached, let grid = wanted ?? sentGrid, let client else { return }
        let mine = generation
        var request = params(grid)
        request["active"] = true
        TerminalLifecycleQueue.enqueue(client: client, key: sessionKey) { [weak self] in
            guard self?.isCurrent(mine) == true else { return }
            do {
                _ = try await client.call(WireProtocol.mTerminalResize, params: request)
            } catch {
                debugTrace("terminal size claim failed: \(error)")
            }
        }
    }

    /// Every attach carries the colours; a change while attached is sent on its
    /// own, ordered with attach and resize. Hosts without `terminal.theme` ignore it.
    func updateTheme(_ next: TerminalTheme) {
        guard theme != next else { return }
        theme = next
        if attached { sendTheme() }
    }

    private func sendTheme() {
        guard let client, theme != nil else { return }
        let mine = generation
        var params = themeParams
        params["key"] = sessionKey
        TerminalLifecycleQueue.enqueue(client: client, key: sessionKey) { [weak self] in
            guard self?.isCurrent(mine) == true else { return }
            do {
                _ = try await client.call(WireProtocol.mTerminalTheme, params: params)
                debugTrace("terminal theme acknowledged \(params["background"] ?? "")")
            } catch {
                debugTrace("terminal theme not applied: \(error)")
            }
        }
    }

    private var themeParams: [String: Any] {
        guard let theme else { return [:] }
        return ["background": theme.background, "foreground": theme.foreground]
    }

    /// Asks for a fresh snapshot (the view changed its font, which resets
    /// SwiftTerm's terminal modes); output waits for it like after a gap.
    /// The attach snapshot can arrive before the attach call returns, so this
    /// must not wait for `attached`; an unsynced stream already has one coming.
    func refreshSnapshot() {
        guard events != nil, synced else { return }
        synced = false
        requestResync()
    }

    private func recover() {
        guard events != nil else { return }
        generation = UUID()
        cancelSnapshotRecovery()
        resizeTask?.cancel()
        resizeTask = nil
        attachGeneration = nil
        attached = false
        sentGrid = nil
        synced = false
        resyncing = false
        lastSeq = 0
        backlog = nil
        backlogBytes = 0
        backlogNeedsResync = false
        phase = .connecting
        attachIfReady()
    }

    private func isCurrent(_ mine: UUID) -> Bool { events != nil && generation == mine }

    // MARK: - Host calls

    private func attachIfReady() {
        guard events != nil, !attached, attachGeneration != generation,
              let grid = wanted, let client else { return }
        let mine = generation
        attachGeneration = mine
        TerminalLifecycleQueue.enqueue(client: client, key: sessionKey) { [weak self] in
            await self?.attach(grid, generation: mine)
        }
    }

    #if DEBUG
    /// Host attach requests made by every stream (switch acceptance counts them).
    static var inspectionAttachCalls = 0
    #endif

    private func attach(_ grid: TerminalGrid, generation mine: UUID) async {
        defer { if attachGeneration == mine { attachGeneration = nil } }
        #if DEBUG
        Self.inspectionAttachCalls += 1
        #endif
        for attempt in 0..<4 {
            guard let client, isCurrent(mine) else { return }
            do {
                let attachTheme = theme
                _ = try await client.call(WireProtocol.mTerminalAttach, params: params(grid).merging(themeParams) { $1 })
                guard isCurrent(mine) else { return }
                attached = true
                sentGrid = grid
                recoverMissingSnapshot()
                debugTrace("terminal attached with theme \(attachTheme?.background ?? "none")")
                if theme != attachTheme { sendTheme() }
                if let latest = wanted, latest != grid { scheduleResize() }
                return
            } catch {
                guard isCurrent(mine) else { return }
                if attempt == 3 {
                    phase = .failed(error.localizedDescription)
                    return
                }
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
    }

    private func scheduleResize() {
        resizeTask?.cancel()
        resizeGeneration = UUID()
        let mine = generation, resize = resizeGeneration
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.isCurrent(mine), self.attached,
                  let grid = self.wanted, grid != self.sentGrid, let client = self.client else { return }
            let operation = TerminalLifecycleQueue.enqueue(client: client, key: self.sessionKey) { [weak self] in
                await self?.resize(grid, generation: mine, request: resize)
            }
            await operation.value
            if self.resizeGeneration == resize { self.resizeTask = nil }
        }
    }

    /// Attach acknowledges the subscription, not the first screen. A lost
    /// snapshot must not leave an otherwise connected terminal spinning forever.
    private func recoverMissingSnapshot() {
        guard !synced, phase == .connecting, snapshotRecovery == nil, let client else { return }
        let mine = generation, key = sessionKey
        snapshotRecovery = Task { [weak self] in
            for attempt in 0...2 {
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                guard let self, !Task.isCancelled, self.isCurrent(mine),
                      !self.synced, self.phase == .connecting else { return }
                if attempt == 2 {
                    self.snapshotRecovery = nil
                    self.phase = .failed(String(localized: String.LocalizationValue("error.host_timeout")))
                    return
                }
                do {
                    _ = try await client.call(WireProtocol.mTerminalResync, params: ["key": key])
                } catch {
                    // A snapshot/reconnect/stop can win while this RPC is in
                    // flight, including transports that ignore cancellation.
                    guard !Task.isCancelled, self.isCurrent(mine),
                          !self.synced, self.phase == .connecting else { return }
                    self.snapshotRecovery = nil
                    self.phase = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func cancelSnapshotRecovery() {
        snapshotRecovery?.cancel()
        snapshotRecovery = nil
    }

    private func resize(_ grid: TerminalGrid, generation mine: UUID, request resize: UUID) async {
        guard let client else { return }
        for attempt in 0..<4 {
            guard isCurrent(mine), wanted == grid, resizeGeneration == resize else { return }
            do {
                _ = try await client.call(WireProtocol.mTerminalResize, params: params(grid))
                guard isCurrent(mine), wanted == grid, resizeGeneration == resize else { return }
                sentGrid = grid
                return
            } catch {
                guard isCurrent(mine), wanted == grid, resizeGeneration == resize else { return }
                if attempt == 3 {
                    phase = .failed(error.localizedDescription)
                    return
                }
                try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            }
        }
    }

    private func requestResync() {
        guard !resyncing, let client else { return }
        resyncing = true
        let mine = generation, key = sessionKey
        Task { [weak self] in
            guard self?.isCurrent(mine) == true else { return }
            do {
                _ = try await client.call(WireProtocol.mTerminalResync, params: ["key": key])
            } catch {
                guard let self, self.isCurrent(mine) else { return }
                self.phase = .failed(error.localizedDescription)
            }
            guard let self, self.isCurrent(mine) else { return }
            self.resyncing = false
        }
    }

    private func params(_ grid: TerminalGrid) -> [String: Any] {
        ["key": sessionKey, "cols": grid.cols, "rows": grid.rows, "active": isInFront()]
    }

    // MARK: - Events

    private func handle(_ payload: [String: Any]) {
        // A bounded subscriber that fell behind reports one coalesced gap: raw
        // bytes are missing, so only a fresh host snapshot may restore the screen.
        if payload["resync"] as? Bool == true {
            backlog = nil
            backlogBytes = 0
            backlogNeedsResync = false
            synced = false
            requestResync()
            return
        }
        let seq = (payload["seq"] as? Int) ?? 0
        switch payload["kind"] as? String {
        case "snapshot":
            guard let cols = payload["cols"] as? Int, let rows = payload["rows"] as? Int,
                  let data = decode(payload["data"]) else { return }
            cancelSnapshotRecovery()
            lastSeq = seq
            snapshotRevision += 1
            synced = true
            phase = .live
            if !hasBeenLive { hasBeenLive = true }
            let grid = TerminalGrid(cols: cols, rows: rows)
            if let sink {
                sink.terminalReset(grid: grid, data: data)
            } else {
                backlog = (grid, [data])
                backlogBytes = data.count
                backlogNeedsResync = false
            }
        case "output":
            guard synced, let data = decode(payload["data"]) else { return }
            guard seq == lastSeq + 1 else {
                synced = false
                requestResync()
                return
            }
            lastSeq = seq
            if let sink {
                sink.terminalFeed(data)
            } else {
                appendBacklog(data)
            }
        case "ended":
            cancelSnapshotRecovery()
            lastSeq = seq
            phase = .ended
        default:
            break
        }
    }

    /// Buffer live output only up to a fixed ceiling while no view is attached.
    private func appendBacklog(_ data: Data) {
        guard backlog != nil else { return }
        backlog?.data.append(data)
        backlogBytes += data.count
        guard backlogBytes > Self.backlogByteLimit else { return }
        // Keep the last full screen for instant display; the missing tail is
        // recovered from a fresh snapshot when the view attaches.
        if let first = backlog?.data.first {
            backlog = (backlog!.grid, [first])
            backlogBytes = first.count
        } else {
            backlog = nil
            backlogBytes = 0
        }
        backlogNeedsResync = true
    }

    private func replayBacklog() {
        guard let sink else { return }
        if backlogNeedsResync {
            backlogNeedsResync = false
            // Show the last full screen immediately; the snapshot requested below
            // replaces it authoritatively instead of trusting the dropped tail.
            if let pending = backlog, let first = pending.data.first {
                sink.terminalReset(grid: pending.grid, data: first)
            }
            backlog = nil
            backlogBytes = 0
            synced = false
            requestResync()
            return
        }
        guard let pending = backlog else { return }
        backlog = nil
        backlogBytes = 0
        guard let first = pending.data.first else { return }
        sink.terminalReset(grid: pending.grid, data: first)
        for data in pending.data.dropFirst() {
            sink.terminalFeed(data)
        }
    }

    private func decode(_ value: Any?) -> Data? {
        (value as? String).flatMap { Data(base64Encoded: $0) }
    }
}

/// Lifecycle operations must remain ordered even when SwiftUI replaces a view
/// before its previous attach returns. Entries disappear when their tail finishes.
@MainActor
private enum TerminalLifecycleQueue {
    private struct Key: Hashable { let client: ObjectIdentifier; let session: String }
    private struct Pending { let id: UUID; let task: Task<Void, Never> }
    private static var pending: [Key: Pending] = [:]

    @discardableResult
    static func enqueue(client: RemoteClient, key session: String, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let key = Key(client: ObjectIdentifier(client), session: session)
        let previous = pending[key]?.task, id = UUID()
        let task = Task {
            await previous?.value
            await operation()
            if pending[key]?.id == id { pending[key] = nil }
        }
        pending[key] = Pending(id: id, task: task)
        return task
    }

    /// Detach jumps the queue: it must not wait behind a failing attach
    /// (4 retries x 20s RPC) while holding a host channel. The attach checks
    /// its generation after each attempt and aborts once `stop()` bumps it.
    static func detach(client: RemoteClient, key session: String, operation: @escaping @MainActor () async -> Void) {
        let key = Key(client: ObjectIdentifier(client), session: session)
        // Leave the previous attach running to abort on its own generation
        // check; do not block detach behind it.
        let id = UUID()
        let task = Task {
            await operation()
            if pending[key]?.id == id { pending[key] = nil }
        }
        pending[key] = Pending(id: id, task: task)
    }
}

/// Serializes terminal input so the agent receives it in typing order, each
/// request carrying whatever was typed while the previous one was in flight.
/// Keys and input-method text go as raw bytes; pastes go through the host
/// paste path so bracketed paste follows the agent's real mode.
@MainActor
final class TerminalInputSender {
    private enum Input {
        /// `passive`: the emulator answered the program by itself.
        case bytes(Data, passive: Bool)
        case paste(String)
    }

    private static let maxBatch = 8 * 1024

    private let sessionKey: String
    private weak var client: RemoteClient?
    private var queue: [Input] = []
    private var draining = false
    private(set) var revision = 0

    init(sessionKey: String, client: RemoteClient) {
        self.sessionKey = sessionKey
        self.client = client
    }

    /// Large input (a paste typed by the emulator itself) is split so no
    /// request exceeds the host's raw-input limit.
    /// `passive`: the emulator's own reply to the program (no key, click or
    /// paste). Such replies and focus reports (DECSET 1004, e.g. when a Your
    /// prompts click moves focus) are not typing: they must not retire a prompt
    /// navigation in progress, here or on the host.
    func send(_ bytes: ArraySlice<UInt8>, passive: Bool = false) {
        let passive = passive || Self.isFocusReport(bytes)
        let typed = !passive
        #if DEBUG
        if ProcessInfo.processInfo.environment["CORRAL_INSPECTION_TRACE_INPUT"] == "1" {
            debugTrace("terminal input \(bytes.count) bytes: \(String(decoding: bytes.prefix(24), as: UTF8.self).debugDescription)")
        }
        #endif
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: Self.maxBatch, limitedBy: bytes.endIndex) ?? bytes.endIndex
            enqueue(.bytes(Data(bytes[start..<end]), passive: passive), typed: typed)
            start = end
        }
    }

    /// One or more `ESC [ I` / `ESC [ O` focus reports and nothing else.
    nonisolated static func isFocusReport(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !bytes.isEmpty, bytes.count % 3 == 0 else { return false }
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let report = bytes[index..<(index + 3)]
            guard report.first == 0x1b, report.dropFirst().first == 0x5b,
                  report.last == 0x49 || report.last == 0x4f else { return false }
            index += 3
        }
        return true
    }

    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(.paste(text))
    }

    private func enqueue(_ input: Input, typed: Bool = true) {
        if typed { revision &+= 1 }
        queue.append(input)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func takeBatch() -> Input {
        var head = queue.removeFirst()
        while case .bytes(let joined, let passive) = head, let next = queue.first,
              case .bytes(let more, let morePassive) = next, passive == morePassive,
              joined.count + more.count <= Self.maxBatch {
            head = .bytes(joined + more, passive: passive)
            queue.removeFirst()
        }
        return head
    }

    private func drain() async {
        var retriedHead = false
        while !queue.isEmpty {
            let next = takeBatch()
            guard let client else {
                debugTrace("terminal input lost its client")
                // Client is gone: keep the batch for the next client instead of dropping keys.
                queue.insert(next, at: 0)
                break
            }
            do {
                switch next {
                case .bytes(let data, let passive):
                    var params: [String: Any] = ["key": sessionKey, "data": data.base64EncodedString()]
                    if passive { params["passive"] = true }
                    _ = try await client.call(WireProtocol.mTerminalInput, params: params)
                case .paste(let text):
                    _ = try await client.call(
                        WireProtocol.mInputText,
                        params: [
                            "key": sessionKey, "text": text, "submit": false,
                            // Hosts with command receipts require an id per input.
                            "command_id": UUID().uuidString.lowercased(),
                        ]
                    )
                }
                retriedHead = false
            } catch is CancellationError {
                queue.insert(next, at: 0)
                break
            } catch {
                debugTrace("terminal input failed: \(error)")
                if !retriedHead {
                    // Transport blip: one requeue, then give up to avoid a hot loop.
                    retriedHead = true
                    queue.insert(next, at: 0)
                    try? await Task.sleep(for: .milliseconds(300))
                } else {
                    // Second failure: drop this batch, allow the next one its own retry.
                    retriedHead = false
                }
            }
        }
        draining = false
    }
}

/// How one host prompt jump ended.
enum TerminalPromptOutcome: Sendable {
    case landed
    /// The prompt is no longer in the agent's terminal (for example compacted).
    case absent
    case failed
    /// A later selection or user input replaced this one; nothing to report.
    case superseded
}

/// Debug builds record failed terminal input to /tmp for acceptance runs;
/// release builds drop it (a failed keystroke has no user-visible surface yet).
func debugTrace(_ message: String) {
    #if DEBUG
    let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: "/tmp/corral-inspect.log") {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: "/tmp/corral-inspect.log", contents: Data(line.utf8))
    }
    #endif
}
