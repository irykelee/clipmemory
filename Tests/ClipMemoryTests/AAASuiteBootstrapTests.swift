import XCTest
@testable import ClipMemory

/// M13 (2026-08-03): suite-level before-snapshot.
///
/// Runs first in the suite (alphabetically before every other test class).
/// Snapshots the production UserDefaults persistent domain BEFORE any test
/// executes, so ZZZSuiteTeardownTests can diff against it.
///
/// Snapshot source: `UserDefaults.standard.persistentDomain(forName:)` —
/// contains only the app's own keys, excluding NSGlobalDomain and other
/// system domains that change during normal system operation.
///
/// Filter prefix: `NS` / `Apple` / `com.apple.` — system runtime keys that
/// may appear/disappear between before/after snapshots without meaning a
/// test wrote them.
final class AAASuiteBootstrapTests: XCTestCase {

    /// Snapshot of the production persistent domain before any test ran.
    /// Consumed by ZZZSuiteTeardownTests.
    static var productionPersistentDomainBefore: [String: Any] = [:]

    /// ID-CRASH-0031 (2026-10-20): whether `productionPersistentDomainBefore`
    /// was actually captured.
    ///
    /// The snapshot is empty when this class never ran (e.g. a focused
    /// `-only-testing:` run that skips the suite bootstrap). An empty
    /// dictionary is indistinguishable from "the production domain really
    /// is empty", so the consumers need an explicit flag: the byte-level
    /// data-blob comparison must SKIP (not fail) when there is no baseline
    /// to compare against.
    static var didSnapshotProductionDomain = false

    override static func setUp() {
        super.setUp()
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        Self.productionPersistentDomainBefore =
            UserDefaults.standard.persistentDomain(forName: bundleId) ?? [:]
        Self.didSnapshotProductionDomain = true
        // NEW-2 follow-up (2026-08-06): redirect the
        // `LanguageManager.shared` singleton's underlying UserDefaults
        // to an isolated test suite BEFORE any other test reads
        // `LanguageManager.shared`. AAASuiteBootstrapTests is
        // alphabetically the first test class, so this setUp runs
        // before any code path that might lazy-init the singleton.
        // The redirect keeps every test's `applyLanguage` writes
        // (`AppleLanguages`) and didSet writes (`appLanguage`) out
        // of the production UserDefaults domain.
        //
        // NOTE: there is no `class func tearDown` to restore
        // `.standard`. The test isolation suite is process-scoped
        // (UserDefaults caches the suite instance for the process
        // lifetime), and the test process exits immediately after
        // the suite finishes. Restoring to `.standard` mid-suite
        // would invalidate the cached singleton mid-run and cause
        // subsequent tests to write to the production domain again.
        LanguageManager.defaults = UserDefaults(suiteName: "LanguageManager-test-isolation") ?? .standard

        // ID-STORE-0014 (2026-08-10): per-test cleanup of the
        // `ClipboardStore-XCTest-isolation` UserDefaults suite. Without this,
        // any test that mutates state via `ClipboardStore.xcTestDefaults`
        // (e.g. `store.maxItems = 3` in `IntegrationTests`) leaks the
        // value to subsequent tests within the same process — which were
        // silently relying on `.standard` having user-pollution values like
        // `maxClipboardItems = 3`. Clearing before each test gives every
        // test a fresh isolated suite, so reads default to `nil → 100` (the
        // init fallback) regardless of what earlier tests in the suite
        // happened to write.
        //
        // ID-REVIEW-1034 (2026-10-26): the cleanup observer now lives in
        // `XCTestIsolationSuiteBootstrap` (it also guards against writes into
        // the shared suites). It is still registered HERE, so it still
        // depends on this class running — Swift forbids overriding `+load`.
        //
        // That dependence is what turned a host crash into a failure
        // hundreds of lines away: in CI run 40186263416 the host died inside
        // `DecryptionFailedLoopTests.testPreFailedItemReturnsNilImmediately`,
        // xcodebuild relaunched it and continued with the REMAINING classes,
        // so THIS class never re-ran ⇒ no observer ⇒ the shared suite kept
        // the `maxClipboardItems = 3` that `IntegrationTests` had written
        // ⇒ `QuickBarViewTests` failed with `("3") is not equal to ("8")`.
        //
        // The incident is now prevented structurally rather than by making
        // the observer survive a restart: no test writes into the shared
        // suites any more, and the tests that depend on store settings
        // inject their own suite. The observer is the belt-and-braces layer.
        XCTestIsolationSuiteBootstrap.registerObserver()
    }

    // MARK: Canary discovery marker

    /// XCTest discovers test classes by their `testXxx()` methods; a class
    /// with NO test methods is silently skipped and its class-level hooks
    /// (`setUp`/`tearDown`) never run — the whole canary was structurally
    /// dead until this marker was added (2026-08-03 CI catch: build passed,
    /// zero tests executed). Empty on purpose; ordering relies on XCTest's
    /// class-name alphabetical execution with the scheme's
    /// `parallelizable = NO`.
    func testSuiteBootstrapMarker() {}
}
