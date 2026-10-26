import Dispatch
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Releases rebuildable caches when the system reports memory pressure.
///
/// Native clients keep image, markdown, preview and dormant-pane data warm for
/// instant switching. Under pressure those resources can be rebuilt from the
/// host, while conversation history, drafts, reading position, native selection
/// and terminal state must survive untouched.
@MainActor
enum ClientMemoryPressure {
    private static var installed = false
    /// Extra per-owner cleanup (the Mac workspace evicts dormant panes here).
    private static var handlers: [UUID: @MainActor () -> Void] = [:]
    #if canImport(UIKit)
    private static var token: NSObjectProtocol?
    #elseif os(macOS)
    private static var source: DispatchSourceMemoryPressure?
    #endif

    static func install() {
        guard !installed else { return }
        installed = true
        #if canImport(UIKit)
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { purge() }
        }
        #elseif os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { purge() }
        }
        source.resume()
        self.source = source
        #endif
    }

    @discardableResult
    static func addHandler(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    static func removeHandler(_ id: UUID) {
        handlers[id] = nil
    }

    /// Drop only rebuildable caches; never user-visible history or state.
    static func purge() {
        ChatImageLoader.purgeMemory()
        ChatMarkdown.purgeCache()
        ChatImageReferenceCache.purge()
        SessionPresentation.purgePreviewCache()
        for handler in handlers.values { handler() }
    }
}
