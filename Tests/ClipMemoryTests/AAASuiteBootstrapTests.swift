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
    }
}
