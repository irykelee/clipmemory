import Foundation
import SwiftUI

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var selectedLanguage: String {
        didSet {
            // L-7 (2026-07-25 audit): `selectedLanguage` may in theory be set
            // from a background queue (e.g. a future settings import or
            // command-line override). UserDefaults and AppleLanguages must be
            // touched on the main thread. Keep the synchronous fast path when
            // already on main, otherwise hop.
            let apply = { [weak self] in
                guard let self = self else { return }
                UserDefaults.standard.set(self.selectedLanguage, forKey: "appLanguage")
                self.applyLanguage()
                NotificationCenter.default.post(name: Notification.Name("LanguageDidChange"), object: nil)
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
    }

    private init() {
        // BUG-050 (2026-07-21): simplify init — nil/non-nil branch split
        // wrote to UserDefaults inconsistently (only the nil branch).
        // Both branches now converge: derive the language, assign; didSet
        // handles persistence and application. Init runs on main in production.
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? Self.getSystemLanguage()
        self.selectedLanguage = lang
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
