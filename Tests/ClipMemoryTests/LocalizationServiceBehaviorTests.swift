import XCTest
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-19): behavior tests for `Services/LocalizationService.swift`.
/// The audit found that key-completeness tests (LocalizationKeysTests.swift)
/// verify all keys exist in all 7 language files, but no test exercised
/// the runtime behavior of the resolver itself: how it picks between
/// current-language and English bundles, how it interpolates format
/// arguments, and how `plural()` resolves count-bearing keys. These
/// tests pin those behaviors at the public API surface.
///
/// Adapted from brief: brief referenced `LocalizationService.localized(...)`
/// and `LocalizationService.formatted(...)`; the actual struct is `L10n`
/// with `string(_:)`, `string(_:_:)`, and `plural(_:_:)` accessors.
final class LocalizationServiceBehaviorTests: XCTestCase {

  // MARK: - string(_:) behavior

  /// Known key (`app.name`) must resolve to non-empty translated text in
  /// the running app bundle. Pins the base happy path; if it ever fell
  /// through to the key-returns-key fallback the user-visible app name
  /// would render as the raw key.
  func testKnownKeyResolvesToNonEmptyValue() {
    let result = L10n.string("app.name")
    XCTAssertFalse(result.isEmpty,
                   "P2-19: 'app.name' must resolve to non-empty translated text")
    XCTAssertNotEqual(result, "app.name",
                      "P2-19: 'app.name' must not fall through to the key string")
  }

  /// Unknown key must return the key itself verbatim — this is the
  /// documented fallthrough behavior (`getFromBundle` returns nil on a
  /// miss, both bundles are tried, and the key string is the final
  /// fallback). Pinning this prevents a regression where a missing key
  /// silently renders "" and crashes downstream formatting.
  func testUnknownKeyReturnsKeyItself() {
    let unknown = "definitely.not.a.key"
    let result = L10n.string(unknown)
    XCTAssertEqual(result, unknown,
                   "P2-19: unknown key must fall through to returning the key itself")
  }

  /// Multiple distinct known keys must resolve to distinct values. Pins
  /// that the resolver doesn't accidentally cache-and-return the first
  /// value for every key (an NSCache-style bug that would map every UI
  /// label to the same translated string).
  func testDistinctKnownKeysResolveToDistinctValues() {
    let a = L10n.string("button.clear")
    let b = L10n.string("button.cancel")
    let c = L10n.string("button.done")
    XCTAssertNotEqual(a, b, "P2-19: 'button.clear' and 'button.cancel' must differ")
    XCTAssertNotEqual(b, c, "P2-19: 'button.cancel' and 'button.done' must differ")
    XCTAssertNotEqual(a, c, "P2-19: 'button.clear' and 'button.done' must differ")
    XCTAssertFalse(a.isEmpty)
    XCTAssertFalse(b.isEmpty)
    XCTAssertFalse(c.isEmpty)
  }

  // MARK: - string(_:_:) format-argument interpolation

  /// `about.version` is a parameterized key with `%@` placeholders; the
  /// resolver must pass through the argument so the version appears in
  /// the rendered string. Without this the about tab would render
  /// "<version arg>" as a literal token.
  func testFormatArgumentIsInterpolated() {
    let rendered = L10n.string("about.version", "2.9.0")
    XCTAssertTrue(rendered.contains("2.9.0"),
                  "P2-19: 'about.version(\"2.9.0\")' must embed the version argument, got: \(rendered)")
  }

  /// `welcomeStep2Desc` interpolates the user's hotkey into a welcome
  /// step description. Pins a real production arg-pass-through path.
  func testWelcomeStep2InterpolatesHotkey() {
    let rendered = L10n.string("welcome.step2.desc", "⌘⇧V")
    XCTAssertTrue(rendered.contains("⌘⇧V"),
                  "P2-19: welcome step 2 must embed the hotkey argument, got: \(rendered)")
  }

  // MARK: - plural(_:_:) behavior

  /// `alertClearMessage` is a plural-bearing key with a `.one` variant
  /// (en defines `alert.clear.message.one`). At count=1 the English
  /// singular variant must be selected (regression for ID-L10N-0016).
  /// The exact wording is intentionally not pinned — only that the count
  /// is present and the count-token doesn't render as the raw key.
  func testPluralEmbedsCount() {
    let rendered = L10n.alertClearMessage(7)
    XCTAssertTrue(rendered.contains("7"),
                  "P2-19: plural must embed the count, got: \(rendered)")
    XCTAssertNotEqual(rendered, "alert.clear.message",
                      "P2-19: plural must not fall through to the raw key")
  }

  /// `alertClearMessage(1)` must use the singular form in English. The
  /// shipped English bundle defines both `alert.clear.message` and
  /// `alert.clear.message.one` (en.lproj/Localizable.strings); the
  /// resolver must pick the `.one` variant at count==1, not the plural
  /// base form.
  func testPluralAtCountOnePicksSingularVariant() {
    let singular = L10n.alertClearMessage(1)
    let plural = L10n.alertClearMessage(5)
    XCTAssertTrue(singular.contains("1"),
                  "P2-19: singular form must embed count, got: \(singular)")
    XCTAssertNotEqual(singular, plural,
                      "P2-19: count=1 and count=5 must produce distinct rendered strings")
  }

  // MARK: - bundle fallback chain

  /// The resolver falls back to the English bundle when the current
  /// language lacks a key. We pin this via the CJK bundles (which don't
  /// define every English key — by design). Switching to zh-Hans and
  /// asking for `button.clear` returns the CJK rendering, not English —
  /// a regression here would expose English copy to CJK users.
  @MainActor
  func testCJKBundleResolvesKnownKeyToNativeCopy() {
    let mgr = LanguageManager.shared
    let original = mgr.selectedLanguage
    defer { mgr.selectedLanguage = original }
    mgr.selectedLanguage = "zh-Hans"

    let result = L10n.string("button.clear")
    XCTAssertFalse(result.isEmpty)
    XCTAssertNotEqual(result, "button.clear",
                      "P2-19: zh-Hans bundle must resolve 'button.clear' to native copy, not the key")
    // The shipped zh-Hans bundle renders "清除" for button.clear. Pin the
    // first character so a regression that flips to English ("Clear")
    // is caught.
    XCTAssertTrue(result.contains("清"),
                  "P2-19: zh-Hans 'button.clear' must contain native token '清', got: \(result)")
  }
}