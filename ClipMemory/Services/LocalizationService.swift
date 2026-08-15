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

    /// Plural-aware variant for count-bearing messages. Picks "<key>.one"
    /// when count == 1 and the current language defines that key (en/es/pt
    /// have singular forms; the CJK languages define ".one" with the same
    /// value as the base key). Falls back to the base key when ".one"
    /// is absent from the CURRENT bundle (ID-L10N-0020: detected via a
    /// direct current-bundle lookup — the englishBundle fallback inside
    /// `string()` must not leak English singular forms into non-English
    /// languages).
    ///
    /// 2026-07-25: replaces the .stringsdict (`%#@count@`) mechanism, which
    /// was broken on multiple levels: all six keys shared ONE format key
    /// (ambiguous rule lookup), every entry lacked
    /// NSStringFormatValueTypeKey, `String.localizedStringWithFormat`
    /// resolves rules against the main bundle's SYSTEM localization
    /// (ignoring the in-app language override), and any key missing from
    /// the bundled stringsdict rendered as "(null)" — observed in the
    /// settings maxItems picker on macOS 26. Plain `%d` formatting routes
    /// through the proven `String(format:)` path in the correct bundle.
    ///
    /// ID-L10N-0018 (2026-07-31 audit): the CJK bundles originally omitted
    /// ".one" and relied on the missing-key fallback above — but `string()`
    /// consults the English bundle before declaring a key missing, and en
    /// defines every ".one", so CJK count==1 rendered English ("1 item").
    /// The 4 CJK bundles now carry ".one" keys (value == base) so the
    /// singular lookup resolves in the current bundle; the missing-key
    /// fallback stays as defense-in-depth.
    static func plural(_ key: String, _ count: Int) -> String {
        String(format: pluralTemplate(key, count), count)
    }

    /// ID-L10N-0016 (2026-07-30 audit): template-selection half of
    /// `plural()`, exposed for count-bearing messages that also carry other
    /// format arguments (e.g. a tag name) whose substitution order differs
    /// from the count's. Callers format the returned template themselves.
    private static func pluralTemplate(_ key: String, _ count: Int) -> String {
        if count == 1 {
            let singularKey = key + ".one"
            // ID-L10N-0020 (2026-08-01 audit): the presence check used to be
            // `string(singularKey) != singularKey` — but `string()` falls
            // back to englishBundle on a current-bundle miss, so a language
            // lacking ".one" would silently resolve to the ENGLISH singular
            // ("1 item") instead of its own plural base form. Check the
            // current bundle directly; on a miss, fall through to the base
            // key (current language, plural grammar) — the defense-in-depth
            // path the L10N-0018 comment describes.
            if let singular = getFromBundle(singularKey, bundle: currentBundle) {
                return singular
            }
        }
        return string(key)
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
        // Read the nonisolated mirror instead of the @MainActor-isolated
        // @Published property. The mirror is updated by LanguageManager.didSet
        // before the .LanguageDidChange notification fires, so any consumer
        // reacting to the notification sees a consistent value.
        let lang = LanguageManager.currentLanguageCode
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
    // ID-VIEW-0030/0032 (2026-08-13): share image items via NSSharingServicePicker.
    static var actionShare: String { string("action.share") }
    static func actionShareCount(_ count: Int) -> String { plural("action.share.count", count) }
    // ID-VIEW-0036 (2026-08-13): direct save-to-folder in the toolbar
    // Share menu (sibling to "Share...").
    static var actionExport: String { string("action.export") }
    static func exportPanelMessage(_ count: Int) -> String { plural("export.panel.message", count) }
    static func exportFileExistsTitle(_ filename: String) -> String {
        String(format: string("export.file.exists.title"), filename)
    }
    static var exportFileExistsBody: String { string("export.file.exists.body") }
    static var exportConflictReplace: String { string("export.conflict.replace") }
    static var exportConflictKeepBoth: String { string("export.conflict.keep.both") }
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
    // ID-L10N-0016 (2026-07-30 audit): route through the plural template so
    // count=1 picks the ".one" variant ("removed from 1 item") instead of
    // the grammatically plural base form.
    static func tagPickerDeleteConfirmMessage(_ name: String, _ count: Int) -> String {
        String(format: pluralTemplate("tagPicker.deleteConfirm.message", count), name, count)
    }
    static var tagPickerDeleteConfirmConfirm: String { string("tagPicker.deleteConfirm.confirm") }
    static var tagPickerNameSuggestionsToggle: String { string("tagPicker.nameSuggestions.toggle") }

    // MARK: - Sidebar tag section (Task #17)
    static var sidebarSectionTags: String { string("sidebar.section.tags") }
    static var sidebarTagsEmpty: String { string("sidebar.tags.empty") }
    static var sidebarNewTag: String { string("sidebar.newTag") }
    static var sidebarDeleteTag: String { string("sidebar.deleteTag") }
    static var sidebarDeleteTagConfirmTitle: String { string("sidebar.deleteTag.confirm.title") }
    // ID-L10N-0016 (2026-07-30 audit): plural-aware; count=1 uses ".one".
    static func sidebarDeleteTagConfirmMessage(_ name: String, _ count: Int) -> String {
        String(format: pluralTemplate("sidebar.deleteTag.confirm.message", count), name, count)
    }
    // L-17 (2026-07-24 audit): explicit accessibility labels so VoiceOver
    // reads "Tag Work, 5 items" instead of the bare "Work, 5". Lives on the
    // tag-row accessibility modifier (see SidebarTagRow).
    // ID-L10N-0016 (2026-07-30 audit): plural-aware; count=1 uses ".one".
    static func sidebarTagAccessibilityLabel(_ name: String, _ count: Int) -> String {
        String(format: pluralTemplate("sidebar.tag.accessibility.label", count), name, count)
    }
    static var sidebarTagAccessibilitySelected: String { string("sidebar.tag.accessibility.selected") }
    static var sidebarTagAccessibilityUnselected: String { string("sidebar.tag.accessibility.unselected") }
    static var newTagTitle: String { string("newTag.title") }
    static var newTagCreate: String { string("newTag.create") }
    static var newTagCustomColor: String { string("newTag.customColor") }

    // MARK: - Active tag filter chip strip (2026-07-27)
    // Surfaces the currently-applied tag filter at the top of the item list
    // so users don't read a short list as "missing content". Each chip has
    // an inline × to remove the tag, plus a "clear all" affordance.
    static var tagFilterActiveTitle: String { string("tagFilter.active.title") }
    static var tagFilterClearAll: String { string("tagFilter.clearAll") }
    static var tagFilterRemoveTag: String { string("tagFilter.removeTag") }
    /// "Showing X of Y items" — pins the count so users can see at a glance
    /// that the list is filtered, not truncated.
    static func tagFilterCount(_ shown: Int, _ total: Int) -> String { string("tagFilter.count", shown, total) }

    // MARK: - Tag picker sheet footer (2026-07-27)
    // Done button tooltip when no changes have been made. Helps users
    // understand why the button is grey instead of being confused by it.
    static var tagPickerDoneNoChangesHint: String { string("tagPicker.done.noChangesHint") }

    static var alertClearTitle: String { string("alert.clear.title") }
    static func alertClearMessage(_ count: Int) -> String { plural("alert.clear.message", count) }
    static var alertClearNone: String { string("alert.clear.none") }
    static var alertDeleteTitle: String { string("alert.delete.title") }
    static var alertDeleteMessage: String { string("alert.delete.message") }
    static var settingsLaunchAtLoginErrorBody: String { string("settings.launch.at.login.error.body") }

    // MARK: - Recycle Bin (Trash)

    static var trashTitle: String { string("trash.title") }
    static var trashEmpty: String { string("trash.empty") }
    static var trashRestore: String { string("trash.restore") }
    // NEW-batch-restore: multi-select toolbar labels
    static func trashBatchRestore(_ count: Int) -> String { plural("trash.batch.restore", count) }
    static var trashSelectAll: String { string("trash.selectAll") }
    static var trashSelectItem: String { string("trash.selectItem") }
    static var trashDeselectItem: String { string("trash.deselectItem") }
    static var trashEmptyConfirmTitle: String { string("trash.emptyConfirm.title") }
    static func trashEmptyConfirmMessage(_ count: Int) -> String { plural("trash.emptyConfirm.message", count) }
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
    static func settingsMaxItemsCount(_ count: Int) -> String { plural("settings.max.items.count", count) }
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
    // ID-L10N-0009 (2026-07-30 audit): parameterized options for picker
    // entries so the bare-number "3" / "7" / "14" / "30" gets unit context
    // (e.g. "3 backups" / "3 天"). AI-only translation per project policy.
    static func settingsBackupKeepCount(_ count: Int) -> String { plural("settings.backup.keep.count", count) }
    static var settingsBackupNow: String { string("settings.backup.now") }
    static var settingsBackupOpen: String { string("settings.backup.open") }
    // ID-L10N-0009 (2026-07-30 audit): see settingsBackupKeepCount above.
    static func trashRetentionDaysCount(_ count: Int) -> String { plural("settings.trash.retention.days.count", count) }
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
    // N-3 (2026-07-27): surfaces the last auto-backup failure in the
    // settings footer. Replaces the prior silent `try?` swallow.
    static func settingsBackupErrorLast(_ reason: String) -> String {
        string("settings.backup.error.last", reason)
    }
    static var settingsBackupExportDone: String { string("settings.backup.export.done") }
    static func settingsBackupImportResult(_ added: Int, _ skipped: Int, _ corrupt: Int, _ images: Int) -> String { string("settings.backup.import.result", added, skipped, corrupt, images) }
    // NEW-3 (2026-08-03 audit): shown when image import failed but
    // items/tags already merged. Plain string (no interpolation) so
    // all 7 locales can ship the same key without plural rule drift.
    static var settingsBackupImportImagesFailed: String { string("settings.backup.import.imagesFailed") }
    static func settingsBackupLast(_ date: String) -> String { string("settings.backup.last", date) }
    // ID-STORE-0016 (2026-08-15, L26 Path E): shown when pruneOldBackups
    // could not list the Backups/ directory. Distinct from
    // settingsBackupErrorLast because a prune failure is independent of the
    // backup run (next backupNow can still succeed) — collapsing would hide
    // the prune signal under a recent backup success.
    static func settingsBackupPruneErrorLast(_ reason: String) -> String {
        string("settings.backup.pruneError.last", reason)
    }
    static func clearTypeAction(_ typeName: String) -> String { string("clear.type.action", typeName) }
    // ID-L10N-0016 (2026-07-30 audit): plural-aware; count=1 uses ".one".
    static func clearTypeConfirm(_ typeName: String, _ count: Int) -> String {
        String(format: pluralTemplate("clear.type.confirm", count), typeName, count)
    }
    static var clearConditionalAction: String { string("clear.conditional.action") }
    static var clearConditionalTitle: String { string("clear.conditional.title") }
    static var clearConditionalType: String { string("clear.conditional.type") }
    static var clearConditionalRange: String { string("clear.conditional.range") }
    static func clearConditionalConfirm(_ count: Int) -> String { plural("clear.conditional.confirm", count) }
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
    static var settingsHotkeyFooter: String { string("settings.hotkey.footer") }
    static var settingsHistoryFooter: String { string("settings.history.footer") }
    static var settingsExcludedAppsFooter: String { string("settings.excluded.apps.footer") }
    // ID-VIEW-0039 (2026-08-14): drag-and-drop rejection feedback. Deliberately
    // count-free so no plural forms are needed across the 7 languages.
    static var settingsExcludedDropNotApp: String { string("settings.excluded.drop.notApp") }
    static var settingsExcludedDropUnreadable: String { string("settings.excluded.drop.unreadable") }
    static var settingsExcludedDropSelf: String { string("settings.excluded.drop.self") }
    // ID-EXCLUDE-0002 (2026-08-14): opt-in exclusion-list update notice.
    static var settingsExcludedUpdateNotice: String { string("settings.excluded.update.notice") }
    static var settingsExcludedUpdateApply: String { string("settings.excluded.update.apply") }
    static var settingsExcludedUpdateDismiss: String { string("settings.excluded.update.dismiss") }
    static var settingsExcludedAppsEmpty: String { string("settings.excluded.apps.empty") }
    static var settingsBackupFooter: String { string("settings.backup.footer") }
    static var settingsUpdateSourceFooter: String { string("settings.updateSource.footer") }

    /// C2 (v2.7.9): version comparison line shown in the Update tab.
    /// `status` argument is the pre-formatted "up to date" / "update available"
    /// phrase (see `settingsUpdateStatusUpToDate` / `settingsUpdateStatusOutOfDate`).
    /// Format: "Current v%@ · Latest v%@ · %@" (zh-Hans: "当前 v%@ · 最新 v%@ · %@").
    static func settingsUpdateStatusLine(_ current: String, _ latest: String, _ status: String) -> String {
        string("settings.update.statusLine", current, latest, status)
    }
    static var settingsUpdateStatusUpToDate: String { string("settings.update.statusUpToDate") }
    static var settingsUpdateStatusOutOfDate: String { string("settings.update.statusOutOfDate") }

    // MARK: - OCR Search Highlight
    /// Placeholder shown under image thumbnails while OCR backfill is in progress.
    static var itemOcrProcessing: String { string("item.ocrProcessing") }
    /// Placeholder shown when OCR ciphertext is present but decrypt fails (corrupt
    /// blob or key mismatch). Helps user distinguish "no OCR yet" from "broken OCR".
    static var itemOcrUnreadable: String { string("item.ocrUnreadable") }
    /// Settings toggle label — controls whether image search results show OCR
    /// snippet + highlight. Display-only; filter still uses OCR text.
    static var settingsHistoryCaptureOcrPreview: String { string("settings.historyCapture.ocrPreview") }

    static var quitApp: String { string("app.quit") }
    static var launchAtLogin: String { string("app.launch.at.login") }
    static var error: String { string("app.error") }
    static func batchSelected(_ count: Int) -> String { plural("batch.selected", count) }
    static var sendFeedback: String { string("app.send.feedback") }
    static var viewWelcomeGuide: String { string("app.view.welcome.guide") }
    static var alertEncryptFailed: String { string("alert.encrypt.failed") }
    // CLIP-3 (2026-07-24): coalesced variant used when the throttler
    // suppressed repeat failures inside its window — reports the total count.
    // ID-L10N-0016 (2026-07-30 audit): use `plural()` so count=1 picks up
    // the `.one` variant ("1 item was not saved" / "1 件保存されませんでした" / etc.).
    // The previous `string()` only ever used the plural form.
    static func alertEncryptFailedCount(_ count: Int) -> String { plural("alert.encrypt.failed.count", count) }
    // H-1 (2026-08-08 audit): save failure alerts. Reuses the encrypt
    // failure key style (.one variant for count=1) so count + text
    // rendering stay consistent across the two alert paths.
    static var alertSaveFailed: String { string("alert.save.failed") }
    static func alertSaveFailedCount(_ count: Int) -> String { plural("alert.save.failed.count", count) }
    // H-1 (2026-08-08 audit): trash load failure alerts. Distinct text
    // from save/encryption because the underlying cause (corrupt blob)
    // is recoverable via the quarantined .corrupt-* file rather than
    // user action on disk.
    static var alertTrashLoadFailed: String { string("alert.trash.load.failed") }
    static func alertTrashLoadFailedCount(_ count: Int) -> String { plural("alert.trash.load.failed.count", count) }

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

    // MARK: - Update Source Switch (Task 6)
    static var settingsUpdateSourceTitle: String { string("settings.updateSource.title") }
    static var settingsUpdateSourceOptionAutomatic: String { string("settings.updateSource.option.automatic") }
    static var settingsUpdateSourceOptionPrimary: String { string("settings.updateSource.option.primary") }
    static var settingsUpdateSourceOptionFallback: String { string("settings.updateSource.option.fallback") }
    static var settingsUpdateSourceOptionGitee: String { string("settings.updateSource.option.gitee") }
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

    // MARK: - Settings Window (2026-07-25)
    static var settingsWindowTitle: String { string("settings.window.title") }
    static var settingsTabGeneral: String { string("settings.tab.general") }
    static var settingsTabHistory: String { string("settings.tab.history") }
    static var settingsTabBackup: String { string("settings.tab.backup") }
    static var settingsTabUpdate: String { string("settings.tab.update") }

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
    static func quickbarRecent(_ count: Int) -> String { plural("quickbar.recent", count) }
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

    // P0-2: diagnostics banner (see DecryptionDiagnostics)
    static var bannerKeyUnavailable: String { string("banner.key.unavailable") }
    static func bannerDataCorruptedCount(_ n: Int) -> String { plural("banner.data.corrupted.count", n) }

    // MARK: - VoiceOver / Accessibility labels (Round-2 2026-07-30 audit, L10N-0001..0007)
    /// ID-L10N-0002: Clear search button label (ContentView toolbar × icon).
    static var searchClear: String { string("search.clear") }
    /// ID-L10N-0003: QuickBar menu item shortcut hint, e.g. "Quit ClipMemory, shortcut ⌘Q".
    static func quickbarMenuShortcut(_ label: String, _ shortcut: String) -> String {
        string("quickbar.menuShortcut", label, shortcut)
    }
    /// ID-L10N-0003: QuickBar row type-and-preview hint, e.g. "Text clipboard item: foo".
    static func quickbarClipboardItemPrefix(_ typeLabel: String, _ preview: String) -> String {
        string("quickbar.clipboardItemPrefix", typeLabel, preview)
    }
    /// ID-L10N-0004: Welcome step row label template (number, title, description).
    static func welcomeStepAccessibility(_ number: String, _ title: String, _ description: String) -> String {
        string("welcome.stepAccessibility", number, title, description)
    }
    /// ID-L10N-0005: AppPickerRow "Remove exclusion for X" label.
    static func appPickerAccessibilityRemove(_ name: String) -> String {
        string("appPicker.accessibility.remove", name)
    }
    /// ID-L10N-0005: AppPickerRow "Exclude X" label.
    static func appPickerAccessibilityAdd(_ name: String) -> String {
        string("appPicker.accessibility.add", name)
    }
    /// ID-L10N-0006: DateFilterButton selected-state suffix, e.g. ", selected" / "（已选）".
    /// Empty string when not selected — caller decides whether to append.
    static var dateFilterSelected: String { string("dateFilter.selected") }
    /// ID-L10N-0007: Tag chip label template, e.g. "Tag: Work".
    static func tagChipAccessibility(_ name: String) -> String {
        string("tag.chipAccessibility", name)
    }
    /// ID-L10N-0015 (2026-07-30 audit): explicit accessibility label so
    /// VoiceOver reads "添加建议标签 X" (or localized equivalent) instead
    /// of the inline Chinese. Added after v3.0 audit introduced the same
    /// pattern with hardcoded "X 个标签" — both inline strings need to
    /// be L10n-routed for non-zh-Hans locales.
    static func tagPickerAddSuggestion(_ name: String) -> String {
        string("tagPicker.addSuggestion", name)
    }
    /// ID-L10N-0015: plural-aware accessibility label for the tag-count
    /// badge on each row. "3 个标签" / "1 个标签" / etc.
    static func tagBadgeAccessibility(_ count: Int) -> String {
        plural("tag.badge.accessibility", count)
    }

    // MARK: - Restore wizard (ID-BACKUP-0002)
    static var restoreWizardTitle: String { string("restore.wizard.title") }
    static var restoreStepSelectSource: String { string("restore.step.selectSource") }
    static var restoreStepValidate: String { string("restore.step.validate") }
    static var restoreStepPreview: String { string("restore.step.preview") }
    static var restoreStepConfirmApply: String { string("restore.step.confirmApply") }
    static var restoreStepResult: String { string("restore.step.result") }
    static var restoreSourceLocal: String { string("restore.source.local") }
    static var restoreSourceLocalEmpty: String { string("restore.source.local.empty") }
    static var restoreSourceLocalEmptyHint: String { string("restore.source.local.empty.hint") }
    static var restoreSourceLocalIncompleteTooltip: String { string("restore.source.local.incomplete.tooltip") }
    static var restoreSourceExternal: String { string("restore.source.external") }
    static var restoreSourceExternalPick: String { string("restore.source.external.pick") }
    static var restoreSourceExternalPassword: String { string("restore.source.external.password") }
    static var restoreSourceExternalPasswordWrong: String { string("restore.source.external.passwordWrong") }
    static var restorePreviewItems: String { string("restore.preview.items") }
    static var restorePreviewTags: String { string("restore.preview.tags") }
    static var restorePreviewImages: String { string("restore.preview.images") }
    static var restorePreviewCreatedAt: String { string("restore.preview.createdAt") }
    static var restorePreviewAppVersion: String { string("restore.preview.appVersion") }
    static var restorePreviewWarningIncomplete: String { string("restore.preview.warning.incomplete") }
    static var restoreConfirmTitle: String { string("restore.confirm.title") }
    static var restoreConfirmBody: String { string("restore.confirm.body") }
    static var restoreConfirmApply: String { string("restore.confirm.apply") }
    static var restoreProgressSnapshot: String { string("restore.progress.snapshot") }
    static var restoreProgressImport: String { string("restore.progress.import") }
    static var restoreResultTitle: String { string("restore.result.title") }
    static var restoreResultBody: String { string("restore.result.body") }
    static var restoreResultImageFailed: String { string("restore.result.imageFailed") }
    static var restoreResultClose: String { string("restore.result.close") }
    static var restoreErrorCorrupted: String { string("restore.error.corrupted") }
    static var restoreErrorUnsupportedVersion: String { string("restore.error.unsupportedVersion") }
    static var restoreErrorUnsupportedKDF: String { string("restore.error.unsupportedKDF") }
    static var restoreErrorArchiveFailed: String { string("restore.error.archiveFailed") }
    static var restoreErrorKeychain: String { string("restore.error.keychain") }
    static var restoreErrorSnapshotFailed: String { string("restore.error.snapshotFailed") }
    static var restoreErrorDiskFull: String { string("restore.error.diskFull") }
}
