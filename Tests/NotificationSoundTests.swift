import AVFoundation
import Foundation
import XCTest
@testable import Corral

final class NotificationSoundTests: XCTestCase {
    func testUnknownOrMissingChoiceFallsBackToElectronicChime() {
        XCTAssertEqual(NotificationSound.resolve(stored: nil), .electronicChime)
        XCTAssertEqual(NotificationSound.resolve(stored: "default"), .electronicChime)
        XCTAssertEqual(NotificationSound.resolve(stored: ""), .electronicChime)
    }

    func testLegacyChoicesResolveWithoutOpeningTheAppFirst() {
        XCTAssertEqual(NotificationSound.resolve(stored: "chime"), .electronicChime)
        XCTAssertEqual(NotificationSound.resolve(stored: "marimba"), .woodenDuet)
        XCTAssertEqual(NotificationSound.resolve(stored: "tap"), .waterDrop)
    }

    func testExactlyThreeApprovedChoicesRoundTrip() {
        XCTAssertEqual(NotificationSound.allCases, [.woodenDuet, .waterDrop, .electronicChime])
        for sound in NotificationSound.allCases {
            XCTAssertEqual(NotificationSound.resolve(stored: sound.rawValue), sound)
            XCTAssertEqual(sound.id, sound.rawValue)
            XCTAssertEqual(sound.fileName, "corral-\(sound.rawValue).caf")
        }
    }

    /// Decode each shipped asset, rather than using file size as a duration proxy.
    func testEveryPresetHasAShortDecodableSoundAndRetainedMaster() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Shared/Resources/Sounds")
        let bundled = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".caf") }
        XCTAssertEqual(Set(bundled), Set(NotificationSound.allCases.map(\.fileName)))

        for sound in NotificationSound.allCases {
            let url = directory.appendingPathComponent(sound.fileName)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.prefix(4), Data("caff".utf8), sound.fileName)
            let audio = try AVAudioFile(forReading: url)
            XCTAssertEqual(audio.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatAppleIMA4)
            XCTAssertEqual(audio.processingFormat.sampleRate, 44_100)
            XCTAssertEqual(audio.processingFormat.channelCount, 2)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            XCTAssertGreaterThan(duration, 0)
            XCTAssertLessThan(duration, 2, sound.fileName)

            let master = root.appendingPathComponent(
                "scripts/notification-sounds/sources/corral-\(sound.rawValue).mp3")
            XCTAssertGreaterThan(try Data(contentsOf: master).count, 0, master.lastPathComponent)
        }
    }
}
