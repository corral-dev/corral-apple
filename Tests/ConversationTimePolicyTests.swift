import Foundation
@testable import Corral
import XCTest

@MainActor
final class ConversationTimePolicyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testAdjacentGapAndMidnightStartGroups() {
        let midnight = 1_791_417_600.0
        let messages = [message(1, midnight - 60), message(2, midnight),
                        message(3, midnight + 299), message(4, midnight + 599)]
        let items = messages.map(ConversationTimelineItem.message)
        let groups = ConversationTimePolicy.separators(for: items, messages: messages, calendar: calendar)
        XCTAssertEqual(Set(groups.keys), ["message-1", "message-2", "message-4"])
    }

    func testFrequentMessagesKeepFiveMinuteTimeOrientation() {
        let messages = (0..<8).map { message($0 + 1, 1_791_417_600 + Double($0 * 120)) }
        let groups = ConversationTimePolicy.separators(
            for: messages.map(ConversationTimelineItem.message), messages: messages, calendar: calendar)
        XCTAssertEqual(Set(groups.keys), ["message-1", "message-4", "message-7"])
    }

    func testMissingAndInvalidTimesNeverInventLabels() {
        let messages = [message(1, nil), message(2, .nan), message(3, .infinity),
                        message(4, -1), message(5, 1_791_417_600), message(6, nil),
                        message(7, 1_791_417_900)]
        let groups = ConversationTimePolicy.separators(
            for: messages.map(ConversationTimelineItem.message), messages: messages, calendar: calendar)
        XCTAssertEqual(Set(groups.keys), ["message-5", "message-7"])
        XCTAssertNil(ConversationTimePolicy.date(for: 253_402_300_800))
    }

    func testActivityGroupUsesFirstSourceEvenWhenIdentityIsPreserved() {
        let messages = [message(10, 1_791_417_600), message(11, 1_791_417_660)]
        let item = ConversationTimelineItem.toolGroup(id: 11, sourceSeqs: [10, 11], tools: [])
        let groups = ConversationTimePolicy.separators(for: [item], messages: messages, calendar: calendar)
        XCTAssertEqual(groups["tools-11"], Date(timeIntervalSince1970: 1_791_417_600))
    }

    func testPrependingRecomputesBoundaryWithoutChangingRowIDs() {
        let tail = message(2, 1_791_417_660)
        let head = message(1, 1_791_417_600)
        let tailItems = [ConversationTimelineItem.message(tail)]
        XCTAssertNotNil(ConversationTimePolicy.separators(for: tailItems, messages: [tail])["message-2"])
        let items = [ConversationTimelineItem.message(head)] + tailItems
        let groups = ConversationTimePolicy.separators(for: items, messages: [head, tail], calendar: calendar)
        XCTAssertNil(groups["message-2"])
        XCTAssertEqual(items.last?.id, tailItems.last?.id)
    }

    func testViewerTimeZoneControlsDayBoundaryAndLabel() {
        let now = Date(timeIntervalSince1970: 1_791_417_600)
        let earlier = now.addingTimeInterval(-60)
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        var local = calendar
        local.timeZone = zone
        let messages = [message(1, earlier.timeIntervalSince1970), message(2, now.timeIntervalSince1970)]
        XCTAssertEqual(ConversationTimePolicy.separators(
            for: messages.map(ConversationTimelineItem.message), messages: messages, calendar: local).count, 1)
        let label = ConversationTimePolicy.label(for: now, now: now, locale: Locale(identifier: "en_GB"),
                                                calendar: local, timeZone: zone)
        XCTAssertEqual(label, "8:00")
    }

    private func message(_ seq: Int, _ timestamp: Double?) -> RichMessage {
        RichMessage(seq: seq, role: "user", text: "Message \(seq)", timestamp: timestamp)
    }
}
