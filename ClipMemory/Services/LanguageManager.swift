import Foundation
import SwiftUI

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: "appLanguage")
            applyLanguage()
            objectWillChange.send()
        }
    }

    private init() {
        let preferred = UserDefaults.standard.string(forKey: "appLanguage")
        if let preferred = preferred {
            self.selectedLanguage = preferred
        } else {
            let systemLang = Self.getSystemLanguage()
            self.selectedLanguage = systemLang
            UserDefaults.standard.set(systemLang, forKey: "appLanguage")
        }
        applyLanguage()
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
        defaults.set([selectedLanguage], forKey: "AppleLanguages")
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

struct SensitiveClearOption: Identifiable {
    let id = UUID()
    let hours: Int

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
