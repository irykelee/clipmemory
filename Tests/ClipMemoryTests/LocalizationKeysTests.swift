import XCTest
@testable import ClipMemory

/// H-2/H-3 (2026-07-23) regression tests.
///
/// Pins the two new backup-UX L10n keys resolve to translated text (not the
/// key string itself) in the running app bundle, and that the entries exist
/// in all 7 shipping language files. Without these pins, a future refactor
/// could drop the LocalizationService accessors or mistype the key and the
/// build would still pass — only the user-visible alert text would silently
/// regress.
///
/// Per `feedback/i18n-assert-via-l10n-not-literal`: assertions use
/// `L10n.string(...)` paths rather than hardcoded English copy, so the test
/// succeeds in any Locale (XCTest default is en but the bundle fallback
/// chain is locale-agnostic).
final class LocalizationKeysTests: XCTestCase {

    func testSettingsBackupPassphraseInfoResolvesToTranslatedText() {
        // If the key is missing from every bundle, L10n.string returns the
        // key string verbatim (see LocalizationService.swift fallthrough).
        // The assertion pins that at least the English fallback produces a
        // real translation.
        XCTAssertNotEqual(
            L10n.settingsBackupPassphraseInfo,
            "settings.backup.passphrase.info",
            "L10n.settingsBackupPassphraseInfo must resolve to translated text, not the key string"
        )
        XCTAssertFalse(
            L10n.settingsBackupPassphraseInfo.isEmpty,
            "L10n.settingsBackupPassphraseInfo must not be empty"
        )
    }

    func testSettingsBackupErrorMissingEncryptionKeyResolvesToTranslatedText() {
        XCTAssertNotEqual(
            L10n.settingsBackupErrorMissingEncryptionKey,
            "settings.backup.error.missingEncryptionKey",
            "L10n.settingsBackupErrorMissingEncryptionKey must resolve to translated text, not the key string"
        )
        XCTAssertFalse(
            L10n.settingsBackupErrorMissingEncryptionKey.isEmpty,
            "L10n.settingsBackupErrorMissingEncryptionKey must not be empty"
        )
        // B-8 (2026-07-27): the message must give the user a real recovery
        // path, not just "reset encryption from Settings" (which is a dead
        // end — there is no in-UI reset). Every locale's copy points the
        // user at the Keychain item name `com.clipmemory.app` (the literal
        // bundle id — untranslated by design). Pin that token so a future
        // copy edit can't silently regress to the unhelpful original "reset
        // encryption from Settings" wording. The locale-specific "Keychain
        // Access" / "钥匙串访问" / "鑰匙圈存取" etc. spelling is intentionally
        // NOT pinned — that's covered by the 7-language file parity test
        // `testNewBackupKeysExistInAllSevenLanguageFiles`.
        XCTAssertTrue(
            L10n.settingsBackupErrorMissingEncryptionKey.contains("com.clipmemory.app"),
            "B-8: missing-encryption-key message must reference the Keychain item 'com.clipmemory.app' so the user can find and delete it, got: \(L10n.settingsBackupErrorMissingEncryptionKey)"
        )
    }

    // N-3 (2026-07-27): the auto-backup error footer key must resolve to
    // translated text and embed the supplied reason. Without the embed
    // check, a future refactor that drops the %@ substitution would only
    // fail at the user's eyes — the test would still pass because
    // L10n.string() falls back to the English bundle.
    func testSettingsBackupErrorLastEmbedsReason() {
        let reason = "Disk full"
        let rendered = L10n.settingsBackupErrorLast(reason)
        XCTAssertNotEqual(
            rendered,
            "settings.backup.error.last",
            "L10n.settingsBackupErrorLast must resolve to translated text, not the key string"
        )
        XCTAssertTrue(
            rendered.contains(reason),
            "L10n.settingsBackupErrorLast must embed the supplied reason, got: \(rendered)"
        )
    }

