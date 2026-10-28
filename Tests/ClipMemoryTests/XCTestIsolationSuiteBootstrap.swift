import XCTest

/// ID-REVIEW-1034 (2026-10-26): the per-test cleanup of the shared XCTest
/// isolation suites, plus a guard that makes a write into those suites a
/// **detectable** event instead of a silent one.
///
/// ## Background (CI run 40186263416, 2026-10-25)
///
/// The host crashed inside
/// `DecryptionFailedLoopTests.testPreFailedItemReturnsNilImmediately`
/// ("Restarting after unexpected exit, crash, or test timeout"), and
/// `xcodebuild` relaunched it and continued with the REMAINING test
/// classes. `AAASuiteBootstrapTests` is alphabetically FIRST, so the
/// relaunched host never re-ran it — and the cleanup observer used to be
/// registered in that class's `class func setUp()`. Without the observer
/// the shared `ClipboardStore-XCTest-isolation` suite kept whatever an
/// earlier test had written into it (`maxClipboardItems = 3`, written by
/// `IntegrationTests.testTrimToMaxItemsRemovesOldest`), and
/// `QuickBarViewTests` — hundreds of lines later — inherited the stale cap
/// and failed with `("3") is not equal to ("8")`.
///
/// The observer therefore still depends on `AAASuiteBootstrapTests` running
/// (Swift forbids overriding `+load`, and Objective-C would mean a
/// Swift-runtime-order hazard). The incident is prevented structurally
/// instead: no test writes into the shared suite any more
/// (`IntegrationTests` + `TestHostIsolationTests` inject their own suite),
/// and the tests that depend on store settings inject their own suite too
/// (`QuickBarViewTests`). This observer is the belt-and-braces layer, and
/// the write guard below turns "somebody wrote into the shared suite" from
/// an invisible state change into a named, failing canary.
final class XCTestIsolationSuiteBootstrap: NSObject {

    /// The suite whose setting leaked in CI run 40186263416.
    static let clipboardStoreSuiteName = "ClipboardStore-XCTest-isolation"

    /// Suites that every no-arg service under XCTest resolves to. They are
    /// cleared before every test case so one test's mutation cannot leak
    /// into the next.
    ///
    /// Kept in sync with the `xcTestDefaults` seams in
    /// `ClipboardStore` / `HotKeyManager` / `BackupService` /
    /// `SafeModeService` / `TestIsolation`.
    ///
    /// The ClipboardStore suite is referenced through
    /// `clipboardStoreSuiteName` (single source of truth): if the two ever
    /// diverge, the write guard would silently watch the WRONG suite and the
    /// ZZZ canary would pass vacuously.
    ///
    /// ID-REVIEW-1037 (2026-10-26): this list was **3 of 5** — the
    /// `TestIsolation-XCTest-isolation` (the canonical seam's baseline) and
    /// `SafeModeService-XCTest-isolation` suites were never cleared, and
    /// **measured** leftovers proved it: after a full local run the baseline
    /// suite still carried `appLanguage` + `AppleLanguages` (written by
    /// `LanguageManager.init` → `applyLanguage`) and the SafeMode suite
    /// still carried `safeMode.active = true` + `safeMode.crashCount = 5`.
    /// Both are cross-test state that a later test can read.
    static let sharedSuiteNames = [
        clipboardStoreSuiteName,
        "HotKeyManager-XCTest-isolation",
        "BackupService-XCTest-isolation",
        testIsolationSuiteName,
        safeModeServiceSuiteName,
        // ID-REVIEW-1048 (2026-10-28): `StartupHealth`'s own suite. It is
        // cleared before every test case like the others (its
        // `lastLaunchTime` must not leak into a later test).
        //
        // ⚠️ It is deliberately **NOT** in `guardedSharedSuiteKeys`: the write
        // guard exists to catch a test that publishes a setting **for other
        // tests to read**, and StartupHealth writing `lastLaunchTime` into
        // **its own** suite is that service's legitimate behaviour, not a
        // stray write.
        startupHealthSuiteName
    ]

    /// The suite `StartupHealth.defaultsFor(isTestProcess:)` resolves to under
    /// XCTest.
    static let startupHealthSuiteName = "StartupHealth-XCTest-isolation"

    /// The canonical seam's baseline suite (`TestIsolation.baselineDefaults`).
    ///
    /// ⚠️ Clearing this suite's CONTENT is safe: `SeamBaselineIsolationTests`
    /// asserts the baseline's *identity* (`addressesProductionDomain`), not
    /// its contents. The suite object itself is untouched — only its
    /// persistent domain is removed, so `TestIsolation.defaults` keeps
    /// pointing at the same instance.
    static let testIsolationSuiteName = "TestIsolation-XCTest-isolation"

    /// The suite `SafeModeService.xcTestDefaults` resolves to under XCTest.
    static let safeModeServiceSuiteName = "SafeModeService-XCTest-isolation"

