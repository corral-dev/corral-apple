import Foundation

extension LifecycleProbe {
    @MainActor static func sessionBatchRegressions() async {
        let runner = MacSessionBatch(), gate = Gate()
        var visited: [String] = []
        let first = Task {
            await runner.run(keys: ["a", "b", "a", "c"], isCurrent: { true }) { key in
                visited.append(key)
                if key == "a" { _ = try await gate.wait() }
                if key == "b" { throw MacSessionBatch.Failure(message: "denied") }
            }
        }
        await settle()
        check(runner.isRunning && runner.total == 3 && visited == ["a"], "batch was not serialized")
        let duplicate = await runner.run(keys: ["unexpected"], isCurrent: { true }) { _ in
            preconditionFailure("a second batch executed while busy")
        }
        check(duplicate.succeeded.isEmpty, "busy runner reported unexecuted success")
        gate.succeed([:])
        let result = await first.value
        check(visited == ["a", "b", "c"] && result.succeeded == ["a", "c"], "partial failure replayed/skipped targets")
        check(result.failures.count == 1 && result.failures.first?.key == "b"
              && runner.completed == 3 && !runner.isRunning, "partial result/progress was lost")

        var current = true
        let retired = await runner.run(keys: ["a", "b", "c"], isCurrent: { current }) { _ in current = false }
        check(retired.succeeded == ["a"] && retired.failures.map(\.key) == ["b", "c"], "host switch sent remaining writes")

        let model = AppModel(), client = RemoteClient(), workspace = MacWorkspace(), feed = HostSessionFeed()
        model.client = client
        workspace.attach(appModel: model); workspace.selectHost("batch"); workspace.feed = feed
        var pins: [String: Double] = [:]
        var groupPinned = false
        var revision = 0
        func layoutPayload() -> [String: Any] {
            [
                "revision": revision,
                "groups": [[
                    "id": "g", "name": "", "project": "/p",
                    "members": ["g1", "g2"], "focus": "g1", "collapsed": false,
                    "pinned": groupPinned, "pinned_at": groupPinned ? 1.0 : 0, "updated_at": 0,
                ]],
                "pinned_sessions": pins,
            ]
        }
        client.handler = { method, params in
            if method == WireProtocol.mLayoutPin, let key = params["key"] as? String {
                pins[key] = pins[key] == nil ? 1 : nil
                revision += 1
                return layoutPayload()
            }
            if method == WireProtocol.mLayoutPinGroup, params["group_id"] as? String == "g" {
                groupPinned.toggle()
                revision += 1
                return layoutPayload()
            }
            if method == WireProtocol.mSessionDelete, params["key"] as? String == "keep" {
                throw MacSessionBatch.Failure(message: "host refused deletion")
            }
            return [:] as [String: Any]
        }
        do {
            workspace.startLayoutWatch()
            client.emit(layoutPayload(), channel: WireProtocol.chLayout)
            await settle()
            check(workspace.layout.groups.count == 1, "layout watch did not deliver the split")
            // TUI semantics: a member pins its whole split, and a repeated
            // member in one batch must not toggle the split back off.
            try await workspace.applySessionAction(.pin, key: "g1")
            check(workspace.layout.isPinned("g1") && workspace.layout.isPinned("g2") && groupPinned,
                  "split member pin did not include the whole split")
            try await workspace.applySessionAction(.pin, key: "g2")
            check(groupPinned && client.calls.filter { $0.0 == WireProtocol.mLayoutPinGroup }.count == 1,
                  "repeated split member inverted the split pin")
            try await workspace.applySessionAction(.unpin, key: "g2")
            check(!workspace.layout.isPinned("g1") && !groupPinned,
                  "split member unpin did not clear the whole split")
            try await workspace.applySessionAction(.pin, key: "a")
            try await workspace.applySessionAction(.pin, key: "a")
            try await workspace.applySessionAction(.unpin, key: "a")
            check(client.calls.filter { $0.0 == WireProtocol.mLayoutPin }.count == 2 && pins.isEmpty,
                  "desired-state pin inverted an already pinned item")
            feed.listStore.patchSession(SessionSummary(key: "delete"))
            feed.listStore.patchSession(SessionSummary(key: "keep"))
            workspace.restorePanes(["delete", "keep"])
            let deleted = await runner.run(keys: ["delete", "keep"], isCurrent: { true }) { key in
                try await workspace.applySessionAction(.delete, key: key)
            }
            check(deleted.succeeded == ["delete"] && deleted.failures.map(\.key) == ["keep"], "delete result lost partial failure")
            check(feed.listStore.session(for: "delete") == nil && feed.listStore.session(for: "keep") != nil,
                  "failed deletion removed history from the list")
            check(!workspace.paneKeys.contains("delete") && workspace.paneKeys.contains("keep"),
                  "deletion closed an unconfirmed pane")
            check(workspace.actionError == nil, "batch emitted a second per-item alert")
        } catch { preconditionFailure("batch fixture failed: \(error)") }
        print("PASS session batches: serialized snapshots, duplicate exclusion, partial failure, host retirement, split/session desired pins, confirmed deletion")
    }
}
