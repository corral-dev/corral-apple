import Foundation
import Observation

/// One host's live session list: cache-first bootstrap, `sessions.watch`
/// subscription, reconnect rewatch, periodic reconciliation, host search and the
/// row actions (pin / stop / delete). Shared by the iPhone session list page and
/// the Mac sidebar so both platforms keep the same ordering, ownership and
/// stale-response rules.
///
/// Ownership rules (unchanged from the original iOS page):
/// - never install another host's snapshot or subscribe on another host's client;
/// - a newer refresh revision invalidates stale responses and failures;
/// - the local multicast subscription is installed before `sessions.watch`;
/// - leaving finishes the previous unwatch before a new watch is registered.
@MainActor
@Observable
final class HostSessionFeed {
    static let listRecheckInterval: Duration = .seconds(20)

    let host: HostInfo
    let listStore = SessionListStore()
    private(set) var isLoading = true
    var loadError: String?
    /// True while the owning surface is visible; work is consumed only then.
    private(set) var isActive = false

    /// Called after every applied snapshot, migration or patch (the iOS page
    /// resolves pending notification taps here).
    @ObservationIgnored var onNotification: ((SessionSummary, String) async -> Void)?

    @ObservationIgnored var onListChanged: (() async -> Void)?
    /// A provisional key was promoted to its canonical key (old, new).
    @ObservationIgnored var onSessionMigrated: ((String, String) -> Void)?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var didWatch = false
    @ObservationIgnored private var refreshRevision = 0
    @ObservationIgnored private var watchClient: RemoteClient?
    @ObservationIgnored private var readyHandlerID: UUID?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var unwatchTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(host: HostInfo) {
        self.host = host
    }

    // MARK: - Lifecycle

    /// Cache first, then connect, watch and refresh. Call from the surface's task;
    /// `beforeConnect` runs after the cached snapshot loads (iOS opens cached taps).
    func activate(appModel: AppModel, beforeConnect: (() async -> Void)? = nil) async {
        self.appModel = appModel
        isActive = true
        listStore.loadPersisted(hostID: host.hostID)
        if !listStore.sections.isEmpty {
            isLoading = false
        }
        await beforeConnect?()
        if appModel.isConnected(to: host) {
            appModel.selectHost(host)
        } else {
            await appModel.connect(to: host)
        }
        // The surface may have disappeared while connect awaited.
        guard !Task.isCancelled, isActive else { return }
        await unwatchTask?.value
        unwatchTask = nil
        guard !Task.isCancelled, isActive else { return }
        startWatching()
        await refresh(showLoading: listStore.sections.isEmpty)
        await onListChanged?()
    }

