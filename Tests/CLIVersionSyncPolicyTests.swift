import Foundation
import Testing
@testable import Corral

@Suite("CLI version sync policy")
struct CLIVersionSyncPolicyTests {
    @Test("Compares padded semantic versions numerically")
    func comparesVersions() {
        #expect(CLIVersionSyncPolicy.compareVersions("v1.0.2", "1.0.10") == .orderedAscending)
        #expect(CLIVersionSyncPolicy.compareVersions("1.0", "1.0.0") == .orderedSame)
        #expect(CLIVersionSyncPolicy.compareVersions("1.1.0", "1.0.99") == .orderedDescending)
    }

    @Test("Parses corral update --status --json payload and --version fallback")
    func parsesStatusAndFallback() {
        let json = """
        {"ok":true,"cli":{"version":"1.0.0","channel":"pipx","editable_like":false}}
        """
        let snap = CLIVersionSyncPolicy.parseCLIStatusJSON(Data(json.utf8))
        #expect(snap == CLIStatusSnapshot(version: "1.0.0", channel: .pipx, editableLike: false))
        #expect(CLIVersionSyncPolicy.parsePlainVersionOutput("corral 0.24.300 (/opt/homebrew)") == "0.24.300")
    }

    @Test("Missing CLI selects brew, script, or needsHomebrew based on prerequisites")
    func missingInstallDecisions() {
        #expect(
            CLIVersionSyncPolicy.decide(
                appVersion: "1.0.1",
                snapshot: nil,
                supportsVersionUpdateFlag: false,
                hasHomebrew: true,
                hasScriptPrerequisites: true
            ) == .install(targetVersion: "1.0.1", method: .brew)
        )
        #expect(
            CLIVersionSyncPolicy.decide(
                appVersion: "1.0.1",
                snapshot: nil,
                supportsVersionUpdateFlag: false,
                hasHomebrew: false,
                hasScriptPrerequisites: true
            ) == .install(targetVersion: "1.0.1", method: .script)
        )
        #expect(
            CLIVersionSyncPolicy.decide(
                appVersion: "1.0.1",
                snapshot: nil,
                supportsVersionUpdateFlag: false,
                hasHomebrew: false,
                hasScriptPrerequisites: false
            ) == .install(targetVersion: "1.0.1", method: .needsHomebrew)
        )
    }

    @Test("Protects dev editable installs and newer CLIs from overwrite or downgrade")
    func protectsDevAndNewer() {
        let devSnap = CLIStatusSnapshot(version: "1.0.0", channel: .dev, editableLike: true)
        #expect(
            CLIVersionSyncPolicy.decide(
                appVersion: "1.0.5",
                snapshot: devSnap,
                supportsVersionUpdateFlag: true,
                hasHomebrew: true,
                hasScriptPrerequisites: true
            ) == .devCheckout(cliVersion: "1.0.0")
        )
        let newerSnap = CLIStatusSnapshot(version: "1.0.8", channel: .pipx, editableLike: false)
        #expect(
            CLIVersionSyncPolicy.decide(
                appVersion: "1.0.5",
                snapshot: newerSnap,
                supportsVersionUpdateFlag: true,
                hasHomebrew: true,
                hasScriptPrerequisites: true
            ) == .ahead(cliVersion: "1.0.8")
        )
    }

    @Test("Older managed CLI schedules upgrade matching Mac version")
    func upgradesOlderManagedCLI() {
        let olderSnap = CLIStatusSnapshot(version: "1.0.0", channel: .pipx, editableLike: false)
        #expect(
            CLIVersionSyncPolicy.decide(
                appVersion: "1.0.1",
                snapshot: olderSnap,
                supportsVersionUpdateFlag: true,
                hasHomebrew: false,
                hasScriptPrerequisites: false
            ) == .upgrade(targetVersion: "1.0.1", channel: .pipx, viaVersionFlag: true)
        )
    }

    @Test("Extracts sentinel-wrapped PATH ignoring shell startup noise")
    func extractsSentinelPath() {
        let noisy = Data(
            """
            Welcome to zsh
            __CORRAL_PATH_BEGIN__/stale/path__CORRAL_PATH_END__
            initializing nvm
            __CORRAL_PATH_BEGIN__/home/.local/share/nodejs/current-v22/bin:/opt/homebrew/bin__CORRAL_PATH_END__
            done
            """.utf8
        )
        #expect(
            HostShellPathPolicy.extractSentinelPath(from: noisy)
                == "/home/.local/share/nodejs/current-v22/bin:/opt/homebrew/bin"
        )
        #expect(HostShellPathPolicy.extractSentinelPath(from: Data("plain output".utf8)) == nil)
        #expect(HostShellPathPolicy.probeCommand(forShell: "/opt/homebrew/bin/fish").contains("string join : $PATH"))
        #expect(HostShellPathPolicy.probeCommand(forShell: "/bin/zsh").contains("\"$PATH\""))
    }

    @Test("Merges PATH lists preserving order and discovers tool-manager bins")
    func mergesAndDiscoversToolBins() throws {
        let merged = HostShellPathPolicy.mergePaths([
            ["/shell/bin", "/opt/homebrew/bin", ""],
            ["/opt/homebrew/bin", "/usr/bin"],
            ["/bin"],
        ])
        #expect(merged == "/shell/bin:/opt/homebrew/bin:/usr/bin:/bin")

        let fm = FileManager.default
        let rawRoot = fm.temporaryDirectory.appending(path: "corral-path-test-\(UUID().uuidString)")
        try fm.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        let root = rawRoot.resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let node22 = root.appending(path: ".local/share/nodejs/current-v22/bin")
        let bun = root.appending(path: ".bun/bin")
        let claude = root.appending(path: ".claude/local/bin")
        for dir in [node22, bun, claude] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let discovered = HostShellPathPolicy.commonToolBinDirectories(home: root, fileManager: fm)
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(discovered.contains(node22.resolvingSymlinksInPath().path))
        #expect(discovered.contains(bun.resolvingSymlinksInPath().path))
        #expect(discovered.contains(claude.resolvingSymlinksInPath().path))
        #expect(!discovered.contains(root.appending(path: ".volta/bin").resolvingSymlinksInPath().path))
        #expect(discovered.contains("/opt/homebrew/bin"))
    }
}
