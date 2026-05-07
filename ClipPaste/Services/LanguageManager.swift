import Foundation
import SwiftUI

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: "appLanguage")
            applyLanguage()
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
        if preferred.hasPrefix("zh") {
            return "zh-Hans"
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
            ("en", "English")
        ]
    }
}

struct SensitiveClearOption: Identifiable {
    let id = UUID()
    let hours: Int
    let label: String

    static let options: [SensitiveClearOption] = [
        SensitiveClearOption(hours: 1, label: "1 小时"),
        SensitiveClearOption(hours: 24, label: "24 小时"),
        SensitiveClearOption(hours: 48, label: "48 小时"),
        SensitiveClearOption(hours: 168, label: "7 天"),
        SensitiveClearOption(hours: 0, label: "不自动清除")
    ]
}
