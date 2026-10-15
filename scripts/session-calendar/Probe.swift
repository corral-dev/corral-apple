import AppKit
import Foundation

enum ChatMarkdown { static func prewarm() {} }
enum SessionTextSize: String { case standard; static let storageKey = "corral.sessionTextSize"; static func resolve(stored: String?) -> Self { .standard } }

@main @MainActor
struct CalendarProbe {
    static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-probe-" + UUID().uuidString)
        SessionListCache.directoryOverride = scratch
        defer {
            SessionListCache.flushPendingWrites()
            SessionListCache.directoryOverride = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        // Isolated clock/data: no pairing, network or user history.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 59))!
        let store = SessionListStore(now: { now }, calendar: { calendar })
        let row = SessionSummary(key: "codex:fixture", runtime: "codex", title: "Fixture", cwd: "/fixture", mtime: now.timeIntervalSince1970, live: true)
        store.loadPersisted(hostID: "calendar-fixture")
        store.updateSessions([row])
        let model = AppModel()
        let feed = HostSessionFeed(host: HostInfo(hostID: "calendar-fixture", name: "Fixture", publicKeyHex: ""), listStore: store)
        // Activate the real calendar owner without establishing a connection.
        let activation = Task { await feed.activate(appModel: model, beforeConnect: { try? await Task.sleep(for: .seconds(60)) }) }
        await Task.yield()
        activation.cancel()
        precondition(store.sections.map(\.id) == ["today"])
        now = now.addingTimeInterval(120)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        for _ in 0..<100 where store.sections.map(\.id) != ["yesterday"] { await Task.yield() }
        precondition(store.sections.map(\.id) == ["yesterday"], "offline day-change notification did not reproject")
        now = now.addingTimeInterval(86400)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<100 where store.sections.map(\.id) != ["earlier"] { await Task.yield() }
        precondition(store.sections.map(\.id) == ["earlier"], "wake did not reproject")
        feed.deactivate()
        let stoppedDate = store.presentationDate
        now = now.addingTimeInterval(86400)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        for _ in 0..<20 { await Task.yield() }
        precondition(store.presentationDate == stoppedDate, "inactive calendar owner still receives events")
        model.disconnect()
        print("PASS calendar lifecycle: offline midnight, multi-day wake, observer teardown")
    }
}
