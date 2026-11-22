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
}
