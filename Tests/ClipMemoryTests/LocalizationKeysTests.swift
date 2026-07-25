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
}
