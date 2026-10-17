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

    @ObservationIgnored let sessionKey: String
    @ObservationIgnored let input: TerminalInputSender
    @ObservationIgnored private(set) weak var client: RemoteClient?
    @ObservationIgnored weak var sink: TerminalStreamSink? {
        didSet { replayBacklog() }
    }

    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var synced = false
    @ObservationIgnored private var resyncing = false
    /// Snapshot plus later output that arrived before the view existed.
    @ObservationIgnored private var backlog: (grid: TerminalGrid, data: [Data])?
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
        events?.cancel()
        events = nil
        resizeTask?.cancel()
        resizeTask = nil
        attachGeneration = nil
        attached = false
        synced = false
        backlog = nil
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

    /// Resolve full host text by identity; card previews are never search input.
    func navigatePrompt(seq: Int, historyGeneration: Int) async -> String? {
        let request = UUID()
        promptNavigation = request
        guard let client, client.hostCapabilities.terminalPrompt else { return String(localized: "terminal.prompt.unavailable") }
        // The iPhone sheet temporarily stopped the stream. Wait for its fresh
        // attach, without reviving a process or borrowing a previous snapshot.
        for _ in 0..<30 {
            if phase == .live && synced { break }
            guard !Task.isCancelled, self.client === client, promptNavigation == request else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, self.client === client, promptNavigation == request, phase == .live, synced else {
            return String(localized: "terminal.prompt.unavailable")
        }
        let mine = generation
        let params: [String: Any] = ["key": sessionKey, "seq": seq, "generation": historyGeneration,
                                   "navigation": request.uuidString]
        do {
            let value = try await client.call("terminal.prompt", params: params)
            guard !Task.isCancelled, generation == mine, promptNavigation == request else { return nil }
            guard let payload = value as? [String: Any], let query = payload["query"] as? String else {
                return String(localized: "terminal.prompt.unavailable")
            }
            let occurrence = payload["occurrence"] as? Int ?? 0
            let total = payload["total"] as? Int ?? 1
            if sink?.terminalRevealPrompt(query, occurrence: occurrence, total: total) == true { return nil }
            var native = params
            native["native"] = true
            _ = try await client.call("terminal.prompt", params: native)
            guard !Task.isCancelled, generation == mine, promptNavigation == request else { return nil }
            return nil
        } catch {
            guard !Task.isCancelled, generation == mine, promptNavigation == request else { return nil }
            return error.localizedDescription
        }
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
        resizeTask?.cancel()
        resizeTask = nil
        attachGeneration = nil
        attached = false
        sentGrid = nil
        synced = false
        resyncing = false
        lastSeq = 0
        backlog = nil
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

    private func attach(_ grid: TerminalGrid, generation mine: UUID) async {
        defer { if attachGeneration == mine { attachGeneration = nil } }
        for attempt in 0..<4 {
            guard let client, isCurrent(mine) else { return }
            do {
                let attachTheme = theme
                _ = try await client.call(WireProtocol.mTerminalAttach, params: params(grid).merging(themeParams) { $1 })
                guard isCurrent(mine) else { return }
                attached = true
                sentGrid = grid
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
        let seq = (payload["seq"] as? Int) ?? 0
        switch payload["kind"] as? String {
        case "snapshot":
            guard let cols = payload["cols"] as? Int, let rows = payload["rows"] as? Int,
                  let data = decode(payload["data"]) else { return }
            lastSeq = seq
            synced = true
            phase = .live
            let grid = TerminalGrid(cols: cols, rows: rows)
            if let sink {
                sink.terminalReset(grid: grid, data: data)
            } else {
                backlog = (grid, [data])
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
                backlog?.data.append(data)
            }
        case "ended":
            lastSeq = seq
            phase = .ended
        default:
            break
        }
    }

    private func replayBacklog() {
        guard let sink, let pending = backlog else { return }
        backlog = nil
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
        case bytes(Data)
        case paste(String)
    }

    private static let maxBatch = 8 * 1024

    private let sessionKey: String
    private weak var client: RemoteClient?
    private var queue: [Input] = []
    private var draining = false

    init(sessionKey: String, client: RemoteClient) {
        self.sessionKey = sessionKey
        self.client = client
    }

    /// Large input (a paste typed by the emulator itself) is split so no
    /// request exceeds the host's raw-input limit.
    func send(_ bytes: ArraySlice<UInt8>) {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: Self.maxBatch, limitedBy: bytes.endIndex) ?? bytes.endIndex
            enqueue(.bytes(Data(bytes[start..<end])))
            start = end
        }
    }

    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(.paste(text))
    }

    private func enqueue(_ input: Input) {
        queue.append(input)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func takeBatch() -> Input {
        var head = queue.removeFirst()
        while case .bytes(let joined) = head, let next = queue.first, case .bytes(let more) = next,
              joined.count + more.count <= Self.maxBatch {
            head = .bytes(joined + more)
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
                case .bytes(let data):
                    _ = try await client.call(
                        WireProtocol.mTerminalInput,
                        params: ["key": sessionKey, "data": data.base64EncodedString()]
                    )
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
