import Foundation
import Testing
@testable import Corral

struct MobileZoomPreferencesTests {
    @Test("default values and independence across UserDefaults")
    func defaultsAndIndependence() throws {
        let suite = "MobileZoomPreferencesTests.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(MobileZoomPreferences.loadChatScale(defaults: defaults) == 1.0)
        #expect(MobileZoomPreferences.loadTerminalFontSize(defaults: defaults) == 11.0)

        MobileZoomPreferences.saveChatScale(1.45, defaults: defaults)
        #expect(MobileZoomPreferences.loadChatScale(defaults: defaults) == 1.45)
        #expect(MobileZoomPreferences.loadTerminalFontSize(defaults: defaults) == 11.0)

        MobileZoomPreferences.saveTerminalFontSize(17.5, defaults: defaults)
        #expect(MobileZoomPreferences.loadTerminalFontSize(defaults: defaults) == 17.5)
        #expect(MobileZoomPreferences.loadChatScale(defaults: defaults) == 1.45)
    }

    @Test("legacy SessionTextSize fallback and explicit Chat zoom override")
    func fallbackAndOverridePrecedence() throws {
        let suite = "MobileZoomPreferencesTests.fallback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(MobileZoomPreferences.loadChatScale(defaults: defaults, fallbackScale: 1.3) == 1.3)
        MobileZoomPreferences.saveChatScale(0.88, defaults: defaults)
        #expect(MobileZoomPreferences.loadChatScale(defaults: defaults, fallbackScale: 1.3) == 0.88)
    }

    @Test("clamping, rounding, and magnification guards")
    func clampingAndRounding() {
        #expect(MobileZoomPreferences.clampChatScale(.nan) == 1.0)
        #expect(MobileZoomPreferences.clampChatScale(.infinity) == 1.0)
        #expect(MobileZoomPreferences.clampChatScale(0.25) == 0.70)
        #expect(MobileZoomPreferences.clampChatScale(4.0) == 2.00)
        #expect(MobileZoomPreferences.clampChatScale(1.236) == 1.24)
        #expect(MobileZoomPreferences.scaledChatScale(from: 1.0, magnification: 1.45) == 1.45)
        #expect(MobileZoomPreferences.scaledChatScale(from: 1.45, magnification: 0) == 1.45)
        #expect(MobileZoomPreferences.scaledChatScale(from: 1.45, magnification: .nan) == 1.45)

        #expect(MobileZoomPreferences.clampTerminalFontSize(.nan) == 11.0)
        #expect(MobileZoomPreferences.clampTerminalFontSize(-.infinity) == 11.0)
        #expect(MobileZoomPreferences.clampTerminalFontSize(3.0) == 7.0)
        #expect(MobileZoomPreferences.clampTerminalFontSize(40.0) == 24.0)
        #expect(MobileZoomPreferences.clampTerminalFontSize(13.26) == 13.5)
        #expect(MobileZoomPreferences.scaledTerminalFontSize(from: 11.0, magnification: 1.6) == 17.5)
        #expect(MobileZoomPreferences.scaledTerminalFontSize(from: 17.5, magnification: -1.0) == 17.5)
        #expect(MobileZoomPreferences.scaledTerminalFontSize(from: 17.5, magnification: .infinity) == 17.5)
    }

    @Test("live Chat pinch reflow stepping reaches exact bounds")
    func liveChatReflowStepping() {
        #expect(!MobileZoomPreferences.shouldApplyLiveChatScale(1.0, current: 1.0))
        #expect(!MobileZoomPreferences.shouldApplyLiveChatScale(1.02, current: 1.0))
        #expect(MobileZoomPreferences.shouldApplyLiveChatScale(1.03, current: 1.0))
        #expect(MobileZoomPreferences.shouldApplyLiveChatScale(MobileZoomPreferences.chatMinScale, current: 0.71))
        #expect(MobileZoomPreferences.shouldApplyLiveChatScale(MobileZoomPreferences.chatMaxScale, current: 1.99))
    }
}
