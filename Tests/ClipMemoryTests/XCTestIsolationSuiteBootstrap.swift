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
    /// `ClipboardStore` / `HotKeyManager` / `BackupService`.
    ///
    /// The ClipboardStore suite is referenced through
    /// `clipboardStoreSuiteName` (single source of truth): if the two ever
    /// diverge, the write guard would silently watch the WRONG suite and the
    /// ZZZ canary would pass vacuously.
    static let sharedSuiteNames = [
        clipboardStoreSuiteName,
        "HotKeyManager-XCTest-isolation",
        "BackupService-XCTest-isolation"
    ]

    /// The setting whose leakage caused it. A test that leaves it in the
    /// shared suite changes the behaviour of every later test that reads
    /// store settings from that suite.
    static let guardedSharedSuiteKey = "maxClipboardItems"

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

    /// Records a violation if the shared suite still carries
    /// `guardedSharedSuiteKey` — i.e. the test that just ran left a setting
    /// behind for every later test to read.
    static func recordSharedSuiteViolationIfPresent(testCase: String) {
        let suite = UserDefaults(suiteName: clipboardStoreSuiteName)
        guard suite?.object(forKey: guardedSharedSuiteKey) != nil else { return }
        let entry = "\(testCase) left \(guardedSharedSuiteKey) in \(clipboardStoreSuiteName)"
        guard !recordedViolations.contains(entry) else { return }
        recordedViolations.append(entry)
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
