#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

nonisolated final class SessionDeletionPresentationTests: XCTestCase {
    @MainActor @Observable final class Fixture {
        var refresh = 0
        @ObservationIgnored var presentations: [Int: Binding<Bool>] = [:]
    }

    @MainActor struct FixtureList: View {
        let fixture: Fixture
        var body: some View {
            NavigationStack {
                List {
                    ForEach(0..<8) { index in
                        SessionDeletionRow(session: SessionSummary(key: "fixture:\(index)"), onDelete: { _ in }) { presentation in
                            Text("Session \(index) · \(fixture.refresh)").frame(height: 76)
                                .task { fixture.presentations[index] = presentation }
                        }
                    }
                }
            }
        }
    }

    @MainActor func testConfirmationSurvivesUnrelatedRowsAndCanReopen() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let fixture = Fixture()
        let host = UIHostingController(rootView: FixtureList(fixture: fixture))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .seconds(1))
        let first = try XCTUnwrap(fixture.presentations[3])
        first.wrappedValue = true
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(host.presentedViewController)
        for _ in 0..<8 {
            fixture.refresh += 1
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(first.wrappedValue)
        XCTAssertNotNil(host.presentedViewController)
        first.wrappedValue = false
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(host.presentedViewController)
        let second = try XCTUnwrap(fixture.presentations[5])
        second.wrappedValue = true
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(first.wrappedValue)
        XCTAssertTrue(second.wrappedValue)
        XCTAssertNotNil(host.presentedViewController)
        second.wrappedValue = false
        try await Task.sleep(for: .milliseconds(500))
    }
}
#endif
