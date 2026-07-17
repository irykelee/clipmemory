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
    static var buttonClose: String { string("button.close") }
    static var buttonDone: String { string("button.done") }

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
    static var imageMissing: String { string("image.missing") }
    static var tooltipClearHistory: String { string("tooltip.clear.history") }
    static var tooltipShowAll: String { string("tooltip.show.all") }
    static var tooltipPinnedOnly: String { string("tooltip.pinned.only") }
    static var tooltipReveal: String { string("tooltip.reveal") }
    static var tooltipHide: String { string("tooltip.hide") }
    static var imageDecryptionFailed: String { string("image.decryptionFailed") }
    static var tooltipClose: String { string("tooltip.close") }
    static var tooltipMinimize: String { string("tooltip.minimize") }
    static var tooltipZoom: String { string("tooltip.zoom") }
    static var tooltipEditTags: String { string("tooltip.editTags") }

    // MARK: - Tag suggestions
    static var tagSuggestionKindCode: String { string("tagSuggestion.kind.code") }
    static var tagSuggestionKindEmail: String { string("tagSuggestion.kind.email") }
    static var tagSuggestionKindCredential: String { string("tagSuggestion.kind.credential") }
    static var tagSuggestionKindSensitive: String { string("tagSuggestion.kind.sensitive") }

    // MARK: - Tag picker sheet (Task #16)
    static var tagPickerTitle: String { string("tagPicker.title") }
    static var tagPickerSectionSuggestions: String { string("tagPicker.section.suggestions") }
    static var tagPickerSectionAllTags: String { string("tagPicker.section.allTags") }
    static var tagPickerSectionSuggestedNames: String { string("tagPicker.section.suggestedNames") }
    static var tagPickerCreate: String { string("tagPicker.create") }
    static var tagPickerCreateButton: String { string("tagPicker.create.button") }
    static var tagPickerUseExisting: String { string("tagPicker.useExisting") }
    static func tagPickerNameConflict(_ name: String) -> String { string("tagPicker.nameConflict", name) }
    static var tagPickerDeleteConfirmTitle: String { string("tagPicker.deleteConfirm.title") }
    static func tagPickerDeleteConfirmMessage(_ name: String, _ count: Int) -> String { string("tagPicker.deleteConfirm.message", name, count) }
    static var tagPickerDeleteConfirmConfirm: String { string("tagPicker.deleteConfirm.confirm") }
    static var tagPickerNameSuggestionsToggle: String { string("tagPicker.nameSuggestions.toggle") }

    // MARK: - Sidebar tag section (Task #17)
    static var sidebarSectionTags: String { string("sidebar.section.tags") }
    static var sidebarTagsEmpty: String { string("sidebar.tags.empty") }
    static var sidebarNewTag: String { string("sidebar.newTag") }
    static var newTagTitle: String { string("newTag.title") }
    static var newTagCreate: String { string("newTag.create") }

    static var alertClearTitle: String { string("alert.clear.title") }
    static func alertClearMessage(_ count: Int) -> String { string("alert.clear.message", count) }
    static var alertClearNone: String { string("alert.clear.none") }
    static var alertDeleteTitle: String { string("alert.delete.title") }
    static var alertDeleteMessage: String { string("alert.delete.message") }
    static func alertClearGroupMessage(_ count: Int, _ groupLabel: String) -> String { string("alert.clear.group.message", count, groupLabel) }
    static var settingsLaunchAtLoginErrorBody: String { string("settings.launch.at.login.error.body") }

    static var settingsTitle: String { string("settings.title") }
    static var settingsSectionHistory: String { string("settings.section.history") }
    static var settingsSectionSensitive: String { string("settings.section.sensitive") }
    static var settingsSectionLanguage: String { string("settings.section.language") }
    static var settingsSectionHotkey: String { string("settings.section.hotkey") }
    static var settingsSectionExcludedApps: String { string("settings.section.excluded.apps") }
    static var settingsSectionAbout: String { string("settings.section.about") }
    static var settingsMaxItems: String { string("settings.max.items") }
    static func settingsMaxItemsCount(_ count: Int) -> String { string("settings.max.items.count", count) }
    static var settingsAutoClear: String { string("settings.auto.clear") }
    static var settingsCaptureRichText: String { string("settings.capture.richtext") }
    static var settingsCaptureRichTextHint: String { string("settings.capture.richtext.hint") }
    static var settingsSensitiveHint: String { string("settings.sensitive.hint") }
    static var settingsHotkeyChange: String { string("settings.hotkey.change") }
    static var settingsHotkeyRecording: String { string("settings.hotkey.recording") }
    static var settingsHotkeyReset: String { string("settings.hotkey.reset") }
    static var settingsExcludedAppsPlaceholder: String { string("settings.excluded.apps.placeholder") }
    static var settingsExcludedAppsLabel: String { string("settings.excluded.apps.label") }
    static var settingsExcludedAppsHint: String { string("settings.excluded.apps.hint") }
    static var settingsExcludedAppsNone: String { string("settings.excluded.apps.none") }
    static var settingsAddExcludedApp: String { string("settings.add.excluded.app") }
    static var settingsAppPickerSearch: String { string("settings.app.picker.search") }
    static var settingsAppPickerNoResults: String { string("settings.app.picker.no.results") }
    static var settingsFontSize: String { string("settings.font.size") }
    static var fontSizeSmall: String { string("font.size.small") }
    static var fontSizeMedium: String { string("font.size.medium") }
    static var fontSizeLarge: String { string("font.size.large") }

    static var sensitive1Hour: String { string("sensitive.1.hour") }
    static var sensitive24Hours: String { string("sensitive.24.hours") }
    static var sensitive48Hours: String { string("sensitive.48.hours") }
    static var sensitive7Days: String { string("sensitive.7.days") }
    static var sensitiveNever: String { string("sensitive.never") }

    static func aboutVersion(_ version: String) -> String { string("about.version", version) }
    static var aboutFreeEdition: String { string("about.free.edition") }
    // L1: aboutPaidEdition — unused dead code, removed

    static var itemSensitive: String { string("item.sensitive") }
    static var itemImage: String { string("item.image") }
    static var itemRichText: String { string("item.richText") }
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
    static var sendFeedback: String { string("app.send.feedback") }
    static var viewWelcomeGuide: String { string("app.view.welcome.guide") }
    static var alertEncryptFailed: String { string("alert.encrypt.failed") }

    // MARK: - Trim Alert
    static var alertTrimTitle: String { string("alert.trim.title") }
    static func alertTrimMessage(_ current: Int, _ max: Int) -> String { string("alert.trim.message", current, max) }
    static var alertTrimConfirm: String { string("alert.trim.confirm") }
    static var alertTrimCancel: String { string("alert.trim.cancel") }

    static var filterRichText: String { string("filter.richtext") }

    // MARK: - Type Filter
    static var filterAll: String { string("filter.all") }
    static var filterText: String { string("filter.text") }
    static var filterImage: String { string("filter.image") }
    static var filterLink: String { string("filter.link") }

    // MARK: - Welcome View
    static var welcomeTitle: String { string("welcome.title") }
    static var welcomeSubtitle: String { string("welcome.subtitle") }
    static var welcomeStep1Title: String { string("welcome.step1.title") }
    static var welcomeStep1Desc: String { string("welcome.step1.desc") }
    static var welcomeStep2Title: String { string("welcome.step2.title") }
    static func welcomeStep2Desc(_ hotkey: String) -> String { string("welcome.step2.desc", hotkey) }
    static var welcomeStep3Title: String { string("welcome.step3.title") }
    static var welcomeStep3Desc: String { string("welcome.step3.desc") }
    static var welcomeStep4Title: String { string("welcome.step4.title") }
    static var welcomeStep4Desc: String { string("welcome.step4.desc") }
    static var welcomeStep5Title: String { string("welcome.step5.title") }
    static var welcomeStep5Desc: String { string("welcome.step5.desc") }
    static var welcomeStep6Title: String { string("welcome.step6.title") }
    static var welcomeStep6Desc: String { string("welcome.step6.desc") }
    static var welcomeHotkeyConflict: String { string("welcome.hotkey.conflict") }
    static var welcomeGetStarted: String { string("welcome.get.started") }

    // MARK: - Theme
    static var settingsSectionTheme: String { string("settings.section.theme") }
    static var themeEffect: String { string("theme.effect") }
    static var themeEffectSolid: String { string("theme.effect.solid") }
    static var themeEffectFrosted: String { string("theme.effect.frosted") }
    static var themeEffectUltra: String { string("theme.effect.ultra") }
    static var themeAppearance: String { string("theme.appearance") }
    static var themeAppearanceSystem: String { string("theme.appearance.system") }
    static var themeAppearanceLight: String { string("theme.appearance.light") }
    static var themeAppearanceDark: String { string("theme.appearance.dark") }

    // MARK: - Time Groups
    static var groupToday: String { string("group.today") }
    static var groupYesterday: String { string("group.yesterday") }
    static var groupOlder: String { string("group.older") }
    static var dateFilterAll: String { string("date.filter.all") }

    // MARK: - Cleanup
    static var clearToday: String { string("cleanup.today") }
    static var clearYesterday: String { string("cleanup.yesterday") }
    static var clearOlder: String { string("cleanup.older") }
    static var clearAll: String { string("cleanup.all") }
    static var unpinToday: String { string("unpin.today") }
    static var unpinYesterday: String { string("unpin.yesterday") }
    static var unpinOlder: String { string("unpin.older") }
    static var unpinAll: String { string("unpin.all") }
    static var unpinAllButton: String { string("action.unpin") }

    // MARK: - QuickBar
    static func quickbarRecent(_ count: Int) -> String { string("quickbar.recent", count) }
    static var quickbarNoResults: String { string("quickbar.no.results") }
    static var quickbarOpenFull: String { string("quickbar.open.full") }

    // MARK: - Tips
    static var tipsTitle: String { string("tips.title") }
    static var tipsActions: String { string("tips.actions") }
    static var tipsKeyboard: String { string("tips.keyboard") }
}
