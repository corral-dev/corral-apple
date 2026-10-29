import Foundation

extension LifecycleProbe {
    @MainActor private static func terminalSnapshot(_ client: RemoteClient, _ key: String, seq: Int,
                                                  cols: Int = 80, rows: Int = 24) async {
        client.emit(["kind": "snapshot", "seq": seq, "cols": cols, "rows": rows,
                     "data": Data("healthy screen".utf8).base64EncodedString()], channel: "term:" + key)
        await settle()
    }

    @MainActor private static func terminalOutput(_ client: RemoteClient, _ key: String, seq: Int) async {
        client.emit(["kind": "output", "seq": seq, "data": Data("still running".utf8).base64EncodedString()],
                    channel: "term:" + key)
        await settle()
    }

    @MainActor private static func waitForTerminal(_ condition: @MainActor () -> Bool,
                                                 seconds: Int = 8) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(condition(), "terminal recovery did not reach its expected state before the deadline")
    }

    @MainActor static func terminalRecoveryRegressions() async {
        for runtime in ["pi", "claude", "codex", "opencode", "cursor"] {
            let key = runtime + ":late-resync", client = RemoteClient(), gate = Gate(), sink = Sink()
            client.handler = { method, _ in
                if method == WireProtocol.mTerminalResync { return try await gate.wait() }
                return [:] as [String: Any]
            }
            let stream = RemoteTerminalStream(sessionKey: key, client: client)
            stream.sink = sink; stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24))
            await settle(); await terminalSnapshot(client, key, seq: 1)
            await terminalOutput(client, key, seq: 3)
            await waitForTerminal { gate.continuation != nil }
            await terminalSnapshot(client, key, seq: 4)
            check(stream.phase == .live && sink.resets == 2, "fresh snapshot did not repair the gap")
            gate.fail(); await settle()
            check(stream.phase == .live, "late same-generation resync failure hid a healthy terminal: " + runtime)
            await terminalOutput(client, key, seq: 5)
            check(sink.outputs == 1 && stream.phase == .live, "healthy output remained hidden after stale failure")
            let traces = client.terminalTraces.filter { $0.operation == .resync }
            check(traces.first?.requestID == traces.last?.requestID && traces.last?.result == .failed
                  && traces.last?.snapshotRevision == 2, "terminal diagnostics lost late-reply/snapshot correlation")
            check(client.calls.allSatisfy { [WireProtocol.mTerminalAttach, WireProtocol.mTerminalResync].contains($0.0) },
                  "terminal recovery sent input or resumed an agent")
            stream.stop(); await settle()
        }
        await supersededTerminalRecovery()
        await terminalRecoveryWithoutFrames()
        await terminalResizeRecovery()
        await terminalAttachEvidence()
        print("PASS established terminal: five runtimes, stale RPCs, coalesced gaps, retry, missing frames, resize convergence, attach evidence, ended/stop safety")
    }

    @MainActor private static func supersededTerminalRecovery() async {
        let client = RemoteClient(), first = Gate(), second = Gate(), key = "pi:new-gap"
        var requests = 0
        client.handler = { method, _ in
            if method == WireProtocol.mTerminalResync {
                requests += 1
                return try await (requests == 1 ? first : second).wait()
            }
            return [:] as [String: Any]
        }
        let stream = RemoteTerminalStream(sessionKey: key, client: client)
        stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        await terminalSnapshot(client, key, seq: 1)
        await terminalOutput(client, key, seq: 3)
        await waitForTerminal { first.continuation != nil }
        for _ in 0..<20 { client.emit(["resync": true], channel: "term:" + key) }
        await settle()
        check(requests == 1, "duplicate gap markers started concurrent recovery RPCs")
        await terminalSnapshot(client, key, seq: 4)
        await terminalOutput(client, key, seq: 6)
        await waitForTerminal { second.continuation != nil }
        first.fail(); await settle()
        check(stream.phase == .connecting && requests == 2, "old cancelled recovery changed or cleared a newer gap")
        client.emit(["kind": "ended", "seq": 7], channel: "term:" + key); await settle()
        second.fail(); await settle()
        check(stream.phase == .ended, "late resync failure replaced the ended state")
        stream.stop(); await settle()
    }

    @MainActor private static func terminalRecoveryWithoutFrames() async {
        let client = RemoteClient(), key = "pi:transient-resync", sink = Sink()
        var requests = 0
        client.handler = { method, _ in
            if method == WireProtocol.mTerminalResync {
                requests += 1
                if requests == 1 { throw ProbeError.failed }
                client.emit(["kind": "snapshot", "seq": 4, "cols": 80, "rows": 24,
                             "data": Data("recovered".utf8).base64EncodedString()], channel: "term:" + key)
            }
            return [:] as [String: Any]
        }
        let stream = RemoteTerminalStream(sessionKey: key, client: client)
        stream.sink = sink; stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        await terminalSnapshot(client, key, seq: 1)
        await terminalOutput(client, key, seq: 3)
        await waitForTerminal { requests == 2 && stream.phase == .live }
        check(sink.resets == 2, "transient resync failure did not recover automatically")
        stream.stop(); await settle()

        let silent = RemoteClient(), missingKey = "shell:silent-established"
        let missing = RemoteTerminalStream(sessionKey: missingKey, client: silent)
        missing.start(); missing.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        await terminalSnapshot(silent, missingKey, seq: 1)
        await terminalOutput(silent, missingKey, seq: 3)
        await waitForTerminal {
            if case .failed = missing.phase { return true }
            return false
        }
        check(silent.calls.filter { $0.0 == WireProtocol.mTerminalResync }.count == 2,
              "successful resync replies without frames were not bounded")
        missing.retry(); await settle()
        await terminalSnapshot(silent, missingKey, seq: 5)
        check(missing.phase == .live, "Retry did not repair the genuinely missing screen")
        missing.stop(); await settle()
    }

    @MainActor private static func terminalResizeRecovery() async {
        let client = RemoteClient(), fourth = Gate(), key = "pi:resize", sink = Sink()
        var attempts = 0
        client.handler = { method, _ in
            if method == WireProtocol.mTerminalResize {
                attempts += 1
                if attempts < 4 { throw ProbeError.failed }
                if attempts == 4 { return try await fourth.wait() }
                client.emit(["kind": "snapshot", "seq": 3, "cols": 100, "rows": 30,
                             "data": Data("fitted".utf8).base64EncodedString()], channel: "term:" + key)
            }
            return [:] as [String: Any]
        }
        let stream = RemoteTerminalStream(sessionKey: key, client: client)
        stream.sink = sink; stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        await terminalSnapshot(client, key, seq: 1)
        stream.updateFit(TerminalGrid(cols: 100, rows: 30))
        await waitForTerminal { fourth.continuation != nil }
        fourth.fail(); await settle()
        await terminalOutput(client, key, seq: 2)
        check(stream.phase == .live && sink.outputs == 1, "resize RPC failure hid a healthy output stream")
        await waitForTerminal { attempts == 5 && sink.resets == 2 }
        check(stream.phase == .live, "deferred desired-size retry broke the stream")
        stream.stop(); await settle()
        let calls = client.calls.count
        try? await Task.sleep(for: .milliseconds(200))
        check(client.calls.count == calls, "stopped terminal retained deferred resize work")

        let racing = RemoteClient(), gate = Gate(), raceKey = "pi:resize-snapshot"
        racing.handler = { method, _ in
            if method == WireProtocol.mTerminalResize { return try await gate.wait() }
            return [:] as [String: Any]
        }
        let fitted = RemoteTerminalStream(sessionKey: raceKey, client: racing)
        fitted.start(); fitted.updateFit(TerminalGrid(cols: 80, rows: 24)); await settle()
        await terminalSnapshot(racing, raceKey, seq: 1)
        fitted.updateFit(TerminalGrid(cols: 100, rows: 30))
        await waitForTerminal { gate.continuation != nil }
        await terminalSnapshot(racing, raceKey, seq: 2, cols: 100, rows: 30)
        gate.fail(); await settle()
        check(fitted.phase == .live, "late resize failure overrode a matching snapshot")
        fitted.updateFit(TerminalGrid(cols: 100, rows: 30))
        try? await Task.sleep(for: .milliseconds(200))
        check(racing.calls.filter { $0.0 == WireProtocol.mTerminalResize }.count == 1,
              "matching snapshot failed to settle desired size")
        fitted.stop(); await settle()
    }

    @MainActor private static func terminalAttachEvidence() async {
        let client = RemoteClient(), gate = Gate(), key = "pi:attach-snapshot"
        client.handler = { method, _ in
            if method == WireProtocol.mTerminalAttach { return try await gate.wait() }
            return [:] as [String: Any]
        }
        let stream = RemoteTerminalStream(sessionKey: key, client: client)
        stream.start(); stream.updateFit(TerminalGrid(cols: 80, rows: 24))
        await waitForTerminal { gate.continuation != nil }
        await terminalSnapshot(client, key, seq: 1)
        gate.fail(); await settle()
        stream.updateFit(TerminalGrid(cols: 100, rows: 30))
        await waitForTerminal { client.calls.contains { $0.0 == WireProtocol.mTerminalResize } }
        check(stream.phase == .live && client.calls.filter { $0.0 == WireProtocol.mTerminalAttach }.count == 1,
              "a valid attach snapshot was discarded because its reply failed")
        stream.stop(); await settle()
    }
}
