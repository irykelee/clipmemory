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
/// - The fontScale clamp is pinned against a PER-TEST suite
///   (`makeFontScaleStore()`), never against `UserDefaults.standard`.
///   ID-REVIEW-1038 (2026-10-27): this file used to set the production
///   `fontScale` key and restore it in a `defer` — which broke the rule
///   above, and a `defer` does not survive a host abort (measured: the
///   user's plist was left with `fontScale = 3.7`). The suite-based
///   approach is also deterministic, which the old one was not.
@MainActor final class Audit20260720RegressionTests: XCTestCase {

    // MARK: - Setup / teardown

    private var backend: MemoryStorageBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!
    // PR56-M (v2.8.4 latent bug batch): per-test defaults suite so the
    // `store.maxItems = N` didSet writes stay isolated from any other test
    // (and from `UserDefaults.standard`, which the XCTest host process maps
    // to the production `com.clipmemory.app` plist). Mirrors the pattern
    // in `ClipboardStoreItemForIDTests.setUp/tearDown`.
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = makeTestDefaults()
        backend = MemoryStorageBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(
            backend: backend,
            tagBackend: tagBackend,
            trashBackend: trashBackend,
            defaults: testDefaults
        )
    }

    override func tearDown() {
        store = nil
        backend = nil
        tagBackend = nil
        trashBackend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
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
        // PR56-M (v2.8.4 latent bug batch): the original `UserDefaults.standard`
        // save/restore was defensive dead code — `store.maxItems = N` writes
        // through the injected `defaults` (now `testDefaults`), not `.standard`,
        // so the read of `.standard` always returned nil and the restore was
        // a no-op. Per-test `testDefaults` isolation in setUp/tearDown replaces
        // it (matches `ClipboardStoreItemForIDTests`).
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
        // PR56-M (v2.8.4 latent bug batch): `UserDefaults.standard` save/restore
        // was defensive dead code under XCTest — `store.maxItems = 1000` writes
        // to the injected `testDefaults` suite, not `.standard`. setUp/tearDown
        // now handle isolation uniformly.
        store.maxItems = 1000
        XCTAssertEqual(store.maxItems, 1000,
                       "maxItems=1000 must NOT be clamped by didSet (new Picker upper preset)")

        // PR56-L1 (v2.8.4 latent bug batch): was missing — the maxItems didSet
        // must also rescale the contentCache so decrypted-content caching
        // follows the user's Picker value, not the pre-bump 500 floor.
        // Without this assert, a future regression that broke the cache
        // rescaling would silently cap decrypted-content lookups at 500
        // even with maxItems = 1000 (per ID-PERF-0025 cache-discipline
        // contract from v2.8.3).
        XCTAssertGreaterThanOrEqual(store.contentCache.countLimit, 1000,
                                   "maxItems=1000 didSet must rescale contentCache.countLimit to ≥1000")

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

    /// A per-test store that holds the `fontScale` value the clamp reads.
    ///
    /// ID-REVIEW-1038 (2026-10-26): these tests used to write `fontScale`
    /// into `UserDefaults.standard` and restore it in a `defer`. The test
    /// host runs INSIDE the app process, so `.standard` is the user's real
    /// `com.clipmemory.app` domain — and a `defer` does NOT run when the
    /// host aborts (measured 2026-10-26: `fontScale = 3.7` left behind in
    /// the user's plist). This file's own header already said "never touch
    /// production `UserDefaults` keys"; the code below was breaking that
    /// rule with nothing to catch it.
    private func makeFontScaleStore() -> UserDefaults {
        let name = "Audit20260720-fontScale-\(UUID().uuidString)"
        let suite = TestSuiteCleanup.makeSuite(named: name)
        addTeardownBlock { TestSuiteCleanup.destroy(suite) }
        return suite
    }

    /// Audit M-5: `sz(_:)` only checked `scale > 0`, which passes for
    /// `.infinity` and produces `base * .infinity = .infinity`, then
    /// `Text().font(.system(size: .infinity))` collapses the SwiftUI layout.
    /// The fix clamps with `isFinite && scale > 0 && scale < 4`.
    func testFontScalingClampsBadValuesToBase() {
        let store = makeFontScaleStore()
        let key = UserDefaultsKey.fontScale.rawValue

        store.set(Double.infinity, forKey: key)
        XCTAssertEqual(sz(16, defaults: store), 16, ".infinity must clamp to base (regression of the 2026-07-20 font-scale clamp)")

        store.set(Double.nan, forKey: key)
        XCTAssertEqual(sz(16, defaults: store), 16, "NaN must clamp to base (regression of the 2026-07-20 font-scale clamp)")

        store.set(-2.0, forKey: key)
        XCTAssertEqual(sz(16, defaults: store), 16, "Negative must clamp to base (regression of the 2026-07-20 font-scale clamp)")

        store.set(5.0, forKey: key)
        XCTAssertEqual(sz(16, defaults: store), 16, "scale >= 4 must clamp to base (regression of the 2026-07-20 font-scale clamp)")

        // Valid range: 2x must actually multiply.
        store.set(2.0, forKey: key)
        XCTAssertEqual(sz(16, defaults: store), 32, "scale == 2.0 within bounds must multiply")
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
        let store = makeFontScaleStore()
        let key = UserDefaultsKey.fontScale.rawValue

        // scale == 1.0 (small) — identity, no scaling.
        store.set(1.0, forKey: key)
        XCTAssertEqual(sz(10, defaults: store), 10, "scale == 1.0 (small) must be identity")
        XCTAssertEqual(sz(16, defaults: store), 16)

        // scale == 1.2 (medium) — Settings design team tuned this value.
        // Pin the exact multiplicative result so a future drift (e.g.
        // someone "rounds" 1.2 to 1.25 in the Picker) is caught by the
        // picker-preview test, not by a user complaint.
        store.set(1.2, forKey: key)
        XCTAssertEqual(sz(10, defaults: store), 12, accuracy: 0.001, "scale == 1.2 (medium) multiplies exactly")
        XCTAssertEqual(sz(16, defaults: store), 19.2, accuracy: 0.001)

        // scale == 1.4 (large) — same rationale as medium.
        store.set(1.4, forKey: key)
        XCTAssertEqual(sz(10, defaults: store), 14, accuracy: 0.001, "scale == 1.4 (large) multiplies exactly")
        XCTAssertEqual(sz(16, defaults: store), 22.4, accuracy: 0.001)
    }

    /// FONT-0001 (2026-08-10): the clamp upper bound is `scale < 4` (strict
    /// less-than). The original M-5 test exercised `5.0` (well above 4) but
    /// never the exact boundary value `4.0`. Without this test, an off-by-one
    /// edit (e.g. `< 4` → `<= 4` to "match Settings' tag upper bound") would
    /// pass the M-5 test (5.0 still clamped) while silently changing behavior
    /// at the boundary.
    func testFontScalingClampBoundaryExactlyFourIsBase() {
        let store = makeFontScaleStore()
        let key = UserDefaultsKey.fontScale.rawValue

        // scale == 4.0 — strict `<` must clamp to base.
        store.set(4.0, forKey: key)
        XCTAssertEqual(sz(16, defaults: store), 16, "scale == 4.0 must clamp to base (strict < boundary)")

        // scale == 3.999 — just below boundary, must multiply.
        store.set(3.999, forKey: key)
        XCTAssertEqual(sz(16, defaults: store), 63.984, accuracy: 0.001, "scale == 3.999 (just below boundary) must multiply")
    }

    /// FONT-0001 (2026-08-10): M-5's negative-input check tests `-2.0`,
    /// but `scale == 0` is the *most* dangerous bad value — `0 * 16 = 0`
    /// produces `Text().font(.system(size: 0))` which collapses the layout
    /// just like `.infinity` did before the fix. The guard `scale > 0`
    /// must reject exactly zero.
    func testFontScalingScaleZeroClampsToBase() {
        let store = makeFontScaleStore()

        store.set(0.0, forKey: UserDefaultsKey.fontScale.rawValue)
        XCTAssertEqual(sz(16, defaults: store), 16, "scale == 0.0 must clamp to base (0 * base = 0 collapses SwiftUI layout)")
    }

    /// ID-REVIEW-1038: the clamp tests above no longer touch the
    /// production domain, so the PRODUCTION entry point — `sz(_:)`, which
    /// reads `UserDefaults.standard` — needs its own coverage.
    ///
    /// Three contracts, pinned separately, because one assertion cannot
    /// carry them all:
    ///
    /// 1. **Which KEY** `sz` reads. Deterministic: a value stored under a
    ///    DIFFERENT key must be ignored.
    /// 2. **The key constant itself** — a rename of
    ///    `UserDefaultsKey.fontScale` must not silently change what the
    ///    app reads.
    /// 3. **Which STORE** the production entry reads. Compared against
    ///    the same store read explicitly.
    ///
    /// ⚠️ Contract 3 is the weakest one and is honest about it: on a host
    /// that has NO `fontScale` set (every default install — this machine
    /// included) both sides clamp to base and compare EQUAL whatever
    /// `sz(_:)` does. It catches a regression where the production entry
    /// stops reading `UserDefaults.standard`; it does NOT, on such a
    /// host, catch a regression in WHICH KEY is read — contract 1 above
    /// carries that, deterministically. (The first version of this test
    /// claimed to pin the key; the independent review showed it could
    /// not, and this is the correction.)
    func testProductionEntryPointReadsTheScaleFromTheProductionDomain() {
        // 1. The key `sz` reads.
        let store = makeFontScaleStore()
        store.set(2.0, forKey: "notTheFontScaleKey")
        XCTAssertEqual(
            sz(16, defaults: store), 16,
            "ID-REVIEW-1038: sz must read the fontScale key — a value stored under "
            + "another key must not scale the text"
        )

        // 2. The key constant.
        XCTAssertEqual(
            UserDefaultsKey.fontScale.rawValue, "fontScale",
            "ID-REVIEW-1038: the font-scale key constant must stay `fontScale` — it is "
            + "the key the production domain carries for the user's preference"
        )

        // 3. The store the production entry reads.
        //
        // ID-REVIEW-1039 (2026-10-27): this contract used to compare
        // `sz(_:)` with `sz(_:defaults: UserDefaults.standard)`, which on a
        // host with NO `fontScale` compared "absent" with "absent" — it
        // could not tell the two apart, and the independent review had
        // already flagged it as structurally vacuous.
        //
        // The entry point now resolves against the app's dedicated appearance
        // seam (`AppStorageDefaults.shared`), so the contract becomes
        // DETERMINISTIC: pin a value in that seam and the entry must honour it.
        //
        // Production equivalence is asserted separately by
        // `SeamBaselineIsolationTests.testProductionBranchStillUsesTheStandardDefaults`
        // (`TestIsolation.defaultsFor(isTestProcess: false) === UserDefaults.standard`),
        // which pins the SERVICE seam's production branch.
        let seamStore = makeFontScaleStore()
        seamStore.set(2.0, forKey: "fontScale")
        AppStorageDefaults.setShared(seamStore)
        defer { AppStorageDefaults.setShared(nil) }
        XCTAssertEqual(
            sz(16), 32,
            "ID-REVIEW-1039: sz(_:) must read the font scale from the app's UserDefaults "
            + "seam — the app has to honour the user's font-scale preference"
        )
    }
}
