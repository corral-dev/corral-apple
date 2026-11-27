import Foundation
import Observation
import SubswapQuotaCore

@MainActor
@Observable
final class HostQuotaFeed {
    let host: HostInfo
    private(set) var state: HostQuotaPresentationState = .loading
    private(set) var isRefreshing = false
    private(set) var isActive = false

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var watchClient: RemoteClient?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var unwatchTask: Task<Void, Never>?
    @ObservationIgnored private var requestRevision = 0

    init(host: HostInfo) {
        self.host = host
        loadCacheIfNeeded()
    }

    func loadCacheIfNeeded() {
        if let cached = HostQuotaCache.load(hostID: host.hostID) {
            state = cached.snapshot.accounts.isEmpty ? .empty : .ready(cached.snapshot)
        } else {
            state = .loading
        }
    }

    func activate(appModel: AppModel) async {
        self.appModel = appModel
        isActive = true
        loadCacheIfNeeded()

        if !appModel.isConnected(to: host) {
            await appModel.connect(to: host)
        }
        guard !Task.isCancelled, isActive else { return }

        await unwatchTask?.value
        unwatchTask = nil
        guard !Task.isCancelled, isActive else { return }

        guard let client = appModel.client,
              appModel.connectedHostID == host.hostID else {
            if case .loading = state {
                state = .failed(String(localized: "quotas.error.host_disconnected"))
            }
            return
        }

        guard client.hostCapabilities.quotas else {
            state = .hostUnsupported
            return
        }

        startWatching(client: client, appModel: appModel)
        await initialWatch(client: client, appModel: appModel)
    }

    func deactivate() {
        isActive = false
        requestRevision &+= 1
        watchTask?.cancel()
        watchTask = nil
        guard let client = watchClient, let appModel else {
            watchClient = nil
            return
        }
        watchClient = nil
        unwatchTask = Task { [weak client, weak appModel] in
            guard let client, let appModel, appModel.client === client else { return }
            try? await client.quotasUnwatch()
        }
    }

    func manualRefresh() async {
        guard let appModel else { return }
        if !appModel.isConnected(to: host) {
            await appModel.connect(to: host)
        }
        guard let client = appModel.client,
              appModel.connectedHostID == host.hostID else {
            if case .loading = state {
                state = .failed(String(localized: "quotas.error.host_disconnected"))
            }
            return
        }
        guard client.hostCapabilities.quotas else {
            state = .hostUnsupported
            return
        }
        if watchClient !== client {
            startWatching(client: client, appModel: appModel)
        }

        requestRevision &+= 1
        let revision = requestRevision
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let response = try await client.quotasSnapshot(refresh: true)
            guard !Task.isCancelled, revision == requestRevision,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID else { return }
            applyResponse(response)
        } catch {
            guard !Task.isCancelled, revision == requestRevision,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID else { return }
            if !hasVisibleSnapshot {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func initialWatch(client: RemoteClient, appModel: AppModel) async {
        requestRevision &+= 1
        let revision = requestRevision
        do {
            let response = try await client.quotasWatch()
            guard !Task.isCancelled, revision == requestRevision,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID else { return }
            if response.pending == true {
                return
            }
            applyResponse(response)
        } catch {
            guard !Task.isCancelled, revision == requestRevision,
                  appModel.client === client,
                  appModel.connectedHostID == host.hostID else { return }
            if !hasVisibleSnapshot {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private struct QuotaEventEnvelope: Decodable {
        let d: HostQuotaResponse
    }

    private func startWatching(client: RemoteClient, appModel: AppModel) {
        watchTask?.cancel()
        watchClient = client
        let events = client.subscribe(channel: WireProtocol.chQuotas)
        let hostID = host.hostID

        watchTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled,
                      self.appModel?.client === client,
                      self.appModel?.connectedHostID == hostID else { break }
                if let raw = event.rawEnvelopeData,
                   let envelope = try? SnapshotCodec.decode(QuotaEventEnvelope.self, from: raw) {
                    self.applyResponse(envelope.d)
                } else if let response = try? HostQuotaResponse.decode(from: event.data) {
                    self.applyResponse(response)
                }
            }
        }
    }

    private func applyResponse(_ response: HostQuotaResponse) {
        if response.pending == true {
            return
        }
        guard response.available else {
            if response.reason == .subswapNotInstalled {
                state = .subswapNotInstalled
            } else if !hasVisibleSnapshot {
                state = .failed(response.error ?? String(localized: "quotas.error.load_failed"))
            }
            return
        }
        guard let snapshot = response.snapshot else {
            if !hasVisibleSnapshot {
                state = .empty
            }
            return
        }
        HostQuotaCache.save(hostID: host.hostID, snapshot: snapshot)
        state = snapshot.accounts.isEmpty ? .empty : .ready(snapshot)
    }

    private var hasVisibleSnapshot: Bool {
        if case .ready = state { return true }
        return false
    }
}