    /// Walk all 7 shipping language files and confirm both new keys are
    /// physically present. This catches "I forgot to add the entry in es.lproj"
    /// regressions that the resolver tests above cannot — the resolver falls
    /// back to English when a locale is missing, so a missing translation
    /// would silently degrade rather than fail at runtime.
    ///
    /// Path math: #filePath = Tests/ClipMemoryTests/<this file>, so 3 levels
    /// up lands at the XcodeGen project root next to project.yml.
    func testNewBackupKeysExistInAllSevenLanguageFiles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path.path),
                "Missing .strings file for \(lang) at \(path.path)"
            )
            let content = try String(contentsOf: path, encoding: .utf8)
            XCTAssertTrue(
                content.contains("\"settings.backup.passphrase.info\""),
                "\(lang).lproj/Localizable.strings is missing key 'settings.backup.passphrase.info'"
            )
            XCTAssertTrue(
                content.contains("\"settings.backup.error.missingEncryptionKey\""),
                "\(lang).lproj/Localizable.strings is missing key 'settings.backup.error.missingEncryptionKey'"
            )
            // N-3 (2026-07-27): 7-language parity pin for the auto-backup
            // error footer. Without this assertion, a missing translation
            // silently degrades to English rather than failing the build.
            XCTAssertTrue(
                content.contains("\"settings.backup.error.last\""),
                "\(lang).lproj/Localizable.strings is missing key 'settings.backup.error.last'"
            )
        }
    }

    /// UPD-3 (2026-07-24 review): the status panel's switch-reason keys must
    /// exist in all 7 shipping language files — same parity rationale as the
    /// backup keys above (a missing locale silently degrades to English).
    func testUpdateSourceReasonKeysExistInAllSevenLanguageFiles() throws {
        let keys = [
            "settings.updateSource.reason.automaticReachable",
            "settings.updateSource.reason.automaticPrimaryDown",
            "settings.updateSource.reason.bothDownKeepPrimary",
            "settings.updateSource.reason.mirrorStaleRejected",
            "settings.updateSource.reason.userForced",
            "settings.updateSource.reason.userForcedFallback"
        ]
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: path, encoding: .utf8)
            for key in keys {
                XCTAssertTrue(
                    content.contains("\"\(key)\""),
                    "\(lang).lproj/Localizable.strings is missing key '\(key)'"
                )
            }
        }
    }

    /// OCR search highlight keys parity pin. Without this assertion, a missing
    /// translation silently degrades to English rather than failing the build.
    func testOcrSearchHighlightKeysExistInAllSevenLanguageFiles() throws {
        let keys = [
            "item.ocrProcessing",
            "item.ocrUnreadable",
            "settings.historyCapture.ocrPreview"
        ]
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: path, encoding: .utf8)
            for key in keys {
                XCTAssertTrue(
                    content.contains("\"\(key)\""),
                    "\(lang).lproj/Localizable.strings is missing key '\(key)'"
                )
            }
        }
    }

    /// ID-L10N-0001..0007 (2026-07-30 audit): the 8 new VoiceOver /
    /// accessibility labels must exist in all 7 shipping language files.
    /// Without this parity pin, a missing locale silently degrades to English
    /// rather than failing the build — defeating the purpose of the fix
    /// (VoiceOver users in non-English locales still hear English).
    func testRound2L10nAccessibilityKeysExistInAllSevenLanguageFiles() throws {
        let keys = [
            "search.clear",
            "quickbar.menuShortcut",
            "quickbar.clipboardItemPrefix",
            "welcome.stepAccessibility",
            "appPicker.accessibility.remove",
            "appPicker.accessibility.add",
            "dateFilter.selected",
            "tag.chipAccessibility"
        ]
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: path, encoding: .utf8)
            for key in keys {
                XCTAssertTrue(
                    content.contains("\"\(key)\""),
                    "\(lang).lproj/Localizable.strings is missing key '\(key)'"
                )
            }
        }
    }

    /// 2026-07-25 plural-mechanism regression. The retired .stringsdict
    /// (`%#@count@`) path rendered "(null)" for any key missing from the
    /// bundled stringsdict (observed: settings maxItems picker on macOS 26).
    /// Pin the six count-bearing accessors against that failure mode: output
    /// must embed the count and must not contain the raw plural marker or a
    /// "(null)" substitution, for both plural and singular counts.
    func testPluralAccessorsRenderCountWithoutNullOrMarker() {
        let cases: [(String, (Int) -> String)] = [
            ("alertClearMessage", L10n.alertClearMessage),
            ("trashEmptyConfirmMessage", L10n.trashEmptyConfirmMessage),
            ("settingsMaxItemsCount", L10n.settingsMaxItemsCount),
            ("clearConditionalConfirm", L10n.clearConditionalConfirm),
            ("batchSelected", L10n.batchSelected),
            ("quickbarRecent", L10n.quickbarRecent)
        ]
        for (name, accessor) in cases {
            for n in [1, 50] {
                let rendered = accessor(n)
                XCTAssertTrue(
                    rendered.contains("\(n)"),
                    "\(name)(\(n)) must embed the count, got: \(rendered)"
                )
                XCTAssertFalse(
                    rendered.contains("%#@"),
                    "\(name)(\(n)) must not contain the raw plural marker, got: \(rendered)"
                )
                XCTAssertFalse(
                    rendered.contains("(null)"),
                    "\(name)(\(n)) must not contain a (null) substitution, got: \(rendered)"
                )
            }
        }
    }

    /// Parity pin for the plural migration: no shipping .strings file may
    /// reintroduce a `%#@` marker (the retired .stringsdict mechanism), and
    /// the en/es/pt singular variants must exist for the five keys that can
    /// render a count of 1 (settings.max.items.count is always >= 50).
    func testPluralKeysHaveNoMarkersAndSingularVariantsExist() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let pluralKeys = [
            "alert.clear.message",
            "trash.emptyConfirm.message",
            "settings.max.items.count",
            "clear.conditional.confirm",
            "batch.selected",
            "quickbar.recent"
        ]
        let singularKeys = pluralKeys.filter { $0 != "settings.max.items.count" }
        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: path, encoding: .utf8)
            XCTAssertFalse(
                content.contains("%#@"),
                "\(lang).lproj/Localizable.strings must not use the retired %#@ plural marker"
            )
            for key in pluralKeys {
                XCTAssertTrue(
                    content.contains("\"\(key)\""),
                    "\(lang).lproj/Localizable.strings is missing key '\(key)'"
                )
            }
        }
        for lang in ["en", "es", "pt"] {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: path, encoding: .utf8)
            for key in singularKeys {
                XCTAssertTrue(
                    content.contains("\"\(key).one\""),
                    "\(lang).lproj/Localizable.strings is missing singular key '\(key).one'"
                )
            }
        }
    }

    /// ID-L10N-0016 + ID-L10N-0018 (2026-07-31 audit) parity pin.
    ///
    /// 0016: the four (name, count) messages now route through the plural
    /// template, so each needs a ".one" variant in ALL 7 files — a missing
    /// one silently degrades to the plural base form ("1 items").
    /// 0018: the four pre-existing plural keys whose CJK bundles omitted
    /// ".one" must now define it (value == base). Without these, `string()`'s
    /// English-bundle fallback made CJK count==1 render English ("1 item").
    func testCountOneVariantsExistInAllSevenLanguageFiles() throws {
        let keys = [
            // ID-L10N-0016: newly plural-routed (name, count) messages
            "tagPicker.deleteConfirm.message.one",
            "sidebar.deleteTag.confirm.message.one",
            "sidebar.tag.accessibility.label.one",
            "clear.type.confirm.one",
            // ID-L10N-0018: CJK-backfilled ".one" for existing plural keys
            "settings.backup.keep.count.one",
            "settings.trash.retention.days.count.one",
            "quickbar.recent.one",
            "banner.data.corrupted.count.one"
        ]
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: path, encoding: .utf8)
            for key in keys {
                XCTAssertTrue(
                    content.contains("\"\(key)\""),
                    "\(lang).lproj/Localizable.strings is missing key '\(key)'"
                )
            }
        }
    }

    /// ID-L10N-0016 (2026-07-30 audit): the four (name, count) accessors must
    /// select singular grammar at count==1 in English. Before the fix they
    /// called `string()` directly and always rendered the plural base form
    /// ("removed from 1 items").
    @MainActor
    func testNameAndCountAccessorsUseSingularAtCountOne() {
        let mgr = LanguageManager.shared
        let original = mgr.selectedLanguage
        defer { mgr.selectedLanguage = original }
        mgr.selectedLanguage = "en"

        let cases: [(String, String)] = [
            ("tagPicker", L10n.tagPickerDeleteConfirmMessage("Work", 1)),
            ("sidebarDelete", L10n.sidebarDeleteTagConfirmMessage("Work", 1)),
            ("sidebarA11y", L10n.sidebarTagAccessibilityLabel("Work", 1)),
            ("clearType", L10n.clearTypeConfirm("Text", 1))
        ]
        for (name, rendered) in cases {
            XCTAssertTrue(
                rendered.contains("1"),
                "\(name)(count: 1) must embed the count, got: \(rendered)"
            )
            XCTAssertFalse(
                rendered.contains("items"),
                "\(name)(count: 1) must not use the plural 'items', got: \(rendered)"
            )
            XCTAssertTrue(
                rendered.contains("Work") || rendered.contains("Text"),
                "\(name)(count: 1) must embed the name argument, got: \(rendered)"
            )
        }
        // Plural path must be untouched.
        XCTAssertTrue(
            L10n.tagPickerDeleteConfirmMessage("Work", 3).contains("3 items"),
            "plural form must still render at count > 1"
        )
    }

    /// ID-L10N-0018 (2026-07-31 audit): with a CJK in-app language, count==1
    /// must render in that language — never English. Before the fix the CJK
    /// bundles omitted ".one" and `string()`'s English-bundle fallback
    /// resolved "<key>.one" to the English singular ("1 item").
    @MainActor
    func testCJKPluralAtCountOneDoesNotFallBackToEnglish() {
        let mgr = LanguageManager.shared
        let original = mgr.selectedLanguage
        defer { mgr.selectedLanguage = original }

        // (language, accessor render at 1, required native token)
        mgr.selectedLanguage = "zh-Hans"
        XCTAssertEqual(L10n.quickbarRecent(1), "1 条")
        XCTAssertTrue(L10n.bannerDataCorruptedCount(1).contains("损坏"))

        mgr.selectedLanguage = "zh-Hant"
        XCTAssertEqual(L10n.quickbarRecent(1), "1 條")

        mgr.selectedLanguage = "ja"
        XCTAssertEqual(L10n.quickbarRecent(1), "1 件")
        XCTAssertTrue(L10n.settingsBackupKeepCount(1).contains("バックアップ"))

        mgr.selectedLanguage = "ko"
        XCTAssertEqual(L10n.quickbarRecent(1), "1개")
    }

    /// ID-L10N-0020 (2026-08-01 audit): `pluralTemplate` now detects ".one"
    /// presence in the CURRENT bundle only — the old `string()`-based check
    /// fell through englishBundle, so a language pack missing a ".one" key
    /// that en defines would silently render the ENGLISH singular. With
    /// shipping data all 7 packs carry every ".one", so the latent bug's
    /// trigger is exactly a parity gap. Pin it dynamically: every ".one"
    /// key defined in en.lproj must exist in all 7 shipping files.
    func testAllEnglishSingularVariantsExistInAllSevenLanguageFiles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let enPath = appResDir
            .appendingPathComponent("en.lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let enContent = try String(contentsOf: enPath, encoding: .utf8)
        let keyRegex = try NSRegularExpression(
            pattern: #"^"([^"]+\.one)"\s*="#,
            options: .anchorsMatchLines
        )
        let oneKeys = keyRegex
            .matches(in: enContent, range: NSRange(enContent.startIndex..., in: enContent))
            .compactMap { Range($0.range(at: 1), in: enContent).map { String(enContent[$0]) } }
        XCTAssertFalse(oneKeys.isEmpty, "en.lproj must define at least one '.one' singular key")

        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: path, encoding: .utf8)
            for key in oneKeys {
                XCTAssertTrue(
                    content.contains("\"\(key)\""),
                    "\(lang).lproj/Localizable.strings is missing key '\(key)' — ID-L10N-0020: this gap makes count==1 in \(lang) silently render English"
                )
            }
        }
    }

    /// ID-L10N-0020: count==1 for a key that defines NO ".one" variant must
    /// render the BASE key's template in the current language (plural
    /// grammar), never an English singular leak or the raw key. "app.name"
    /// and "button.clear" have no ".one" in any bundle.
    @MainActor
    func testPluralAtCountOneWithoutSingularVariantUsesBaseKey() {
        let mgr = LanguageManager.shared
        let original = mgr.selectedLanguage
        defer { mgr.selectedLanguage = original }

        mgr.selectedLanguage = "en"
        XCTAssertEqual(L10n.plural("app.name", 1), L10n.string("app.name"))
        XCTAssertFalse(L10n.plural("app.name", 1).contains(".one"))

        mgr.selectedLanguage = "zh-Hans"
        XCTAssertEqual(
            L10n.plural("button.clear", 1),
            L10n.string("button.clear"),
            "ID-L10N-0020: missing '.one' must fall back to the base key in the CURRENT language"
        )
    }

    /// 2026-08-04 settings explanatory footer parity pin.
    ///
    /// The five new footer keys must exist in all 7 shipping language files,
    /// and the updated `settings.ocr.hint` (combined OCR + preview semantics)
    /// must remain present so a future drop would fail the build rather than
    /// silently degrade to English.
    ///
    /// 2026-08-05 (v2.7.9 C2): added `settings.update.statusLine`,
    /// `settings.update.statusUpToDate`, `settings.update.statusOutOfDate`
    /// for the "current vs latest version" display in the Update tab.
    func testSettingsFooterKeysExistInAllSevenLanguageFiles() throws {
        let keys = [
            "settings.hotkey.footer",
            "settings.history.footer",
            "settings.excluded.apps.footer",
            "settings.backup.footer",
            "settings.updateSource.footer",
            "settings.ocr.hint",
            "settings.update.statusLine",
            "settings.update.statusUpToDate",
            "settings.update.statusOutOfDate"
        ]
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResDir = projectRoot.appendingPathComponent("ClipMemory", isDirectory: true)

        let languages = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
        for lang in languages {
            let path = appResDir
                .appendingPathComponent("\(lang).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path.path),
                "Missing .strings file for \(lang) at \(path.path)"
            )
            let content = try String(contentsOf: path, encoding: .utf8)
            for key in keys {
                XCTAssertTrue(
                    content.contains("\"\(key)\""),
                    "\(lang).lproj/Localizable.strings is missing key '\(key)'"
                )
            }
        }
    }
}
