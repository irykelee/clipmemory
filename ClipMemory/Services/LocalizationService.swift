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
        // F-7 (2026-07-23 audit): when the Localizable.strings entry uses
        // the .stringsdict plural marker `%#@var@`, plain `String(format:)`
        // can't resolve the right plural form — Foundation needs
        // `String.localizedStringWithFormat` for that. Detect the marker
        // and route accordingly; other keys keep the cheap `String(format:)`
        // path so we don't pay the .stringsdict lookup cost on every call.
        if template.contains("%#@") {
            return String.localizedStringWithFormat(template, args)
        }
        return String(format: template, arguments: args)
    }

    // MARK: - Private

    // M-22 (2026-07-24 audit): `cachedBundle`/`cachedLanguage` were plain
    // mutable statics with no sync. Two concurrent first-callers (e.g. a
    // @MainActor view body and a background OCR completion that both touch
    // a localized string) would race on the read+write and either return a
    // stale bundle or both pay the `Bundle(path:)` cost. `NSLock` wraps the
    // read-modify-write below; reads on the hot path that hit the cache
    // still take the lock briefly, but `Bundle.main.path` + `Bundle(path:)`
    // dwarf the lock cost.
    private static let cacheLock = NSLock()
    private static var cachedLanguage: String?
    private static var cachedBundle: Bundle?

    private static var currentBundle: Bundle {
        let lang = LanguageManager.shared.selectedLanguage
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let bundle = cachedBundle, cachedLanguage == lang {
            return bundle
        }
        let bundle = Bundle.main.path(forResource: lang, ofType: "lproj")
            .flatMap { Bundle(path: $0) } ?? Bundle.main
        cachedLanguage = lang
        cachedBundle = bundle
        return bundle
    }

    // BUG-048 (2026-07-21): cache englishBundle. Without this, every
    // localization miss re-runs Bundle.main.path + Bundle(path:) — both
    // non-trivial. The bundle path doesn't change at runtime.
    private static let englishBundle: Bundle = {
        Bundle.main.path(forResource: "en", ofType: "lproj")
            .flatMap { Bundle(path: $0) } ?? Bundle.main
    }()

    private static func getFromBundle(_ key: String, bundle: Bundle) -> String? {
        let result = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        // localizedString returns the key itself when not found - return nil to trigger fallback
        return result == key ? nil : result
    }

    // MARK: - Convenience Accessors

    static var appName: String { string("app.name") }
    static var buttonClear: String { string("button.clear") }
    static var buttonSettings: String { string("button.settings") }
    static var buttonCancel: String { string("button.cancel") }
    static var buttonDelete: String { string("button.delete") }
    static var buttonConfirm: String { string("button.confirm") }
    static var buttonClose: String { string("button.close") }
    static var buttonDone: String { string("button.done") }

    static var headerClearHistory: String { string("header.clear.history") }
    static var headerShowPinned: String { string("header.show.pinned") }

    static var searchPlaceholder: String { string("search.placeholder") }

    static var emptyNoHistory: String { string("empty.no.history") }
    static var emptyNoPinned: String { string("empty.no.pinned") }
    static var emptyHistoryHint: String { string("empty.history.hint") }
    static var emptyPinnedHint: String { string("empty.pinned.hint") }

    static var actionPin: String { string("action.pin") }
    static var actionUnpin: String { string("action.unpin") }
    static var actionDelete: String { string("action.delete") }
    static var actionCopy: String { string("action.copy") }
    static var actionShowContent: String { string("action.show.content") }
    static var actionHideContent: String { string("action.hide.content") }
    // F-19 (2026-07-23 audit): VoiceOver labels for the row select checkbox.
    // The button is icon-only (`checkmark.circle.fill` vs `circle`) — without
    // these labels, VoiceOver reads "button" with no functional hint.
    static var actionSelect: String { string("action.select") }
    static var actionDeselect: String { string("action.deselect") }

    static var tooltipUnpin: String { string("tooltip.unpin") }
    static var tooltipPin: String { string("tooltip.pin") }
    static var tooltipDelete: String { string("tooltip.delete") }
    static var imageMissing: String { string("image.missing") }
    static var imageDecryptionFailed: String { string("image.decryptionFailed") }
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
    static var sidebarDeleteTag: String { string("sidebar.deleteTag") }
    static var sidebarDeleteTagConfirmTitle: String { string("sidebar.deleteTag.confirm.title") }
    static func sidebarDeleteTagConfirmMessage(_ name: String, _ count: Int) -> String { string("sidebar.deleteTag.confirm.message", name, count) }
    // L-17 (2026-07-24 audit): explicit accessibility labels so VoiceOver
    // reads "Tag Work, 5 items" instead of the bare "Work, 5". Lives on the
    // tag-row accessibility modifier (see SidebarTagRow).
    static func sidebarTagAccessibilityLabel(_ name: String, _ count: Int) -> String { string("sidebar.tag.accessibility.label", name, count) }
    static var sidebarTagAccessibilitySelected: String { string("sidebar.tag.accessibility.selected") }
    static var sidebarTagAccessibilityUnselected: String { string("sidebar.tag.accessibility.unselected") }
    static var newTagTitle: String { string("newTag.title") }
    static var newTagCreate: String { string("newTag.create") }
    static var newTagCustomColor: String { string("newTag.customColor") }

    static var alertClearTitle: String { string("alert.clear.title") }
    static func alertClearMessage(_ count: Int) -> String { string("alert.clear.message", count) }
    static var alertClearNone: String { string("alert.clear.none") }
    static var alertDeleteTitle: String { string("alert.delete.title") }
    static var alertDeleteMessage: String { string("alert.delete.message") }
    static var settingsLaunchAtLoginErrorBody: String { string("settings.launch.at.login.error.body") }

    // MARK: - Recycle Bin (Trash)

    static var trashTitle: String { string("trash.title") }
    static var trashEmpty: String { string("trash.empty") }
    static var trashRestore: String { string("trash.restore") }
    static var trashEmptyConfirmTitle: String { string("trash.emptyConfirm.title") }
    static func trashEmptyConfirmMessage(_ count: Int) -> String { string("trash.emptyConfirm.message", count) }
    static var trashRetentionDays: String { string("trash.retentionDays") }
    // F-1 (2026-07-23 audit): per-row permanent-delete confirmation. The
    // bulk `trashEmptyConfirmTitle` reads "Empty Trash" which is wrong
    // for a single-item dialog — different copy, different action surface.
    static var trashDeleteConfirmTitle: String { string("trash.deleteConfirm.title") }
    static var trashDeleteConfirmConfirm: String { string("trash.deleteConfirm.confirm") }

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
    static var settingsAddExcludedApp: String { string("settings.add.excluded.app") }
    static var settingsSectionUpdate: String { string("settings.section.update") }
    static var settingsUpdateAuto: String { string("settings.update.auto") }
    static var settingsUpdateCheckNow: String { string("settings.update.check.now") }
    static func settingsUpdateLastCheck(_ date: String) -> String { string("settings.update.last.check", date) }
    static var settingsSectionBackup: String { string("settings.section.backup") }
    static var settingsBackupAuto: String { string("settings.backup.auto") }
    static var settingsBackupKeep: String { string("settings.backup.keep") }
    static var settingsBackupNow: String { string("settings.backup.now") }
    static var settingsBackupOpen: String { string("settings.backup.open") }
    static var settingsBackupExport: String { string("settings.backup.export") }
    static var settingsBackupImport: String { string("settings.backup.import") }
    static var settingsBackupPassphrase: String { string("settings.backup.passphrase") }
    // H-2 (2026-07-23): informativeText for promptBackupPassphrase.
    // Tells users the passphrase will be needed again to restore, not just
    // asking for an opaque password. Reduces confusion when the user later
    // cannot recall why they typed one.
    static var settingsBackupPassphraseInfo: String { string("settings.backup.passphrase.info") }
    static var settingsBackupPassphraseWrong: String { string("settings.backup.passphrase.wrong") }
    // 3.1 (2026-07-23): re-prompt feedback when user enters a passphrase
    // shorter than the 6-char minimum. Previously the alert closed with
    // no feedback, making Export look broken.
    static var passphraseTooShortTitle: String { string("passphrase.tooShort.title") }
    static var passphraseTooShortMessage: String { string("passphrase.tooShort.message") }
    static var settingsBackupError: String { string("settings.backup.error") }
    // H-3 (2026-07-23): distinguishes root-encryption-key-missing from a
    // generic "operation failed". The previous generic message sent users
    // hunting for transport / disk / permission causes when the real issue
    // is that CryptoService.loadKeyData() returned nil (Keychain empty +
    // .encryption_key fallback file gone). Tells them to reset encryption
    // from Settings instead of retrying.
    static var settingsBackupErrorMissingEncryptionKey: String { string("settings.backup.error.missingEncryptionKey") }
    static var settingsBackupExportDone: String { string("settings.backup.export.done") }
    static func settingsBackupImportResult(_ added: Int, _ skipped: Int, _ corrupt: Int, _ images: Int) -> String { string("settings.backup.import.result", added, skipped, corrupt, images) }
    static func settingsBackupLast(_ date: String) -> String { string("settings.backup.last", date) }
    static func clearTypeAction(_ typeName: String) -> String { string("clear.type.action", typeName) }
    static func clearTypeConfirm(_ typeName: String, _ count: Int) -> String { string("clear.type.confirm", typeName, count) }
    static var clearConditionalAction: String { string("clear.conditional.action") }
    static var clearConditionalTitle: String { string("clear.conditional.title") }
    static var clearConditionalType: String { string("clear.conditional.type") }
    static var clearConditionalRange: String { string("clear.conditional.range") }
    static func clearConditionalConfirm(_ count: Int) -> String { string("clear.conditional.confirm", count) }
    static var tagDeleteOnlyTag: String { string("tag.delete.onlytag") }
    static var tagDeleteWithContent: String { string("tag.delete.withcontent") }
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
    static var itemOcrCopy: String { string("item.ocr.copy") }
    static var settingsOcrEnabled: String { string("settings.ocr.enabled") }
    static var settingsOcrHint: String { string("settings.ocr.hint") }


    static var quitApp: String { string("app.quit") }
    static var launchAtLogin: String { string("app.launch.at.login") }
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

    // MARK: - Key Failure Alert (H6)
    static var alertKeyCorruptTitle: String { string("alert.key.corrupt.title") }
    static var alertKeyCorruptMessage: String { string("alert.key.corrupt.message") }
    static var alertKeyRandomTitle: String { string("alert.key.random.title") }
    static var alertKeyRandomMessage: String { string("alert.key.random.message") }
    static var alertKeyStorageTitle: String { string("alert.key.storage.title") }
    static var alertKeyStorageMessage: String { string("alert.key.storage.message") }
    static var alertKeyButtonReset: String { string("alert.key.button.reset") }
    static var alertKeyButtonRetry: String { string("alert.key.button.retry") }

    // MARK: - Update Fallback Consent Alert (H1)
    static var alertUpdateFallbackTitle: String { string("alert.update.fallback.title") }
    static var alertUpdateFallbackMessage: String { string("alert.update.fallback.message") }
    static var alertUpdateFallbackUseMirror: String { string("alert.update.fallback.use.mirror") }
    static var alertUpdateFallbackPrimaryOnly: String { string("alert.update.fallback.primary.only") }

    // MARK: - Update Source Switch (Task 6)
    static var settingsUpdateSourceTitle: String { string("settings.updateSource.title") }
    static var settingsUpdateSourceOptionAutomatic: String { string("settings.updateSource.option.automatic") }
    static var settingsUpdateSourceOptionPrimary: String { string("settings.updateSource.option.primary") }
    static var settingsUpdateSourceOptionFallback: String { string("settings.updateSource.option.fallback") }
    static var settingsUpdateSourceStatusPanel: String { string("settings.updateSource.statusPanel") }

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
    static var unpinToday: String { string("unpin.today") }
    static var unpinYesterday: String { string("unpin.yesterday") }
    static var unpinOlder: String { string("unpin.older") }
    static var unpinAll: String { string("unpin.all") }

    // MARK: - QuickBar
    static func quickbarRecent(_ count: Int) -> String { string("quickbar.recent", count) }
    static var quickbarNoResults: String { string("quickbar.no.results") }
    static var quickbarOpenFull: String { string("quickbar.open.full") }

    // MARK: - Tips
    static var tipsTitle: String { string("tips.title") }
    static var tipsActions: String { string("tips.actions") }
    static var tipsKeyboard: String { string("tips.keyboard") }
    /// F-13 (2026-07-23 audit): was incorrectly bound to
    /// `quickbarRecent(8)` ("8 items"), which misleadingly implied that
    /// the ↑↓ keyboard nav was scoped to the most recent 8 items. Actual
    /// behavior navigates the full filtered list.
    static var tipsKeyUpdown: String { string("tips.key.updown") }
}
