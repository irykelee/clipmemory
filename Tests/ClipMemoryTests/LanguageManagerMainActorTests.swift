import XCTest
@testable import ClipMemory

/// Regression tests for F-1 phase 1 LanguageManager @MainActor annotation.
///
/// Three contracts:
/// 1. Setting `selectedLanguage` on the main actor updates the nonisolated
///    `currentLanguageCode` mirror (consumers in detached Tasks see the new value).
/// 2. The `LanguageDidChange` notification fires AFTER the mirror is updated,
///    so any observer that reads `currentLanguageCode` in response sees the
///    post-change value (not stale).
/// 3. An off-main reader (e.g. `LocalizationService.currentBundle` running
///    inside a `Task.detached` failure handler) can read both the mirror and
///    `L10n.string("button.cancel")` without crashing or returning the key
///    verbatim (which would indicate the bundle fallback failed).
///
/// F-1 phase 1 Task 4. See plan in ~/.claude/plans/cheeky-jingling-firefly.md.
final class LanguageManagerMainActorTests: XCTestCase {

    // MARK: - Test 1: setter updates nonisolated mirror

    /// Setting `selectedLanguage` on the main actor must update
    /// `LanguageManager.currentLanguageCode` so off-main readers see the
    /// new value. This is the contract the `nonisolated(unsafe)` mirror
    /// was added for in commit `153d25d`.
    @MainActor
    func testSelectedLanguageSetterUpdatesNonisolatedMirror() {
        let mgr = LanguageManager.shared
        let original = mgr.selectedLanguage
        defer { mgr.selectedLanguage = original }

        mgr.selectedLanguage = "zh-Hans"
        XCTAssertEqual(LanguageManager.currentLanguageCode, "zh-Hans")

        mgr.selectedLanguage = "ja"
        XCTAssertEqual(LanguageManager.currentLanguageCode, "ja")
    }

    // MARK: - Test 2: notification fires AFTER mirror update

    /// `LanguageDidChange` observers that read `currentLanguageCode` in
    /// their handler must see the new value, not the pre-change one.
    /// This pins the ordering guarantee in `LanguageManager.didSet`
    /// (publish mirror → post notification).
    @MainActor
    func testNotificationFiresAfterMirrorUpdate() {
        let mgr = LanguageManager.shared
        let original = mgr.selectedLanguage
        defer { mgr.selectedLanguage = original }

        var observerSawAtNotificationTime: String?
        let token = NotificationCenter.default.addObserver(
            forName: .languageDidChange,
            object: nil,
            queue: nil
        ) { _ in
            observerSawAtNotificationTime = LanguageManager.currentLanguageCode
        }
        defer { NotificationCenter.default.removeObserver(token) }

        mgr.selectedLanguage = "ko"

        XCTAssertEqual(LanguageManager.currentLanguageCode, "ko")
        XCTAssertEqual(observerSawAtNotificationTime, "ko",
            "Notification observer saw \(observerSawAtNotificationTime ?? "nil"); expected \"ko\" — didSet reordered?")
    }

    // MARK: - Test 3: off-main thread reads mirror + L10n

    /// Off-main readers (e.g. `LocalizationService.currentBundle` running
    /// inside a `Task.detached` `CryptoService.prepareKey` failure handler)
    /// must be able to read both `currentLanguageCode` and `L10n.string(_:)`
    /// without crashing. We use `L10n.string("button.cancel")` (NOT
    /// `"menu.copy"`) because `button.cancel` is verified present in all 7
    /// `Localizable.strings` bundles; `menu.copy` is absent and would
    /// silently return the key verbatim via fallback, giving a false green.
    ///
    /// Not `@MainActor` — the whole point is to exercise the off-main path.
    func testOffMainThreadCanReadCurrentLanguageCodeAndL10n() {
        let expectation = XCTestExpectation(description: "off-main read completes")

        DispatchQueue.global(qos: .userInitiated).async {
            // Nonisolated mirror: safe to read from any thread.
            let lang = LanguageManager.currentLanguageCode
            XCTAssertFalse(lang.isEmpty,
                "currentLanguageCode should be seeded (init commit cd0be7c), not empty")

            // L10n.currentBundle uses NSLock-protected cache + reads the
            // nonisolated mirror, so off-main callers are safe.
            let localized = L10n.string("button.cancel")
            XCTAssertNotEqual(localized, "button.cancel",
                "L10n.string returned the key verbatim — bundle fallback failed (key missing from all 7 bundles?)")
            XCTAssertFalse(localized.isEmpty)

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }
}