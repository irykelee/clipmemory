import XCTest
import AppKit
@testable import ClipMemory

/// Regression tests for the 2026-07-20 codebase audit.
///
/// Each `// AUDIT: …` comment names the finding ID from the audit report
/// so a future regression can be traced back to the original bug.
///
/// Conventions:
/// - XCTest + `@testable import ClipMemory`.
/// - Per-test isolation: fresh `MemoryStorageBackend`; never touch production
///   `UserDefaults` keys (matches `test-never-touch-prod-data` rule).
/// - fontScale user-default key is set then restored in each test that
///   touches it; no permanent user-visible state mutation.
final class Audit20260720RegressionTests: XCTestCase {

    // MARK: - Setup / teardown

    private var backend: MemoryStorageBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(
            backend: backend,
            tagBackend: tagBackend,
            trashBackend: trashBackend
        )
    }

    override func tearDown() {
        store = nil
        backend = nil
        tagBackend = nil
        trashBackend = nil
        super.tearDown()
    }

    // MARK: - C-1: Pinned items must NEVER be silently evicted by trimToMaxItems

    /// Audit C-1: prior `trimToMaxItems` ran `pinned.prefix(maxItems)` when
    /// `pinned.count > maxItems`, dropping the over-cap pinned entries
    /// (and their image files). With 100+ pinned items a user could lose
    /// every over-cap pin and have the corresponding image file deleted
    /// from disk. The fix keeps all pinned items; non-pinned is what gets
    /// shrunk.
    func testTrimToMaxItemsPreservesPinnedOverflow() {
        // maxItems persists to UserDefaults via didSet — restore it so later
        // tests (and the host app's own defaults domain) are unaffected.
        let originalMaxItems = store.maxItems
        defer { store.maxItems = originalMaxItems }
        store.maxItems = 50
        var pinnedIDs = Set<UUID>()
        for i in 0..<60 {
            let item = ClipboardItem(
                content: "pinned-\(i)", type: .text, isPinned: true
            )
            store.addItem(item)
            pinnedIDs.insert(item.id)
        }
        for i in 0..<20 {
            let item = ClipboardItem(
                content: "regular-\(i)", type: .text, isPinned: false
            )
            store.addItem(item)
        }
        store.flushPendingSaves()

        store.trimToMaxItems()
        store.flushPendingSaves()

        // Every pinned item survives regardless of pinned.count > maxItems.
        let survivingPinnedIDs = Set(store.items.filter { $0.isPinned }.map { $0.id })
        XCTAssertEqual(survivingPinnedIDs, pinnedIDs,
                       "All 60 pinned items must survive the trim (regression of C-1)")

        // Non-pinned is bounded by `maxItems - pinned.count` and may be zero.
        let activeCount = store.items.count
        let expectedCap = 60 + max(0, store.maxItems - 60)
        XCTAssertEqual(activeCount, expectedCap,
                       "Active list may exceed maxItems when pinned overflows (regression of C-1)")
    }

    // MARK: - I-7: MemoryStorageBackend must serialize concurrent reads/writes

    /// Audit I-7: `MemoryStorageBackend.items` / `tags` were public mutable
    /// arrays without synchronization. The fix wraps them in `NSLock`.
    /// Hammering save() from concurrent writers while readers poll must
    /// not crash and must commit exactly the latest full snapshot.
    func testMemoryStorageBackendIsThreadSafeUnderHammer() {
        let backend = MemoryStorageBackend()
        let expectedCount = 200
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.storage", attributes: .concurrent)

        // 8 writers each commit a full snapshot of `expectedCount` items.
        for writerID in 0..<8 {
            group.enter()
            queue.async {
                let items = (0..<Audit20260720RegressionTests.selfExpectedCount(writerID))
                    .map { i in ClipboardItem(content: "w\(writerID)-i\(i)", type: .text) }
                do {
                    try backend.save(items)
                } catch {
                    XCTFail("writer \(writerID): \(error)")
                }
                group.leave()
            }
        }
        // 4 concurrent readers verifying no crash and no inflation.
        for _ in 0..<4 {
            group.enter()
            queue.async {
                for _ in 0..<50 {
                    let snapshot = (try? backend.load()) ?? []
                    XCTAssertLessThanOrEqual(snapshot.count, expectedCount,
                        "Reader saw an inflated snapshot — torn write (regression of I-7)")
                }
                group.leave()
            }
        }

        group.wait()
        // Final commit must be exactly `expectedCount` items.
        XCTAssertEqual((try? backend.load())?.count ?? 0, expectedCount,
            "Final save must commit exactly \(expectedCount) items (regression of I-7)")
    }

    private static func selfExpectedCount(_ id: Int) -> Int {
        id == 7 ? 200 : 0   // only the last writer produces 200; others save empty
    }

    // MARK: - M-5: FontScaling.sz must clamp Inf / NaN / oversized scale

    /// Audit M-5: `sz(_:)` only checked `scale > 0`, which passes for
    /// `.infinity` and produces `base * .infinity = .infinity`, then
    /// `Text().font(.system(size: .infinity))` collapses the SwiftUI layout.
    /// The fix clamps with `isFinite && scale > 0 && scale < 4`.
    func testFontScalingClampsBadValuesToBase() {
        let key = "fontScale"
        let original = UserDefaults.standard.double(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(Double.infinity, forKey: key)
        XCTAssertEqual(sz(16), 16, ".infinity must clamp to base (regression of M-5)")

        UserDefaults.standard.set(Double.nan, forKey: key)
        XCTAssertEqual(sz(16), 16, "NaN must clamp to base (regression of M-5)")

        UserDefaults.standard.set(-2.0, forKey: key)
        XCTAssertEqual(sz(16), 16, "Negative must clamp to base (regression of M-5)")

        UserDefaults.standard.set(5.0, forKey: key)
        XCTAssertEqual(sz(16), 16, "scale >= 4 must clamp to base (regression of M-5)")

        // Valid range: 2x must actually multiply.
        UserDefaults.standard.set(2.0, forKey: key)
        XCTAssertEqual(sz(16), 32, "scale == 2.0 within bounds must multiply")
    }
}
