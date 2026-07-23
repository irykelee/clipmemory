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
}
