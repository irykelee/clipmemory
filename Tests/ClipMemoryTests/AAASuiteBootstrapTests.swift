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

    override class func setUp() {
        super.setUp()
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        Self.productionPersistentDomainBefore =
            UserDefaults.standard.persistentDomain(forName: bundleId) ?? [:]
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
