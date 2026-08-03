import XCTest
@testable import ClipMemory

/// M13 (2026-08-03): suite-level after-snapshot / diff.
///
/// Runs last in the suite (alphabetically after every other test class).
/// Compares the production UserDefaults persistent domain against the
/// before-snapshot taken by AAASuiteBootstrapTests. Any key added, removed,
/// or changed is a test-pollution failure — that test wrote production
/// UserDefaults and must be fixed.
///
/// Filter prefix: `NS` / `Apple` / `com.apple.` — system runtime keys
/// that may legitimately appear/disappear between launches; not test errors.
final class ZZZSuiteTeardownTests: XCTestCase {

    private let systemKeyPrefixes = ["NS", "Apple", "com.apple."]

    override class func tearDown() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let after = UserDefaults.standard.persistentDomain(forName: bundleId) ?? [:]
        let before = AAASuiteBootstrapTests.productionPersistentDomainBefore

        // Build filtered key sets (strip system keys)
        func stripSystemKeys(_ dict: [String: Any]) -> [String: Any] {
            dict.filter { key, _ in
                !systemKeyPrefixes.contains { key.hasPrefix($0) }
            }
        }

        let filteredBefore = stripSystemKeys(before)
        let filteredAfter = stripSystemKeys(after)
        let allKeys = Set(filteredBefore.keys).union(filteredAfter.keys)

        var failures: [String] = []

        for key in allKeys.sorted() {
            let beforeVal = filteredBefore[key]
            let afterVal = filteredAfter[key]

            if beforeVal == nil && afterVal != nil {
                failures.append("key ADDED: \"\(key)\" = \(String(describing: afterVal))")
            } else if beforeVal != nil && afterVal == nil {
                failures.append("key REMOVED: \"\(key)\" (was \(String(describing: beforeVal)))")
            } else if let bv = beforeVal, let av = afterVal, !(bv as AnyObject).isEqual(av) {
                failures.append("key CHANGED: \"\(key)\" — before: \(String(describing: bv)), after: \(String(describing: av))")
            }
        }

        if !failures.isEmpty {
            XCTFail("ZZZ suite teardown: production UserDefaults pollution detected:\n" +
                    failures.joined(separator: "\n"))
        }

        super.tearDown()
    }
}
