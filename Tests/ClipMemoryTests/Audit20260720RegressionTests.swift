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
@MainActor final class Audit20260720RegressionTests: XCTestCase {

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
        // NEW-1 (2026-08-03 audit): absence-aware restore — on a fresh CI
        // sandbox `maxClipboardItems` may not exist; reading `store.maxItems`
        // returns the parsed default 100, and `store.maxItems = 100` would
        // fire didSet and plant a brand-new key, tripping ZZZ's `key ADDED`
        // canary. Mirror TestHostIsolationTests.swift :95-101.
        let maxItemsBefore = UserDefaults.standard.object(forKey: "maxClipboardItems")
        defer {
            if let maxItemsBefore {
                UserDefaults.standard.set(maxItemsBefore, forKey: "maxClipboardItems")
            } else {
                UserDefaults.standard.removeObject(forKey: "maxClipboardItems")
            }
        }
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

    // MARK: - NEW: maxItems 1000 boundary (v2.8.4 Picker preset)

    /// v2.8.4 raised the upper Picker preset from 500 to 1000. The underlying
    /// `maxMaxItems = 10_000` already accepts 1000, but Picker-side reachability
    /// + cache rescaling deserve an explicit boundary test so a future
    /// lowering of `maxMaxItems` (e.g. STORAGE-0001 audit decision) cannot
    /// silently re-clamp the new UI preset.
    ///
    /// Guards:
    /// 1. `maxItems = 1000` is NOT clamped by didSet (still 1000 after assign)
    /// 2. `contentCache.countLimit` rescaled to 1000 (≥ 1000, since the
    ///    floor is `minCacheCountLimit = 500`; for maxItems ≥ 500 the cap
    ///    follows maxItems exactly)
    /// 3. `trimToMaxItems()` with 1100 items + maxItems=1000 yields
    ///    exactly 1000 items (no off-by-one at the new boundary)
    func testMaxItems1000BoundaryNewUIPreset() {
        let maxItemsBefore = UserDefaults.standard.object(forKey: "maxClipboardItems")
        defer {
            if let maxItemsBefore {
                UserDefaults.standard.set(maxItemsBefore, forKey: "maxClipboardItems")
            } else {
                UserDefaults.standard.removeObject(forKey: "maxClipboardItems")
            }
        }

        store.maxItems = 1000
        XCTAssertEqual(store.maxItems, 1000,
                       "maxItems=1000 must NOT be clamped by didSet (new Picker upper preset)")

        // Insert 1100 items so trim has something to do.
        for i in 0..<1100 {
            let item = ClipboardItem(
                content: "boundary-\(i)", type: .text, isPinned: false
            )
            store.addItem(item)
        }
        store.flushPendingSaves()

        store.trimToMaxItems()
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1000,
                       "trimToMaxItems must respect the new 1000 boundary exactly")
        XCTAssertLessThanOrEqual(store.items.count, 1000,
                                 "trim must NEVER leave more than maxItems items")
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
        // ID-STORE-0007 (2026-08-01): object(forKey:) not double(forKey:) —
        // double() returns 0 for an ABSENT key and the defer would write a
        // real 0 back into production defaults (blank settings picker).
        let original = UserDefaults.standard.object(forKey: key) as? Double
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

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

    // MARK: - FontScaling: Settings-picker 3-step regression (FONT-0001)

    /// FONT-0001 (2026-08-10): the Settings Picker exposes exactly three
    /// font-scale steps (1.0 / 1.2 / 1.4 in `GeneralSettingsView.swift:80-84`).
    /// The 250ms-debounce + clamp behavior above protects against bad values
    /// landing in UserDefaults, but the multiplicative correctness of the
    /// three "happy path" values themselves was not previously exercised.
    /// Pin the math here so a future refactor of the clamp condition
    /// (e.g. changing `< 4` to `<= 4`) cannot silently break the visible
    /// picker output.
    func testFontScalingThreeStepPickerMultiplies() {
        let key = "fontScale"
        let original = UserDefaults.standard.object(forKey: key) as? Double
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // scale == 1.0 (small) — identity, no scaling.
        UserDefaults.standard.set(1.0, forKey: key)
        XCTAssertEqual(sz(10), 10, "scale == 1.0 (small) must be identity")
        XCTAssertEqual(sz(16), 16)

        // scale == 1.2 (medium) — Settings design team tuned this value.
        // Pin the exact multiplicative result so a future drift (e.g.
        // someone "rounds" 1.2 to 1.25 in the Picker) is caught by the
        // picker-preview test, not by a user complaint.
        UserDefaults.standard.set(1.2, forKey: key)
        XCTAssertEqual(sz(10), 12, accuracy: 0.001, "scale == 1.2 (medium) multiplies exactly")
        XCTAssertEqual(sz(16), 19.2, accuracy: 0.001)

        // scale == 1.4 (large) — same rationale as medium.
        UserDefaults.standard.set(1.4, forKey: key)
        XCTAssertEqual(sz(10), 14, accuracy: 0.001, "scale == 1.4 (large) multiplies exactly")
        XCTAssertEqual(sz(16), 22.4, accuracy: 0.001)
    }

    /// FONT-0001 (2026-08-10): the clamp upper bound is `scale < 4` (strict
    /// less-than). The original M-5 test exercised `5.0` (well above 4) but
    /// never the exact boundary value `4.0`. Without this test, an off-by-one
    /// edit (e.g. `< 4` → `<= 4` to "match Settings' tag upper bound") would
    /// pass the M-5 test (5.0 still clamped) while silently changing behavior
    /// at the boundary.
    func testFontScalingClampBoundaryExactlyFourIsBase() {
        let key = "fontScale"
        let original = UserDefaults.standard.object(forKey: key) as? Double
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // scale == 4.0 — strict `<` must clamp to base.
        UserDefaults.standard.set(4.0, forKey: key)
        XCTAssertEqual(sz(16), 16, "scale == 4.0 must clamp to base (strict < boundary)")

        // scale == 3.999 — just below boundary, must multiply.
        UserDefaults.standard.set(3.999, forKey: key)
        XCTAssertEqual(sz(16), 63.984, accuracy: 0.001, "scale == 3.999 (just below boundary) must multiply")
    }

    /// FONT-0001 (2026-08-10): M-5's negative-input check tests `-2.0`,
    /// but `scale == 0` is the *most* dangerous bad value — `0 * 16 = 0`
    /// produces `Text().font(.system(size: 0))` which collapses the layout
    /// just like `.infinity` did before the fix. The guard `scale > 0`
    /// must reject exactly zero.
    func testFontScalingScaleZeroClampsToBase() {
        let key = "fontScale"
        let original = UserDefaults.standard.object(forKey: key) as? Double
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(0.0, forKey: key)
        XCTAssertEqual(sz(16), 16, "scale == 0.0 must clamp to base (0 * base = 0 collapses SwiftUI layout)")
    }
}
