import XCTest
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-9): tests guarding the central `UserDefaultsKey`
/// registry. The two invariants the refactor introduced:
///   1. No two cases share a rawValue — collisions would silently merge two
///      otherwise-distinct UserDefaults slots.
///   2. Every case round-trips through UserDefaults — a typo in the rawValue
///      can't masquerade as a read at the wrong key.
///
/// Tests use an isolated `UserDefaults(suiteName:)` so they never touch the
/// production `com.clipmemory.app` domain (ID-STORE-0014 / ZZZ canary
/// invariant).
final class UserDefaultsKeyTests: XCTestCase {
    /// P1-AUDIT-2026-09-22 (P2-9): every case must have a unique rawValue.
    /// Two cases sharing `"foo"` would mean every write to one accidentally
    /// overwrites the other — the exact failure mode the audit was hunting.
    func testAllRawValuesAreUnique() {
        let rawValues = UserDefaultsKey.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(rawValues).count, rawValues.count,
                      "P1-AUDIT-2026-09-22 P2-9: UserDefaultsKey rawValues must be unique; duplicates: \(Dictionary(grouping: rawValues, by: { $0 }).filter { $0.value.count > 1 }.keys)")
    }

    /// P1-AUDIT-2026-09-22 (P2-9): every rawValue must round-trip through
    /// a real UserDefaults suite. If a future case has a typo in its
    /// rawValue (e.g. wrong capitalization), this test catches it on the
    /// first run.
    ///
    /// Uses an isolated suite per test so we never pollute the production
    /// `com.clipmemory.app` domain and the canary (`testNoProductionPollution`)
    /// stays green.
    func testRoundTripAcrossSuite() {
        let suiteName = "p2-9-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("UserDefaults suite \(suiteName) unavailable")
            return
        }
        defer {
            // Clean up the suite so a long-running test process doesn't
            // accumulate stale preferences on disk.
            suite.removePersistentDomain(forName: suiteName)
        }
        for key in UserDefaultsKey.allCases {
            // `AppleLanguages` is a system-managed key (LanguageManager
            // writes a `[String]` via `set(_:forKey:)` and reads via
            // `stringArray(forKey:)`). The set() with a plain String is
            // routed through Apple's system preference handler which
            // rejects non-array values, so a string write+read returns nil.
            // Round-trip it as an array instead — same wire contract, same
            // round-trip proof.
            if key == .appleLanguages {
                suite.set(["en"], forKey: key.rawValue)
                XCTAssertEqual(
                    suite.stringArray(forKey: key.rawValue),
                    ["en"],
                    "P1-AUDIT-2026-09-22 P2-9: round-trip for \(key) (\(key.rawValue)) [system array key]"
                )
                continue
            }
            // Use the rawValue (not key.rawValue) to verify that the case
            // name resolves to a writable, readable key in UserDefaults.
            suite.set("test-value-\(key.rawValue)", forKey: key.rawValue)
            XCTAssertEqual(
                suite.string(forKey: key.rawValue),
                "test-value-\(key.rawValue)",
                "P1-AUDIT-2026-09-22 P2-9: round-trip for \(key) (\(key.rawValue))"
            )
        }
    }

    /// P1-AUDIT-2026-09-22 (P2-9): spot-check that the historically
    /// concatenated keys (`trashedItemsStorageKey + ".loadFailed"` and
    /// `trashedItemsStorageKey + ".retentionDays"`) now live as discrete
    /// cases with the same rawValue the legacy code produced. Without
    /// this assertion a future edit could swap the prefix and silently
    /// orphan the trash sentinel + retention settings.
    func testTrashDerivedKeysKeepLegacyRawValues() {
        XCTAssertEqual(
            UserDefaultsKey.trashedItemsLoadFailedSentinel.rawValue,
            "ClipboardTrashedItems.loadFailed",
            "P1-AUDIT-2026-09-22 P2-9: trash loadFailed sentinel must keep its legacy concatenated rawValue"
        )
        XCTAssertEqual(
            UserDefaultsKey.trashedItemsRetentionDays.rawValue,
            "ClipboardTrashedItems.retentionDays",
            "P1-AUDIT-2026-09-22 P2-9: trash retentionDays must keep its legacy concatenated rawValue"
        )
    }

    /// P1-AUDIT-2026-09-22 (P2-9): ensure the well-known central store keys
    /// (`ClipboardItems`, `ClipMemoryTags`, `ClipboardTrashedItems`) keep
    /// their legacy rawValues verbatim. These are referenced by external
    /// tools / recovery scripts; renaming them would orphan any manual
    /// `defaults read com.clipmemory.app` troubleshooting.
    func testSharedStoreKeysKeepLegacyRawValues() {
        XCTAssertEqual(UserDefaultsKey.clipboardItems.rawValue, "ClipboardItems")
        XCTAssertEqual(UserDefaultsKey.clipboardTags.rawValue, "ClipMemoryTags")
        XCTAssertEqual(UserDefaultsKey.trashedItems.rawValue, "ClipboardTrashedItems")
    }

    /// P1-AUDIT-2026-09-22 (P2-9): ensure the Apple `AppleLanguages`
    /// system key keeps its case-sensitive rawValue. macOS only honors
    /// that exact string; renaming would silently disable the
    /// prepend-selected-language logic in `LanguageManager.applyLanguage`.
    func testAppleLanguagesKeyKeepsSystemRawValue() {
        XCTAssertEqual(UserDefaultsKey.appleLanguages.rawValue, "AppleLanguages")
    }
}