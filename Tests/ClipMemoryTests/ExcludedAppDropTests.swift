import XCTest
@testable import ClipMemory

/// ID-VIEW-0039 (2026-08-14): dragging a .app onto the excluded-apps section.
///
/// The classifier is exercised through its `resolveBundleId` seam so these
/// tests don't depend on which apps happen to be installed on the machine.
final class ExcludedAppDropTests: XCTestCase {

    private typealias View = HistoryCaptureSettingsView

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    /// Stub resolver: any path whose last component is in `known` reports a
    /// bundle id; every other .app is treated as unreadable.
    private func resolver(_ known: [String: String]) -> (URL) -> String? {
        { known[$0.lastPathComponent] }
    }

    func testAcceptsApplications() {
        let result = View.classifyDroppedURLs(
            [url("/Applications/Bitwarden.app"), url("/Applications/KeeWeb.app")],
            selfBundleId: "com.clipmemory.app",
            resolveBundleId: resolver([
                "Bitwarden.app": "com.bitwarden.desktop",
                "KeeWeb.app": "net.antelle.keeweb"
            ])
        )
        XCTAssertEqual(result.bundleIds, ["com.bitwarden.desktop", "net.antelle.keeweb"])
        XCTAssertEqual(result.notAppCount, 0)
        XCTAssertFalse(result.containsSelf)
    }

    func testRejectsNonApplications() {
        // A folder and a document are both fileURLs, which is exactly why the
        // rejection has to happen after the drop rather than during the drag.
        let result = View.classifyDroppedURLs(
            [url("/Users/someone/Documents"), url("/Users/someone/notes.txt")],
            selfBundleId: "com.clipmemory.app",
            resolveBundleId: resolver([:])
        )
        XCTAssertTrue(result.bundleIds.isEmpty)
        XCTAssertEqual(result.notAppCount, 2)
        XCTAssertEqual(result.unreadableCount, 0)
    }

    func testCountsAppWithUnreadableBundleId() {
        let result = View.classifyDroppedURLs(
            [url("/Applications/Broken.app")],
            selfBundleId: "com.clipmemory.app",
            resolveBundleId: resolver([:])
        )
        XCTAssertTrue(result.bundleIds.isEmpty)
        XCTAssertEqual(result.unreadableCount, 1)
    }

    func testRejectsClipMemoryItself() {
        let result = View.classifyDroppedURLs(
            [url("/Applications/ClipMemory.app")],
            selfBundleId: "com.clipmemory.app",
            resolveBundleId: resolver(["ClipMemory.app": "com.ClipMemory.App"])
        )
        XCTAssertTrue(result.bundleIds.isEmpty)
        XCTAssertTrue(result.containsSelf, "self-check must be case-insensitive")
    }

    func testMixedDropKeepsValidAppsAndReportsTheRest() {
        // Partial success is the interesting case: the good apps must still
        // land even though the batch also carried junk.
        let result = View.classifyDroppedURLs(
            [url("/Applications/Bitwarden.app"), url("/Users/someone/Documents"), url("/Applications/ClipMemory.app")],
            selfBundleId: "com.clipmemory.app",
            resolveBundleId: resolver([
                "Bitwarden.app": "com.bitwarden.desktop",
                "ClipMemory.app": "com.clipmemory.app"
            ])
        )
        XCTAssertEqual(result.bundleIds, ["com.bitwarden.desktop"])
        XCTAssertEqual(result.notAppCount, 1)
        XCTAssertTrue(result.containsSelf)
    }

    // MARK: - Merge

    func testMergeAppendsNewIdsPreservingOrder() {
        let merged = View.mergeExcludedIds(existing: "com.a.one,com.b.two", adding: ["com.c.three"])
        XCTAssertEqual(merged, "com.a.one,com.b.two,com.c.three")
    }

    func testMergeReturnsNilWhenEverythingAlreadyExcluded() {
        // No write means no didSet, so dropping a duplicate doesn't churn
        // UserDefaults or re-notify the monitor.
        let merged = View.mergeExcludedIds(existing: "com.a.one", adding: ["com.a.one"])
        XCTAssertNil(merged)
    }

    func testMergeDeduplicatesCaseInsensitively() {
        let merged = View.mergeExcludedIds(existing: "com.LastPass.LastPass", adding: ["com.lastpass.lastpass"])
        XCTAssertNil(merged)
    }

    func testMergeHandlesEmptyExistingList() {
        let merged = View.mergeExcludedIds(existing: "", adding: ["com.a.one"])
        XCTAssertEqual(merged, "com.a.one")
    }
}