    /// The setting whose leakage caused it. A test that leaves it in the
    /// shared suite changes the behaviour of every later test that reads
    /// store settings from that suite.
    static let guardedSharedSuiteKey = "maxClipboardItems"

    /// The settings the write guard watches, per shared suite.
    ///
    /// ID-REVIEW-1035 (2026-10-26): the guard used to watch ONE key in ONE
    /// suite, so every other write was invisible. The independent review
    /// found `HotKeyManagerTests` publishing `HotKeyKeyCode` /
    /// `HotKeyModifiers` into the shared `HotKeyManager-XCTest-isolation`
    /// suite — a `maxClipboardItems`-only guard could not see it.
    ///
    /// ⚠ A KEY LIST is required; "any residual key" does not work. On a
    /// suite-based `UserDefaults`, `dictionaryRepresentation()` returns the
    /// WHOLE global defaults dictionary (NSGlobalDomain keys such as
    /// `AppleLanguages`, `com.apple.finder.*`, …), not the suite's own keys.
    /// Measured 2026-10-26: a brand-new suite already reported ~90 such
    /// system keys, so a generic guard would fire on EVERY test. Probing each
    /// key with `object(forKey:)` is what actually works.
    ///
    /// ID-REVIEW-1037 (2026-10-26): widened from 2 suites / 4 keys to
    /// **all 5 shared suites** and their **full production write surface**.
    /// The previous table was derived from the ONE incident (`maxClipboardItems`)
    /// plus the ONE review finding (the HotKey keys) — it was not derived
    /// from what the code actually writes, so most of the surface was
    /// invisible. The lists below mirror the `defaults.set(...)` /
    /// `defaults.removeObject(...)` call sites of the owning service:
    ///
    /// | suite | owner | keys |
    /// |---|---|---|
    /// | `ClipboardStore-XCTest-isolation` | `ClipboardStore` | `maxClipboardItems`, `sensitiveClearHours`, `captureRichText`, `excludedBundleIds`, `excludedUpdateDismissedIds`, `ClipboardItems.loadFailed`, `ClipboardTrashedItems.loadFailed`, `ClipboardTrashedItems.retentionDays` |
    /// | `HotKeyManager-XCTest-isolation` | `HotKeyManager` | `HotKeyKeyCode`, `HotKeyModifiers` |
    /// | `BackupService-XCTest-isolation` | `BackupService` | `backupEnabled`, `backupKeepCount`, `lastBackupDate`, `lastBackupErrorDate`, `lastBackupErrorMessage`, `lastPruneErrorDate`, `lastPruneErrorMessage`, `lastQuarantineErrorDate`, `lastQuarantineErrorMessage` |
    /// | `TestIsolation-XCTest-isolation` | `TestIsolation` (canonical seam) | `UpdateFallbackFeedConsent`, `UpdateFeedPolicy`, `LastPrimaryAppcastItemDate` (via `UpdateService`), `appLanguage`, `AppleLanguages` (via `LanguageManager`) |
    /// | `SafeModeService-XCTest-isolation` | `SafeModeService` | `safeMode.crashCount`, `safeMode.active`, `safeMode.sentinelHealthy` |
    ///
    /// The store's BLOB keys (`ClipboardItems` / `ClipMemoryTags` /
    /// `ClipboardTrashedItems`) are deliberately NOT listed: under XCTest the
    /// convenience-init store is **memory-backed** (ID-STORE-0005), so the
    /// blobs never reach the suite — only the settings above do.
    ///
    /// `ImageIntegrity.scannedMtimes` is deliberately NOT watched either,
    /// even though the store persists it into this suite: it is written by an
    /// **asynchronous** background scan (`runImageIntegrityScan` →
    /// `persistIntegrityMtimes`, dispatched to a utility queue), so a write
    /// can land in whatever test happens to be running at that moment.
    /// Measured 2026-10-26: the guard named two tests that never created an
    /// image item — innocent bystanders — while the scan that caused the
    /// write belonged to an earlier test. Attribution is meaningless for an
    /// async writer, and a guard that blames bystanders is worse than no
    /// guard. The harm a stale mtime cache could do (masking an
    /// image-integrity check) is already neutralized by the per-test cleanup,
    /// which wipes this suite before every test.
    static let guardedSharedSuiteKeys: [String: [String]] = [
        clipboardStoreSuiteName: [
            "maxClipboardItems",
            "sensitiveClearHours",
            "captureRichText",
            "excludedBundleIds",
            "excludedUpdateDismissedIds",
            "ClipboardItems.loadFailed",
            "ClipboardTrashedItems.loadFailed",
            "ClipboardTrashedItems.retentionDays"
        ],
        "HotKeyManager-XCTest-isolation": ["HotKeyKeyCode", "HotKeyModifiers"],
        "BackupService-XCTest-isolation": [
            "backupEnabled",
            "backupKeepCount",
            "lastBackupDate",
            "lastBackupErrorDate",
            "lastBackupErrorMessage",
            "lastPruneErrorDate",
            "lastPruneErrorMessage",
            "lastQuarantineErrorDate",
            "lastQuarantineErrorMessage"
        ],
        testIsolationSuiteName: [
            "UpdateFallbackFeedConsent",
            "UpdateFeedPolicy",
            "LastPrimaryAppcastItemDate",
            "appLanguage",
            "AppleLanguages"
        ],
        safeModeServiceSuiteName: [
            "safeMode.crashCount",
            "safeMode.active",
            "safeMode.sentinelHealthy",
            // ID-REVIEW-1046 (2026-10-28): the one-shot migration marker is
            // a FOURTH `defaults.set` site of this service ⇒ the roster
            // that claims to mirror the service's call sites must list it
            // too (otherwise it is already drifting).
            "safeMode.polarityFixedV1"
        ]
    ]

