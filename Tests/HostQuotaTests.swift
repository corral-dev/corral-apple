import Foundation
import SubswapQuotaCore
import Testing
@testable import Corral

@Suite("HostQuotaCore")
struct HostQuotaTests {
    @Test("HostCapabilities decodes quotas flag from dict or features list and defaults false")
    func hostCapabilitiesQuotasDecoding() throws {
        let legacyData = Data(#"{"command_receipts":true,"tool_detail":true}"#.utf8)
        let legacy = try JSONDecoder().decode(HostCapabilities.self, from: legacyData)
        #expect(!legacy.quotas)

        let directData = Data(#"{"command_receipts":true,"tool_detail":true,"quotas":true}"#.utf8)
        let direct = try JSONDecoder().decode(HostCapabilities.self, from: directData)
        #expect(direct.quotas)

        let featuresData = Data(#"{"command_receipts":true,"tool_detail":false,"features":["quotas"]}"#.utf8)
        let fromFeatures = try JSONDecoder().decode(HostCapabilities.self, from: featuresData)
        #expect(fromFeatures.quotas)
    }

    @Test("HostQuotaResponse decodes snapshot, pending state, subswap_not_installed, and unknown reason")
    func quotaResponseDecoding() throws {
        let readyJSON: [String: Any] = [
            "available": true,
            "fetched_at": 1_764_150_000.0,
            "snapshot": [
                "schema_version": 1,
                "generated_at": "2026-11-26T09:10:00Z",
                "daemon_running": true,
                "stale_after_ms": 300_000,
                "auto_swap": ["enabled": true, "threshold": 0.99],
                "warn_pct": 90.0,
                "exhausted_pct": 100.0,
                "provider_order": ["claude"],
                "accounts": [
                    [
                        "id": "c-1",
                        "provider": "claude",
                        "provider_display_name": "Claude",
                        "display_label": "user@example.com",
                        "active": true,
                        "billing": "subscription",
                        "manual_only": false,
                        "fetch_state": "ready",
                        "cached_at": "2026-11-26T09:09:55Z",
                        "quotas": [
                            [
                                "provider": "claude",
                                "account_id": "c-1",
                                "window": "five_hour",
                                "used": 25,
                                "limit": 100,
                                "reset_at": "2026-11-26T14:00:00Z",
                                "status": "ok",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let decoded = try HostQuotaResponse.decode(from: readyJSON)
        #expect(decoded.available)
        let snapshot = try #require(decoded.snapshot)
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.accounts[0].quotas[0].used == 25)

        let pending = try HostQuotaResponse.decode(from: ["available": true, "pending": true])
        #expect(pending.pending == true)
        #expect(pending.snapshot == nil)

        let missing = try HostQuotaResponse.decode(from: [
            "available": false,
            "reason": "subswap_not_installed",
            "error": "missing",
        ])
        #expect(!missing.available)
        #expect(missing.reason == .subswapNotInstalled)

        let unknownReason = try HostQuotaResponse.decode(from: [
            "available": false,
            "reason": "future_reason",
        ])
        #expect(unknownReason.reason == .unknown)
    }

    @MainActor
    @Test("HostQuotaCache persists per hostID and clears on HostStore.removeHost")
    func hostQuotaCacheLifecycle() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-quota-cache-\(UUID().uuidString)", isDirectory: true)
        let savedQuotaDir = HostQuotaCache.directoryOverride
        let savedHostDir = HostStore.directoryOverride
        let savedHosts = HostStore.shared.hosts
        HostQuotaCache.directoryOverride = dir
        HostStore.directoryOverride = dir
        HostStore.shared.replaceAllForTesting([])
        defer {
            HostStore.shared.replaceAllForTesting(savedHosts)
            HostQuotaCache.directoryOverride = savedQuotaDir
            HostStore.directoryOverride = savedHostDir
            try? FileManager.default.removeItem(at: dir)
        }

        let hostID = "host-quota-test-1"
        let snap = SubswapSnapshot(
            generatedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
            providerOrder: ["claude"],
            accounts: [
                AccountSnapshot(
                    id: "c-1",
                    provider: "claude",
                    providerDisplayName: "Claude",
                    displayLabel: "user@example.com",
                    active: true,
                    billing: "subscription",
                    manualOnly: false,
                    fetchState: "ready",
                    cachedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
                    quotas: []
                ),
            ]
        )

        HostQuotaCache.save(hostID: hostID, snapshot: snap)
        let loaded = HostQuotaCache.load(hostID: hostID)
        #expect(loaded?.hostID == hostID)
        #expect(loaded?.snapshot.accounts.count == 1)

        HostStore.shared.upsertHost(
            HostInfo(hostID: hostID, name: "Dev", publicKeyHex: String(repeating: "00", count: 32))
        )
        HostStore.shared.removeHost(hostID: hostID)
        #expect(HostQuotaCache.load(hostID: hostID) == nil)
    }
}
