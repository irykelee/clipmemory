import Foundation
import SwiftUI

@MainActor
class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// Nonisolated mirror of `selectedLanguage` for off-main readers
    /// (e.g. `LocalizationService.currentBundle` running inside a
    /// `Task.detached` `CryptoService.prepareKey` failure handler).
    /// Written from `didSet` on the main actor; reads are best-effort and
    /// tolerate one-tick staleness across thread boundaries.
    /// Marked `nonisolated(unsafe)` because Swift cannot prove the
    /// single-writer / many-reader discipline at compile time.
    nonisolated(unsafe) static var currentLanguageCode: String = "en"

    @Published var selectedLanguage: String {
        didSet {
            // @MainActor guarantees didSet runs on main; publish to the
            // off-main cache before the notification so any listener that
            // reads `currentLanguageCode` in response sees the new value.
            Self.currentLanguageCode = selectedLanguage
            UserDefaults.standard.set(selectedLanguage, forKey: "appLanguage")
            applyLanguage()
            NotificationCenter.default.post(name: Notification.Name("LanguageDidChange"), object: nil)
        }
    }

    private init() {
        // BUG-050 (2026-07-21): simplify init — nil/non-nil branch split
        // wrote to UserDefaults inconsistently (only the nil branch).
        // Both branches now converge: derive the language, assign; didSet
        // handles persistence and application. Init runs on main in production.
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? Self.getSystemLanguage()
        self.selectedLanguage = lang
        // didSet observers do NOT fire during Swift init, so currentLanguageCode
        // (the nonisolated mirror added in pilot commit 153d25d) must be seeded
        // explicitly here. Without this, off-main readers of LocalizationService
        // observe the default "en" instead of the user's saved language until the
        // first post-init language change. Same applies to any future cache fields
        // initialized from selectedLanguage.
        Self.currentLanguageCode = lang
    }

    static func getSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh-Hant") {
            return "zh-Hant"
        }
        if preferred.hasPrefix("zh") {
            return "zh-Hans"
        }
        if preferred.hasPrefix("ja") {
            return "ja"
        }
        if preferred.hasPrefix("ko") {
            return "ko"
        }
        if preferred.hasPrefix("es") {
            return "es"
        }
        if preferred.hasPrefix("pt") {
            return "pt"
        }
        return "en"
    }

    func applyLanguage() {
        let defaults = UserDefaults.standard
        // L8: Prepend selectedLanguage to existing AppleLanguages chain instead of
        // replacing it entirely, preserving system language fallback behavior.
        var languages = defaults.stringArray(forKey: "AppleLanguages") ?? ["en"]
        if let existingIndex = languages.firstIndex(of: selectedLanguage) {
            languages.remove(at: existingIndex)
        }
        languages.insert(selectedLanguage, at: 0)
        defaults.set(languages, forKey: "AppleLanguages")
    }

    var availableLanguages: [(code: String, name: String)] {
        [
            ("zh-Hans", "简体中文"),
            ("zh-Hant", "繁體中文"),
            ("en", "English"),
            ("ja", "日本語"),
            ("ko", "한국어"),
            ("es", "Español"),
            ("pt", "Português")
        ]
    }

    var currentLanguageName: String {
        availableLanguages.first { $0.code == selectedLanguage }?.name ?? "English"
    }
}

struct SensitiveClearOption {
    let hours: Int

    init(hours: Int) {
        self.hours = hours
    }

    var label: String {
        switch hours {
        case 1: return L10n.sensitive1Hour
        case 24: return L10n.sensitive24Hours
        case 48: return L10n.sensitive48Hours
        case 168: return L10n.sensitive7Days
        case 0: return L10n.sensitiveNever
        default: return "\(hours) hours"
        }
    }

    static var options: [SensitiveClearOption] {
        [
            SensitiveClearOption(hours: 1),
            SensitiveClearOption(hours: 24),
            SensitiveClearOption(hours: 48),
            SensitiveClearOption(hours: 168),
            SensitiveClearOption(hours: 0)
        ]
    }
}
