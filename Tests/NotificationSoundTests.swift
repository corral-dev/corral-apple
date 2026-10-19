import Foundation
import XCTest
@testable import Corral

final class NotificationSoundTests: XCTestCase {
    func testUnknownOrMissingChoiceFallsBackToChime() {
        XCTAssertEqual(NotificationSound.resolve(stored: nil), .chime)
        XCTAssertEqual(NotificationSound.resolve(stored: "default"), .chime)
        XCTAssertEqual(NotificationSound.resolve(stored: "marimba"), .marimba)
    }

    /// Every preset must ship a bundled CAF under 30 s, or the system plays its default sound.
    func testEveryPresetHasBundledShortSound() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/Resources/Sounds")
        for sound in NotificationSound.allCases {
            XCTAssertFalse(sound.fileName.contains("default"))
            let data = try Data(contentsOf: directory.appendingPathComponent(sound.fileName))
            XCTAssertEqual(data.prefix(4), Data("caff".utf8), sound.fileName)
            XCTAssertLessThan(data.count, 200_000, sound.fileName)
        }
    }
}
