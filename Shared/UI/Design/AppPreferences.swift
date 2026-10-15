import Foundation
import SwiftUI

/// In-app language override. `.system` clears the override and follows the OS.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let storageKey = "corral.appLanguage"
    static let `default` = AppLanguage.system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "settings.language.system"
        case .english: "settings.language.english"
        case .simplifiedChinese: "settings.language.simplified_chinese"
        }
    }

    /// Locale applied to the SwiftUI environment for an immediate switch.
    /// nil follows the system language.
    var locale: Locale? {
        switch self {
        case .system: nil
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }

    /// Codes written to AppleLanguages so Foundation `String(localized:)`
    /// lookups and relaunched scenes use the same language.
    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .simplifiedChinese: ["zh-Hans"]
        }
    }

    static func resolve(stored: String?) -> AppLanguage {
        stored.flatMap(AppLanguage.init(rawValue:)) ?? .default
    }
}

/// Light / dark / follow-system appearance. `.system` passes nil to
/// `preferredColorScheme`, which follows the OS appearance.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let storageKey = "corral.appAppearance"
    static let `default` = AppAppearance.system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "settings.appearance.system"
        case .light: "settings.appearance.light"
        case .dark: "settings.appearance.dark"
        }
    }

    /// nil follows the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolve(stored: String?) -> AppAppearance {
        stored.flatMap(AppAppearance.init(rawValue:)) ?? .default
    }
}

enum AppLanguageSynchronizer {
    /// Mirror the in-app choice into AppleLanguages so non-SwiftUI lookups
    /// (`String(localized:)`) agree after relaunch. Only called from the
    /// settings UI, never at launch, so an OS-level per-app language is left
    /// alone until the user explicitly picks something here.
    static func apply(_ language: AppLanguage) {
        if let codes = language.appleLanguages {
            UserDefaults.standard.set(codes, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}
