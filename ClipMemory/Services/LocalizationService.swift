import Foundation

/// Centralized localization service using system String(localized:)
/// Falls back to English if the key is not found in the current language
struct L10n {
    /// Get a localized string by key
    /// - Parameter key: The localization key (e.g., "button.clear")
    /// - Returns: The localized string or the key itself if not found
    static func string(_ key: String) -> String {
        if let result = getFromBundle(key, bundle: currentBundle) {
            return result
        }
        if let result = getFromBundle(key, bundle: englishBundle) {
            return result
        }
        return key
    }

    /// Get a localized string with format arguments
    /// - Parameters:
    ///   - key: The localization key
    ///   - args: The format arguments
    /// - Returns: The formatted localized string
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, arguments: args)
    }

    // MARK: - Private

    private static var currentBundle: Bundle {
        let lang = LanguageManager.shared.selectedLanguage
        return Bundle.main.path(forResource: lang, ofType: "lproj")
            .flatMap { Bundle(path: $0) } ?? Bundle.main
    }

    private static var englishBundle: Bundle {
        Bundle.main.path(forResource: "en", ofType: "lproj")
            .flatMap { Bundle(path: $0) } ?? Bundle.main
    }

    private static func getFromBundle(_ key: String, bundle: Bundle) -> String? {
        let result = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        // localizedString returns the key itself when not found - return nil to trigger fallback
        return result == key ? nil : result
    }

    // MARK: - Convenience Accessors

    static var appName: String { string("app.name") }
    static var buttonClear: String { string("button.clear") }
    static var buttonSettings: String { string("button.settings") }
    static var buttonBack: String { string("button.back") }
    static var buttonCancel: String { string("button.cancel") }
    static var buttonDelete: String { string("button.delete") }
    static var buttonConfirm: String { string("button.confirm") }

    static var headerClearHistory: String { string("header.clear.history") }
    static var headerShowAll: String { string("header.show.all") }
    static var headerShowPinned: String { string("header.show.pinned") }
    static var headerPinAll: String { string("header.pin.all") }

    static var searchPlaceholder: String { string("search.placeholder") }

    static var emptyNoHistory: String { string("empty.no.history") }
    static var emptyNoPinned: String { string("empty.no.pinned") }
    static var emptyHistoryHint: String { string("empty.history.hint") }
    static var emptyPinnedHint: String { string("empty.pinned.hint") }

    static var actionPin: String { string("action.pin") }
    static var actionUnpin: String { string("action.unpin") }
    static var actionDelete: String { string("action.delete") }
    static var actionCopy: String { string("action.copy") }
    static var actionView: String { string("action.view") }
    static var actionHide: String { string("action.hide") }
    static var actionShowContent: String { string("action.show.content") }
    static var actionHideContent: String { string("action.hide.content") }

    static var tooltipUnpin: String { string("tooltip.unpin") }
    static var tooltipPin: String { string("tooltip.pin") }
    static var tooltipDelete: String { string("tooltip.delete") }
    static var tooltipClearHistory: String { string("tooltip.clear.history") }
    static var tooltipShowAll: String { string("tooltip.show.all") }
    static var tooltipPinnedOnly: String { string("tooltip.pinned.only") }
    static var tooltipReveal: String { string("tooltip.reveal") }
    static var tooltipHide: String { string("tooltip.hide") }

    static var alertClearTitle: String { string("alert.clear.title") }
    static func alertClearMessage(_ count: Int) -> String { string("alert.clear.message", count) }
    static var alertClearNone: String { string("alert.clear.none") }
    static var alertDeleteTitle: String { string("alert.delete.title") }
    static var alertDeleteMessage: String { string("alert.delete.message") }

    static var settingsTitle: String { string("settings.title") }
    static var settingsSectionHistory: String { string("settings.section.history") }
    static var settingsSectionSensitive: String { string("settings.section.sensitive") }
    static var settingsSectionLanguage: String { string("settings.section.language") }
    static var settingsSectionAbout: String { string("settings.section.about") }
    static var settingsMaxItems: String { string("settings.max.items") }
    static func settingsMaxItemsCount(_ count: Int) -> String { string("settings.max.items.count", count) }
    static var settingsAutoClear: String { string("settings.auto.clear") }
    static var settingsSensitiveHint: String { string("settings.sensitive.hint") }

    static var sensitive1Hour: String { string("sensitive.1.hour") }
    static var sensitive24Hours: String { string("sensitive.24.hours") }
    static var sensitive48Hours: String { string("sensitive.48.hours") }
    static var sensitive7Days: String { string("sensitive.7.days") }
    static var sensitiveNever: String { string("sensitive.never") }

    static func aboutVersion(_ version: String) -> String { string("about.version", version) }
    static var aboutFreeEdition: String { string("about.free.edition") }
    static var aboutPaidEdition: String { string("about.paid.edition") }

    static var itemSensitive: String { string("item.sensitive") }
    static var itemImage: String { string("item.image") }
    static var itemUnpinAll: String { string("item.unpin.all") }

    static func langName(_ code: String) -> String { string("lang.\(code)") }

    static var quitApp: String { string("app.quit") }
    static var launchAtLogin: String { string("app.launch.at.login") }
    static var launchAtLoginEnabled: String { string("app.launch.at.login.enabled") }
    static var launchAtLoginEnabledBody: String { string("app.launch.at.login.enabled.body") }
    static var launchAtLoginDisabled: String { string("app.launch.at.login.disabled") }
    static var launchAtLoginDisabledBody: String { string("app.launch.at.login.disabled.body") }
    static var error: String { string("app.error") }
    static func batchSelected(_ count: Int) -> String { string("batch.selected", count) }
}