    /// Reconcile missed events while the surface remains visible.
    func runRecheckLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.listRecheckInterval)
            guard !Task.isCancelled, isActive,
                  let appModel, appModel.isConnected(to: host) else { continue }
            await refresh(showLoading: false)
        }
    }

    /// Re-establish this host's connection and resubscribe (retry actions).
    func reconnect() async {
        guard isActive, let appModel else { return }
        if !appModel.isConnected(to: host) {
            await appModel.connect(to: host)
        }
        guard !Task.isCancelled, isActive else { return }
        startWatching()
        await refresh(showLoading: listStore.sections.isEmpty)
    }

    func deactivate() {
        isActive = false
        watchTask?.cancel()
        watchTask = nil
        searchTask?.cancel()
        searchTask = nil
        // Invalidate outstanding unstructured refreshes.
        refreshRevision &+= 1
        // Unregister and un-watch on the exact client this feed attached to, even
        // after an async host switch moved appModel.client elsewhere.
        let client = watchClient
        watchClient = nil
        if let readyHandlerID, let client {
            client.removeReadyHandler(readyHandlerID)
        }
        readyHandlerID = nil
        let shouldUnwatch = didWatch
        didWatch = false
        if shouldUnwatch {
            unwatchTask = Task { @MainActor [client] in
                _ = try? await client?.call(WireProtocol.mSessionsUnwatch)
            }
        }
    }

    /// App-owned Mac feeds await the old subscription teardown before replacing it.
    func waitUntilUnwatched() async {
        await unwatchTask?.value
    }

    // MARK: - Refresh and watch

    func refresh(showLoading: Bool) async {
        guard let appModel, let client = appModel.client else {
            loadError = String(localized: String.LocalizationValue("error.not_connected"))
            isLoading = false
            return
        }
        // Same-root ownership: never install another host's snapshot.
        guard appModel.connectedHostID == host.hostID else {
            loadError = String(localized: String.LocalizationValue("error.not_connected"))
            isLoading = false
            return
        }
        refreshRevision &+= 1
        let revision = refreshRevision
        if showLoading { isLoading = true }
        do {
            var params: [String: Any] = [:]
            if !listStore.version.isEmpty {
                params["since_version"] = listStore.version
            }
            // watch 兼具首包列表；若已 watch 则改走 list，避免二次 watch 空包覆盖。
            let method = didWatch ? WireProtocol.mSessionsList : WireProtocol.mSessionsWatch
            let response = try await client.call(method, params: params, as: SessionsListResponse.self)
            guard !Task.isCancelled, revision == refreshRevision,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID else { return }
            didWatch = true
            listStore.applyListResponse(response)
            loadError = nil
        } catch {
            // A stale failure must not clear a newer loading state or assign errors.
            guard !Task.isCancelled, revision == refreshRevision,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID else { return }
            if listStore.sections.isEmpty {
                loadError = error.localizedDescription
            }
        }
        guard revision == refreshRevision, appModel.client === client,
              appModel.connectedHostID == host.hostID else { return }
        isLoading = false
        await onListChanged?()
    }

    private func startWatching() {
        watchTask?.cancel()
        // Same-root ownership: never subscribe or register callbacks on another host's client.
        guard isActive, !Task.isCancelled, let appModel,
              let client = appModel.client,
              client.reconnectHost?.hostID == host.hostID else { return }
        watchClient = client
        listStore.beginConnectionEpoch()
        let events = client.subscribe(channel: WireProtocol.chSessions)
        let hostID = host.hostID

        // 先挂本地多播订阅，再（在 refresh 里）向服务端登记 watch。
        watchTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.appModel?.client === client,
                      self.appModel?.connectedHostID == hostID else { break }
                if event.data["kind"] as? String == "notification" {
                    if let payload = event.data["notification"] as? [String: Any],
                       let kind = event.data["notification_kind"] as? String,
                       let summary = try? RemoteJSONDecoder.decode(SessionSummary.self, from: payload) {
                        await self.onNotification?(summary, kind)
                    }
                } else if event.data["unchanged"] as? Bool == true || event.data["sessions"] != nil {
                    // A full list costs milliseconds to decode; do it off the main actor,
                    // then re-check ownership because the host or client may change meanwhile.
                    if let response = try? await RemoteJSONDecoder.decodeOffMain(
                        SessionsListResponse.self,
                        from: JSONValueBox(value: event.data)
                    ), !Task.isCancelled, self.appModel?.client === client,
                       self.appModel?.connectedHostID == hostID {
                        self.listStore.applyListResponse(response)
                        self.loadError = nil
                        await self.onListChanged?()
                    }
                } else if let oldKey = event.data["old_key"] as? String,
                          let newKey = event.data["new_key"] as? String {
                    self.listStore.migrateSession(from: oldKey, to: newKey)
                    self.onSessionMigrated?(oldKey, newKey)
                    await self.onListChanged?()
                } else if let patch = SessionListStore.sessionPatch(from: event.data) {
                    self.listStore.applySessionEvent(patch.0, revision: patch.1)
                    await self.onListChanged?()
                }
            }
        }

        if let readyHandlerID {
            client.removeReadyHandler(readyHandlerID)
        }
        let handlerClient = client
        readyHandlerID = client.addReadyHandler { [weak self] in
            // A callback queued before removal must not rewatch offscreen.
            guard let self, self.isActive, self.watchClient === handlerClient else { return }
            Task { [weak self] in
                // 重连后服务端订阅丢失，需要重新 watch。
                guard let self, !Task.isCancelled, self.isActive,
                      self.watchClient === handlerClient,
                      self.appModel?.client === handlerClient,
                      self.appModel?.connectedHostID == hostID else { return }
                self.listStore.beginConnectionEpoch()
                self.didWatch = false
                await self.refresh(showLoading: false)
            }
        }
    }

    // MARK: - Search

    func scheduleRemoteSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await self?.searchOnHost(trimmed)
        }
    }

    private func searchOnHost(_ query: String) async {
        guard let client = appModel?.client else { return }
        let current = listStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == query else { return }
        do {
            let response = try await client.call(
                WireProtocol.mSessionsList,
                params: ["q": query, "limit": 100],
                as: SessionsListResponse.self
            )
            guard listStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                return
            }
            listStore.applySearchHits(response.sessions, query: query)
        } catch {
            // 本地窗口过滤已经在画，开发机搜索失败时保留它。
        }
    }

    // MARK: - Row actions

    /// Returns whether the pinned state actually changed on the host.
    @discardableResult
    func togglePin(_ session: SessionSummary) async throws -> Bool {
        let client = try requireClient()
        do {
            _ = try await client.call(WireProtocol.mSessionPin, params: ["key": session.key])
            loadError = nil
            await refresh(showLoading: false)
            guard let updated = listStore.session(for: session.key) else { return false }
            return (updated.pinned ?? false) != (session.pinned ?? false)
        } catch {
            loadError = Self.remoteErrorMessage(error)
            throw error
        }
    }

    /// Returns whether the host reports the session stopped.
    @discardableResult
    func stop(_ session: SessionSummary) async throws -> Bool {
        let client = try requireClient()
        do {
            // confirm=true：开发机侧要求破坏性操作必须带确认，与系统确认框对应
            _ = try await client.call(
                WireProtocol.mSessionStop,
                params: ["key": session.key, "confirm": true]
            )
            loadError = nil
            await refresh(showLoading: false)
            return listStore.session(for: session.key)?.live == false
        } catch {
            loadError = Self.remoteErrorMessage(error)
            throw error
        }
    }

    func delete(_ session: SessionSummary) async throws {
        let client = try requireClient()
        do {
            _ = try await client.call(
                WireProtocol.mSessionDelete,
                params: ["key": session.key, "confirm": true]
            )
            listStore.removeSession(key: session.key)
            loadError = nil
        } catch {
            // Fail closed: keep the row until the host confirms deletion.
            loadError = Self.remoteErrorMessage(error)
            throw error
        }
    }

    private func requireClient() throws -> RemoteClient {
        guard let client = appModel?.client else {
            let message = String(localized: String.LocalizationValue("error.not_connected"))
            loadError = message
            throw RemoteCallError(code: WireProtocol.eInternal, message: message, hint: "")
        }
        return client
    }

    static func remoteErrorMessage(_ error: Error) -> String {
        if let remote = error as? RemoteCallError {
            return remote.message
        }
        return error.localizedDescription
    }
}
