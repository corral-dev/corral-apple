import AppKit
import Observation
import UserNotifications

/// App-owned feed survives closing the main window. Local notifications never register APNs.
@MainActor @Observable
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotifications()
    private(set) var enabled = false
    var waiting = true { didSet { savePreferences() } }
    var completed = true { didSet { savePreferences() } }
    var aborted = true { didSet { savePreferences() } }
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    var failure: String?
    private(set) var pendingOpen = PendingNotificationOpen()
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var feed: HostSessionFeed?
    @ObservationIgnored private var feedClientIdentity: ObjectIdentifier?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var ledger = NotificationLedger()
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var ledgerURL: URL { AppStorageLocation.appDirectory.appendingPathComponent("notification-ledger.json") }
    @ObservationIgnored private var preferencesURL: URL { AppStorageLocation.appDirectory.appendingPathComponent("notifications.json") }

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: preferencesURL),
           let values = try? JSONDecoder().decode([String: Bool].self, from: data) {
            enabled = values["enabled"] ?? false
            waiting = values["waiting"] ?? true
            completed = values["completed"] ?? true
            aborted = values["aborted"] ?? true
        }
        if let data = try? Data(contentsOf: ledgerURL),
           let saved = try? JSONDecoder().decode(NotificationLedger.self, from: data) { ledger = saved }
    }

    func configure(model: AppModel) {
        self.model = model
        center.delegate = self
        Task.detached(priority: .utility) { Self.installSounds() }
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY", title: String(localized: "composer.send"), options: [.foreground],
            textInputButtonTitle: String(localized: "composer.send"),
            textInputPlaceholder: String(localized: "composer.placeholder")
        )
        center.setNotificationCategories([UNNotificationCategory(
            identifier: "CORRAL_WAITING", actions: [reply], intentIdentifiers: [], options: []
        )])
        Task {
            await refreshAuthorization()
            if let request = pendingOpen.request {
                await open(hostID: request.hostID, key: request.sessionKey)
            }
        }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        savePreferences()
        guard value else { return }
        await refreshAuthorization()
        if authorization == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            catch { failure = String(localized: "settings.notifications.registration_failed") }
            await refreshAuthorization()
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// One owner for watch/unwatch: SwiftUI tasks can cancel without tearing down the app's feed.
    func sessionFeed(host: HostInfo, model: AppModel) async -> HostSessionFeed {
        if let feed, feed.host.hostID == host.hostID, feed.isActive,
           model.client?.reconnectHost?.hostID == host.hostID,
           feedClientIdentity == model.clientIdentity {
            await startTask?.value
            return feed
        }
        let previous = feed
        stopFeed()
        // Never block a machine switch on the old feed's unwatch RPC: bound
        // the wait and let the new feed activate immediately. Different hosts
        // subscribe on independent channels, so teardown and activation may overlap.
        if let previous {
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await previous.waitUntilUnwatched() }
                    group.addTask { try? await Task.sleep(for: .seconds(1.5)) }
                    await group.next()
                    group.cancelAll()
                }
            }
        }
        let current = HostSessionFeed(host: host)
        feed = current
        current.onNotification = { [weak self, weak current] session, kind in
            guard let self, let current, self.feed === current else { return }
            await self.deliver(session, kind: kind, hostID: host.hostID)
        }
        let task = Task { await current.activate(appModel: model) }
        startTask = task
        await task.value
        if feed === current {
            feedClientIdentity = model.clientIdentity
            feedTask = Task { await current.runRecheckLoop() }
        }
        return current
    }

    func stopFeed() {
        startTask?.cancel()
        feedTask?.cancel()
        feed?.deactivate()
        feed = nil
        feedClientIdentity = nil
        startTask = nil
        feedTask = nil
    }

    func deliver(_ session: SessionSummary, kind rawKind: String, hostID: String) async {
        guard enabled, let kind = SessionNotificationKind(rawValue: rawKind),
              (kind != .waiting || waiting), (kind != .completed || completed),
              (kind != .aborted || aborted), model?.hosts.contains(where: { $0.hostID == hostID }) == true,
              let id = kind.identity(hostID: hostID, session: session),
              !ledger.contains(id), inFlight.insert(id).inserted else { return }
        defer { inFlight.remove(id) }
        await refreshAuthorization()
        guard enabled, authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        guard let title = SessionNotificationText.title(forKind: kind.rawValue) else { return }
        content.title = title
        content.subtitle = session.title.isEmpty ? "Corral" : session.title
        content.body = NotificationPreview.body(session.lastAgent, fallback: content.title)
        var soundName = NotificationSound.selected.fileName
        #if DEBUG
        // Acceptance probes a throwaway name: Notification Center caches a missed name's fallback.
        soundName = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_NOTIFICATION_SOUND"] ?? soundName
        #endif
        content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        content.categoryIdentifier = kind == .waiting ? "CORRAL_WAITING" : "CORRAL_COMPLETION"
        content.userInfo = ["host_id": hostID, "session_key": session.key]
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            ledger.record(id)
            // Tiny payload; encode inline, write off the main thread.
            if let data = try? JSONEncoder().encode(ledger) {
                let url = ledgerURL
                Task.detached(priority: .utility) {
                    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }
        } catch {
            failure = String(localized: "settings.notifications.registration_failed")
        }
    }

    /// Notification Center does not resolve sounds that exist only inside a
    /// non-sandboxed app bundle; the app container's Library/Sounds (the user's
    /// ~/Library/Sounds here) is the documented lookup location.
    private nonisolated static func installSounds() {
        let manager = FileManager.default
        guard let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for sound in NotificationSound.allCases {
            guard let source = Bundle.main.url(forResource: sound.fileName, withExtension: nil),
                  let data = try? Data(contentsOf: source) else { continue }
            let target = directory.appendingPathComponent(sound.fileName)
            if (try? Data(contentsOf: target)) != data { try? data.write(to: target, options: .atomic) }
        }
    }

    private func savePreferences() {
        do {
            let values = ["enabled": enabled, "waiting": waiting, "completed": completed, "aborted": aborted]
            let data = try JSONEncoder().encode(values)
            let url = preferencesURL
            Task.detached(priority: .utility) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } catch { failure = String(localized: "settings.notifications.registration_failed") }
    }

    func open(hostID: String, key: String) async {
        pendingOpen.store(hostID: hostID, sessionKey: key)
        guard let model else { return }
        guard let host = model.hosts.first(where: { $0.hostID == hostID }) else {
            failure = String(localized: "notification.unavailable")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain && $0.title == "Corral" })?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .corralPendingNotificationOpen, object: nil)
        if !model.isConnected(to: host) { await model.connect(to: host) }
        else { model.selectHost(host) }
    }

    func resolvePending(feed: HostSessionFeed, workspace: MacWorkspace) async {
        guard let request = pendingOpen.request, request.hostID == feed.host.hostID,
              let model, model.isConnected(to: feed.host), let client = model.client else { return }
        let ticket = pendingOpen.ticket
        do {
            let session: SessionSummary
            if let cached = feed.listStore.session(for: request.sessionKey) { session = cached }
            else {
                session = try await client.call(WireProtocol.mSessionGet,
                    params: ["key": request.sessionKey], as: SessionSummary.self)
            }
            guard ticket == pendingOpen.ticket, model.client === client,
                  model.isConnected(to: feed.host), workspace.hostID == request.hostID else { return }
            guard ActiveRuntimeVisibility.isListVisible(session) else {
                pendingOpen.consume(hostID: request.hostID, sessionKey: request.sessionKey)
                failure = String(localized: "notification.unavailable")
                return
            }
            feed.listStore.patchSession(session)
            feed.listStore.rememberOpened(session)
            workspace.open(session.key, sessions: feed.listStore.windowSessions, takeKeys: true)
            pendingOpen.consume(hostID: request.hostID, sessionKey: request.sessionKey)
        } catch {
            guard ticket == pendingOpen.ticket, model.client === client else { return }
            pendingOpen.consume(hostID: request.hostID, sessionKey: request.sessionKey)
            failure = String(localized: "notification.unavailable")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let host = info["host_id"] as? String
        let key = info["session_key"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let completion = MacNotificationCompletion(completionHandler)
        Task { @MainActor in
            defer { completion.call() }
            switch NotificationReply.route(actionIdentifier: action, hostID: host, sessionKey: key, text: text) {
            case let .open(hostID, key): await self.open(hostID: hostID, key: key)
            case let .reply(hostID, key, text):
                await self.open(hostID: hostID, key: key)
                guard let model = self.model, let host = model.hosts.first(where: { $0.hostID == hostID }),
                      model.isConnected(to: host), let client = model.client else {
                    self.failure = String(localized: "notification.reply_failed")
                    return
                }
                do {
                    var params: [String: Any] = ["key": key, "text": text, "submit": true]
                    if client.supportsCommandReceipts { params["command_id"] = UUID().uuidString }
                    _ = try await client.call(WireProtocol.mInputText, params: params)
                } catch { self.failure = String(localized: "notification.reply_failed") }
            case .ignore: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let hostID = notification.request.content.userInfo["host_id"] as? String
        let sessionKey = notification.request.content.userInfo["session_key"] as? String
        Task { @MainActor [weak self] in
            self?.model?.client?.refreshAfterNotification(hostID: hostID, sessionKey: sessionKey)
        }
        completionHandler([.banner, .sound, .list])
    }
}

private nonisolated struct MacNotificationCompletion: @unchecked Sendable {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}
