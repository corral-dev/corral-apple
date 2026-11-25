import Foundation

/// Where app-owned files live. iOS keeps its sandboxed Application Support;
/// the Mac app keeps every app-owned file under `~/.config/corral-mac/`
/// (or `$XDG_CONFIG_HOME/corral-mac/`) per the desktop config location rule.
nonisolated enum AppStorageLocation {
    #if os(macOS)
    private final class DirectoryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedEnv: String?
        private var cachedDir: URL?

        func directory() -> URL {
            let env = getenv("XDG_CONFIG_HOME").map { String(cString: $0) } ?? ""
            lock.lock()
            defer { lock.unlock() }
            if let cachedDir, cachedEnv == env {
                return cachedDir
            }
            let root = env.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
                : URL(fileURLWithPath: env, isDirectory: true)
            let dir = root.appendingPathComponent("corral-mac", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            cachedEnv = env
            cachedDir = dir
            return dir
        }
    }
    private static let cache = DirectoryCache()
    #endif

    static var baseDirectory: URL {
        #if os(macOS)
        cache.directory()
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// Root of Corral's own files: `Application Support/Corral` on iOS (unchanged
    /// since the first release), `~/.config/corral-mac` on macOS.
    static var appDirectory: URL {
        #if os(macOS)
        baseDirectory
        #else
        baseDirectory.appendingPathComponent("Corral", isDirectory: true)
        #endif
    }

    /// Optional form for call sites that chain from an optional test override.
    static var appDirectoryIfAvailable: URL? { appDirectory }

    static var cachesDirectory: URL {
        #if os(macOS)
        baseDirectory.appendingPathComponent("cache", isDirectory: true)
        #else
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #endif
    }
}
