#if DEBUG
import Foundation

/// Real-host acceptance through the pane's own stream and app connection.
/// Restricted to the disposable acceptance project; never submitted to an agent.
@MainActor
enum MacLifecycleInspection {
    private static var claimed = false

    static func run(appModel: AppModel, workspace: MacWorkspace, feed: HostSessionFeed) async {
        guard !claimed,
              let key = ProcessInfo.processInfo.environment["CORRAL_INSPECTION_SESSION_KEY"],
              let session = feed.listStore.session(for: key),
              session.cwd.contains("corral-phone-acceptance"), let client = appModel.client else { return }
        claimed = true
        var outcomes: [String: Bool] = [:]
        outcomes["initial_live"] = await wait { RemoteTerminalStream.inspectionStream?.phase == .live }
        guard let stream = RemoteTerminalStream.inspectionStream else { save(outcomes); return }
        let before = stream.inspectionEpoch
        client.reconnectNow(force: true)
        outcomes["reconnect_started"] = client.state != .ready
        outcomes["reconnect_live"] = await wait {
            appModel.connectionState == .connected && stream.phase == .live && stream.inspectionEpoch != before
        }
        if let grid = stream.inspectionAcknowledgedGrid {
            let fit = TerminalGrid(cols: max(20, grid.cols - 5), rows: grid.rows)
            stream.updateFit(fit)
            outcomes["resize_acknowledged"] = await wait { stream.inspectionAcknowledgedGrid == fit }
            stream.updateFit(grid)
            outcomes["resize_restored"] = await wait { stream.inspectionAcknowledgedGrid == grid }
        }
        let text = "MAC_LIFECYCLE_测试"
        outcomes["typing_sink_bound"] = stream.sink != nil
        outcomes["typing_same_client"] = appModel.client === client
        stream.input.send(ArraySlice(Array(text.utf8)))
        save(outcomes)
        outcomes["typing_visible"] = await wait {
            (stream.sink as? TerminalHostView)?.inspectionContains(text) == true
        }
        stream.input.send(ArraySlice(Array(repeating: UInt8(0x7f), count: text.count)))
        outcomes["typing_erased"] = await wait {
            (stream.sink as? TerminalHostView)?.inspectionContains(text) == false
        }
        let search = FulltextSearchStore()
        await search.search("PHONE", client: appModel.client) { appModel.client === $0 }
        outcomes["real_search"] = search.result != nil && search.errorMessage == nil
        let host = feed.host
        workspace.closePane(key)
        try? await Task.sleep(for: .seconds(1))
        workspace.open(key, sessions: feed.listStore.windowSessions)
        workspace.setMode(.terminal, for: key)
        outcomes["close_reopen_live"] = await wait {
            guard let current = RemoteTerminalStream.inspectionStream else { return false }
            return current !== stream && current.phase == .live
        }
        appModel.disconnect(clearSelection: false)
        await appModel.connect(to: host)
        outcomes["replaced_client_live"] = await wait {
            appModel.client !== client && appModel.connectionState == .connected
                && RemoteTerminalStream.inspectionStream?.phase == .live
        }
        save(outcomes)
    }

    private static func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func save(_ outcomes: [String: Bool]) {
        if let data = try? JSONEncoder().encode(outcomes) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/corral-mac-lifecycle-acceptance.json"), options: .atomic)
        }
    }
}
#endif
