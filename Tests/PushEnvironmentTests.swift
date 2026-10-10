import Foundation
@testable import Corral
import XCTest

/// Push environment derivation regressions: the `push.register` env must come from
/// the actual signature (`embedded.mobileprovision`), never from build configuration.
///
/// Scope: Push/PushEnvironment.swift only. Portable: this file is included in the
/// portable manifest. It must not import or drive PushRegistrar (UIKit) or NSE.
@MainActor
final class PushEnvironmentTests: XCTestCase {
    func testDevelopmentMapsToSandbox() {
        XCTAssertEqual(PushEnvironment.fromApsEnvironment("development"), .sandbox)
    }

    func testProductionMapsToProduction() {
        XCTAssertEqual(PushEnvironment.fromApsEnvironment("production"), .production)
    }

    func testMappingIgnoresCaseAndWhitespace() {
        XCTAssertEqual(PushEnvironment.fromApsEnvironment("  Development\n"), .sandbox)
        XCTAssertEqual(PushEnvironment.fromApsEnvironment("PRODUCTION"), .production)
    }

    func testAbsentOrUnknownMapsToNil() {
        XCTAssertNil(PushEnvironment.fromApsEnvironment(nil))
        XCTAssertNil(PushEnvironment.fromApsEnvironment(""))
        XCTAssertNil(PushEnvironment.fromApsEnvironment("staging"))
        XCTAssertNil(PushEnvironment.fromApsEnvironment("unknown"))
    }

    func testExtractsApsEnvironmentFromProvisioningBlob() {
        let blob = Self.mobileProvision(apsEnvironment: "development")
        XCTAssertEqual(PushEnvironment.apsEnvironmentValue(fromMobileProvision: blob), "development")
        XCTAssertEqual(
            PushEnvironment.fromApsEnvironment(PushEnvironment.apsEnvironmentValue(fromMobileProvision: blob)),
            .sandbox
        )
    }

    func testProductionProvisioningBlob() {
        let blob = Self.mobileProvision(apsEnvironment: "production")
        XCTAssertEqual(
            PushEnvironment.fromApsEnvironment(PushEnvironment.apsEnvironmentValue(fromMobileProvision: blob)),
            .production
        )
    }

    func testMissingEntitlementsFailsSafe() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Name</key><string>NoEntitlements</string></dict></plist>
            """
        let blob = Data("CMS-HEADER".utf8) + Data(plist.utf8) + Data("CMS-FOOTER".utf8)
        XCTAssertNil(PushEnvironment.apsEnvironmentValue(fromMobileProvision: blob))
    }

    func testGarbageBlobFailsSafe() {
        XCTAssertNil(PushEnvironment.apsEnvironmentValue(fromMobileProvision: Data("not-a-profile".utf8)))
        XCTAssertNil(PushEnvironment.apsEnvironmentValue(fromMobileProvision: Data()))
    }

    func testCurrentFailsSafeWithoutEmbeddedProfile() {
        // The test bundle ships no embedded.mobileprovision: unknown env must be
        // nil (skip push.register), never a guessed value.
        XCTAssertNil(PushEnvironment.current(bundle: Bundle(for: Self.self)))
    }

    // MARK: - Fixtures

    private static func mobileProvision(apsEnvironment: String) -> Data {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\
            <key>Name</key><string>Fixture</string>\
            <key>Entitlements</key><dict>\
            <key>aps-environment</key><string>\(apsEnvironment)</string>\
            </dict></dict></plist>
            """
        return Data("CMS-HEADER-BYTES".utf8) + Data(plist.utf8) + Data("CMS-FOOTER-BYTES".utf8)
    }
}
