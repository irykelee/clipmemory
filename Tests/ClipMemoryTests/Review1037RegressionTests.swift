import XCTest
@testable import ClipMemory

/// ID-REVIEW-1037 (2026-10-26) — regression guards for the shared XCTest
/// isolation suites.
///
/// ## What this round found
///
/// ID-REVIEW-1034/1035 built the machinery that keeps the process-shared
/// isolation suites clean:
///
/// * a per-test cleanup that wipes them before every test case, and
/// * a write guard that NAMES the test which published a setting into one of
///   them.
///
/// Both were **narrow**: the cleanup covered 3 of the 5 shared suites and the
/// guard watched 4 keys of 2 suites. And the guard's PROBE was wrong, so
/// widening the key list immediately produced noise instead of signal.
///
/// ## The three invariants
///
/// 1. The guard's probe must see only the keys a suite **owns**. A suite's
///    `object(forKey:)` lookup falls through to the GLOBAL domain, so system
///    keys (`AppleLanguages`, `AppleLocale`, …) answer for every suite on the
///    machine — measured 1260 false offenders for `AppleLanguages` alone.
/// 2. The guard must still SEE a suite-owned key in the suites the old table
///    did not cover — otherwise "widening the table" is a claim, not a fact.
/// 3. The per-test cleanup must cover EVERY shared suite — otherwise a
///    leftover survives into the next test.
///
/// Measured leftovers that motivated (3): after a full local run the
/// canonical `TestIsolation-XCTest-isolation` suite still carried
/// `appLanguage` + `AppleLanguages`, and `SafeModeService-XCTest-isolation`
/// still carried `safeMode.active = true` + `safeMode.crashCount = 5`.
@MainActor final class Review1037RegressionTests: XCTestCase {

    // MARK: - 1. The probe must not see global-domain keys

    /// The trap, stated as an executable precondition: a brand-new, empty
    /// suite answers `object(forKey:)` for a key it never owned.
    ///
    /// Which key that is depends on the machine (a global system key, or —
    /// on CI's `-testLanguage zh-Hans` step — the **argument domain**'s
    /// `AppleLanguages`). So the test does not hard-code a key name: it
    /// discovers any key the machine exposes through a suite's search list.
    ///
    /// Skipped only if the machine exposes NO such key at all (a suite whose
    /// search list is empty) — the trap then cannot be reproduced here.
    /// The invariant that actually guards the fix is
    /// `testGuardProbeSeesOnlySuiteOwnedKeys`, which never skips.
    func testSuiteLookupFallsThroughToTheGlobalDomain() throws {
        let suiteName = "Review1037-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Any key the global domain carries will do — the trap is about the
        // search list, not about a particular key name.
        var trapKey: String?
        for key in UserDefaults.standard.dictionaryRepresentation().keys.sorted() {
            guard suite.object(forKey: key) != nil else { continue }
            guard suite.persistentDomain(forName: suiteName)?[key] == nil else { continue }
            trapKey = key
            break
        }

        guard let trapKey else {
            throw XCTSkip("this machine exposes no global key through a suite's search list — "
                          + "the fall-through cannot be shown here")
        }

        XCTAssertNil(
            suite.persistentDomain(forName: suiteName)?[trapKey],
            "precondition: the fresh suite must not OWN \(trapKey)"
        )
        XCTAssertNotNil(
            suite.object(forKey: trapKey),
            "precondition: the LOOKUP must fall through to the global domain — this is the trap"
        )
    }

    /// The guard's probe — the one it actually uses — must ignore the global
    /// domain. If it ever regresses to `object(forKey:)`, the write guard
    /// fires on **every** test (measured: 1260 false offenders) and the ZZZ
    /// canary stops being usable.
    ///
    /// ⚠️ `suiteOwnedKeys` returns `[String: Any]` (never `nil`): the
    /// implementation maps a missing persistent domain to `[:]`, so a `nil`
    /// domain is indistinguishable from an empty one — which is the correct
    /// reading for a leak check ("the suite owns nothing").
    func testGuardProbeSeesOnlySuiteOwnedKeys() {
        let suiteName = "Review1037-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        // A suite-owned key IS visible to the probe …
        suite.set("zh-Hans", forKey: "appLanguage")
        XCTAssertEqual(
            XCTestIsolationSuiteBootstrap.suiteOwnedKeys(in: suiteName)["appLanguage"] as? String,
            "zh-Hans",
            "a suite-owned key must be visible to the guard's probe"
        )

        // … while a globally-known key is not.
        XCTAssertNil(
            XCTestIsolationSuiteBootstrap.suiteOwnedKeys(in: suiteName)["AppleLanguages"],
            "the guard's probe must not report a key the suite never owned"
        )
        XCTAssertNil(
            XCTestIsolationSuiteBootstrap.suiteOwnedKeys(in: suiteName)["AppleLocale"],
            "the guard's probe must not report a key the suite never owned"
        )
    }

