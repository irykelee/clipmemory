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
            ("en", "English"),
            ("ja", "日本語"),
            ("ko", "한국어"),
            ("es", "Español"),
            ("pt", "Português")
        ]
    }
}

struct SensitiveClearOption: Identifiable {
    let id = UUID()
    let hours: Int

    var label: String {
        let lm = LanguageManager.shared.selectedLanguage
        if lm == "zh-Hans" {
            return Self.labels_zh[hours] ?? "\(hours) 小时"
        } else if lm == "ja" {
            return Self.labels_ja[hours] ?? "\(hours) 時間"
        } else if lm == "ko" {
            return Self.labels_ko[hours] ?? "\(hours) 시간"
        } else if lm == "es" {
            return Self.labels_es[hours] ?? "\(hours) hours"
        } else if lm == "pt" {
            return Self.labels_pt[hours] ?? "\(hours) hours"
        }
        return Self.labels_en[hours] ?? "\(hours) hours"
    }

    private static let labels_zh: [Int: String] = [
        1: "1 小时", 24: "24 小时", 48: "48 小时", 168: "7 天", 0: "不自动清除"
    ]
    private static let labels_en: [Int: String] = [
        1: "1 hour", 24: "24 hours", 48: "48 hours", 168: "7 days", 0: "Never"
    ]
    private static let labels_ja: [Int: String] = [
        1: "1 時間", 24: "24 時間", 48: "48 時間", 168: "7 日間", 0: "自動削除しない"
    ]
    private static let labels_ko: [Int: String] = [
        1: "1시간", 24: "24시간", 48: "48시간", 168: "7일", 0: "자동 삭제 안함"
    ]
    private static let labels_es: [Int: String] = [
        1: "1 hora", 24: "24 horas", 48: "48 horas", 168: "7 días", 0: "Nunca"
    ]
    private static let labels_pt: [Int: String] = [
        1: "1 hora", 24: "24 horas", 48: "48 horas", 168: "7 dias", 0: "Nunca"
    ]

    static let options: [SensitiveClearOption] = [
        SensitiveClearOption(hours: 1),
        SensitiveClearOption(hours: 24),
        SensitiveClearOption(hours: 48),
        SensitiveClearOption(hours: 168),
        SensitiveClearOption(hours: 0)
    ]
}