    /// Tests that left `guardedSharedSuiteKey` behind in the shared suite.
    ///
    /// Process-local on purpose: a violation is only meaningful for the run
    /// that produced it, and persisting it would poison the next run.
    private static var recordedViolations: [String] = []

    /// The violations recorded so far in this process.
    static var sharedSuiteViolations: [String] { recordedViolations }

    /// Registers the cleanup observer. Idempotent per process.
    static func registerObserver() {
        guard observer == nil else { return }
        let observer = CleanupObserver()
        XCTestObservationCenter.shared.addTestObserver(observer)
        self.observer = observer
    }

    /// The observer instance — the observation center retains it, but the
    /// strong reference here also keeps `registerObserver()` idempotent.
    private static var observer: CleanupObserver?

    /// The cleanup itself: drop every shared isolation suite.
    static func clearSharedSuites() {
        for suiteName in sharedSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    /// The keys the given suite **owns** — its own persistent domain, and
    /// nothing else.
    ///
    /// ID-REVIEW-1037 (2026-10-26): the guard used to probe with
    /// `object(forKey:)`, which is **not** the same thing. A suite's lookup
    /// falls through to the GLOBAL domain, so `object(forKey:)` answers with
    /// the machine's global value for any system key — whether or not the
    /// suite ever owned it. Measured: a brand-new, empty suite already
    /// answers `object(forKey: "AppleLanguages")` with the machine's global
    /// chain (`zh-Hans-CN`), and `AppleLocale` likewise.
    ///
    /// The consequence was a guard that fires on **every** test as soon as a
    /// globally-known key enters the watch list (measured: 1260 false
    /// offenders for `AppleLanguages` alone).
    ///
    /// `persistentDomain(forName:)` is the correct probe: a fresh suite
    /// answers `[:]`, and global keys are absent from it.
    static func suiteOwnedKeys(in suiteName: String) -> [String: Any] {
        guard let suite = UserDefaults(suiteName: suiteName) else { return [:] }
        return suite.persistentDomain(forName: suiteName) ?? [:]
    }

    /// Records a violation if a watched shared suite still carries a watched
    /// key — i.e. the test that just ran published a setting for every later
    /// test to read.
    ///
    /// ID-REVIEW-1035 (2026-10-26): widened from "one key in one suite" to
    /// the `guardedSharedSuiteKeys` table, after the independent review found
    /// a write into the HotKey suite that the old guard could not see.
    static func recordSharedSuiteViolationIfPresent(testCase: String) {
        for (suiteName, keys) in guardedSharedSuiteKeys {
            let owned = suiteOwnedKeys(in: suiteName)
            let residual = keys.filter { owned[$0] != nil }
            guard !residual.isEmpty else { continue }
            let entry = "\(testCase) left \(residual.joined(separator: ",")) in \(suiteName)"
            guard !recordedViolations.contains(entry) else { continue }
            recordedViolations.append(entry)
        }
    }

    /// Drops the violations recorded for one test case. Used by the test
    /// that exercises the detection itself — it must not leave its own
    /// synthetic violation behind for the ZZZ canary to trip over.
    static func forgetViolations(forTestCase testCase: String) {
        recordedViolations.removeAll { $0.hasPrefix("\(testCase) ") }
    }

    /// Clears the shared suites before every test case, and watches for
    /// writes into them afterwards.
    private final class CleanupObserver: NSObject, XCTestObservation {
        func testCaseWillStart(_ testCase: XCTestCase) {
            XCTestIsolationSuiteBootstrap.clearSharedSuites()
        }

        func testCaseDidFinish(_ testCase: XCTestCase) {
            XCTestIsolationSuiteBootstrap.recordSharedSuiteViolationIfPresent(
                testCase: "\(type(of: testCase)).\(testCase.name)"
            )
        }
    }
}