    // MARK: - 2. The guard sees suite-owned keys in the newly covered suites

    /// The old table watched 2 suites / 4 keys. Widening it is only meaningful
    /// if the guard actually SEES a suite-owned key in a suite the old table
    /// did not cover — here the SafeMode suite, which the old guard could not
    /// see at all.
    func testGuardDetectsASuiteOwnedKeyInTheSafeModeSuite() {
        let suiteName = XCTestIsolationSuiteBootstrap.safeModeServiceSuiteName
        let shared = UserDefaults(suiteName: suiteName)!
        shared.set(7, forKey: "safeMode.crashCount")
        defer {
            shared.removeObject(forKey: "safeMode.crashCount")
            XCTestIsolationSuiteBootstrap.forgetViolations(forTestCase: "SelfTest")
        }

        XCTestIsolationSuiteBootstrap.recordSharedSuiteViolationIfPresent(testCase: "SelfTest")

        XCTAssertTrue(
            XCTestIsolationSuiteBootstrap.sharedSuiteViolations.contains {
                $0.contains("SelfTest") && $0.contains(suiteName)
            },
            "a suite-owned key in a suite the old table did not cover must be recorded"
        )
    }

    /// The same for the canonical seam's suite — the one that carries the
    /// language keys.
    func testGuardDetectsASuiteOwnedKeyInTheCanonicalSuite() {
        let suiteName = XCTestIsolationSuiteBootstrap.testIsolationSuiteName
        let shared = UserDefaults(suiteName: suiteName)!
        shared.set("ko", forKey: "appLanguage")
        defer {
            shared.removeObject(forKey: "appLanguage")
            XCTestIsolationSuiteBootstrap.forgetViolations(forTestCase: "SelfTest")
        }

        XCTestIsolationSuiteBootstrap.recordSharedSuiteViolationIfPresent(testCase: "SelfTest")

        XCTAssertTrue(
            XCTestIsolationSuiteBootstrap.sharedSuiteViolations.contains {
                $0.contains("SelfTest") && $0.contains(suiteName)
            },
            "a suite-owned key in the canonical suite must be recorded"
        )
    }

    // MARK: - 3. The per-test cleanup covers every shared suite

    /// Every shared suite must be wiped before every test — otherwise one
    /// test's setting survives into the next one. This is the structural
    /// half of the ID-REVIEW-1034 prevention strategy.
    ///
    /// The old list covered 3 suites; the measured leftovers
    /// (`appLanguage` + `AppleLanguages` in the canonical suite,
    /// `safeMode.active` + `safeMode.crashCount` in the SafeMode suite) were
    /// exactly the two it missed.
    func testCleanupCoversEverySharedSuite() {
        // One representative, watched key per shared suite.
        let seeds: [(suite: String, key: String, value: Any)] = [
            (XCTestIsolationSuiteBootstrap.clipboardStoreSuiteName, "maxClipboardItems", 12345),
            ("HotKeyManager-XCTest-isolation", "HotKeyKeyCode", 42),
            ("BackupService-XCTest-isolation", "backupEnabled", true),
            (XCTestIsolationSuiteBootstrap.testIsolationSuiteName, "appLanguage", "ko"),
            (XCTestIsolationSuiteBootstrap.safeModeServiceSuiteName, "safeMode.crashCount", 9)
        ]

        // Every seeded suite must be one the cleanup actually knows about.
        for seed in seeds {
            XCTAssertTrue(
                XCTestIsolationSuiteBootstrap.sharedSuiteNames.contains(seed.suite),
                "the cleanup must cover \(seed.suite)"
            )
        }

        for seed in seeds {
            let suite = UserDefaults(suiteName: seed.suite)!
            suite.set(seed.value, forKey: seed.key)
            XCTAssertNotNil(
                XCTestIsolationSuiteBootstrap.suiteOwnedKeys(in: seed.suite)[seed.key],
                "precondition: \(seed.key) must be owned by \(seed.suite) before the cleanup runs"
            )
        }

        XCTestIsolationSuiteBootstrap.clearSharedSuites()

        for seed in seeds {
            XCTAssertNil(
                XCTestIsolationSuiteBootstrap.suiteOwnedKeys(in: seed.suite)[seed.key],
                "the cleanup must have wiped \(seed.key) from \(seed.suite)"
            )
        }
    }
}
