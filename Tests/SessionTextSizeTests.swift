#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

@MainActor
final class SessionTextSizeTests: XCTestCase {
    func testDefaultIsMediumAndScaleIsIdentity() {
        let defaultSize = SessionTextSize.default
        let medium = SessionTextSize.medium
        let mediumScale = medium.scale
        XCTAssertEqual(defaultSize, medium)
        XCTAssertEqual(mediumScale, 1.0, accuracy: 0.0001)
    }

    func testResolveFallsBackToDefault() {
        let fromNil = SessionTextSize.resolve(stored: nil)
        let fromEmpty = SessionTextSize.resolve(stored: "")
        let fromUnknown = SessionTextSize.resolve(stored: "huge")
        let fromLarge = SessionTextSize.resolve(stored: "large")
        let medium = SessionTextSize.medium
        let large = SessionTextSize.large
        XCTAssertEqual(fromNil, medium)
        XCTAssertEqual(fromEmpty, medium)
        XCTAssertEqual(fromUnknown, medium)
        XCTAssertEqual(fromLarge, large)
    }

    func testScalesIncreaseAcrossSliderSteps() {
        let sizes = SessionTextSize.allCases
        let scales = sizes.map(\.scale)
        for index in 1 ..< scales.count {
            XCTAssertGreaterThan(scales[index], scales[index - 1])
        }
        let extraSmall = SessionTextSize.extraSmall
        let medium = SessionTextSize.medium
        let extraLarge = SessionTextSize.extraLarge
        XCTAssertEqual(SessionTextSize.from(sliderIndex: 0), extraSmall)
        XCTAssertEqual(SessionTextSize.from(sliderIndex: 2), medium)
        XCTAssertEqual(SessionTextSize.from(sliderIndex: 4), extraLarge)
        XCTAssertEqual(SessionTextSize.from(sliderIndex: -3), extraSmall)
        XCTAssertEqual(SessionTextSize.from(sliderIndex: 99), extraLarge)
    }

    func testSliderIndexRoundTrips() {
        for size in SessionTextSize.allCases {
            let index = size.sliderIndex
            XCTAssertEqual(SessionTextSize.from(sliderIndex: index), size)
        }
    }
}
#endif

