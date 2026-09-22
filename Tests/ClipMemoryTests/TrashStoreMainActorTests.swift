import XCTest
@testable import ClipMemory

/// Regression tests for TrashStore @MainActor isolation (F-1 phase 2, 2026-07-28).
///
/// Pins two contracts added when TrashStore became @MainActor:
/// 1. `handleWillTerminate()` synchronously cancels the debounce timer
///    and flushes any pending save to the backend.
/// 2. `scheduleSave()` debounces via a timer on `saveTimerQueue` and
///    flushes through the main actor isolation chain
///    (.main → MainActor.assumeIsolated → flushSave → backend.save).
@MainActor
final class TrashStoreMainActorTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: TrashStore!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // M13 (2026-08-03): use isolated defaults suite so TrashStore
        // trashRetentionDays didSet writes never touch production.
        testDefaults = makeTestDefaults()
        backend = MemoryStorageBackend()
        store = TrashStore(backend: backend, defaults: testDefaults)
    }

    override func tearDown() {
        store = nil
        backend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    /// Pins the willTerminate contract: timer cancelled + pending save flushed.
    /// Direct call (not via NotificationCenter.post) avoids polluting
    /// NSApplication's global observer chain.
    func testHandleWillTerminateCancelsTimerAndFlushesSave() {
        let item = ClipboardItem(content: "trash me", type: .text)
        store.moveToTrash(item, evictCaches: { _ in }, didMove: {})

        // sanity: needsSave should be true (moveToTrash schedules save)
        // and the debounced save hasn't fired yet (we just called it)
        store.handleWillTerminate()

        // Reload via a fresh TrashStore against the same backend → the
        // pending write must have been flushed synchronously
        let reload = TrashStore(backend: backend, defaults: testDefaults)
        XCTAssertEqual(reload.trashedItems.count, 1)
        XCTAssertEqual(reload.trashedItems.first?.content, "trash me")
    }

    /// Pins the debounced-save contract: scheduleSave() fires once after
    /// 500ms (debounce interval), flushing needsSave → backend.
    ///
    /// Future improvement: inject `debounceInterval` so tests can use a
    /// shorter value and avoid the 500ms wait below.
    func testScheduleSaveDebouncesAndFlushesToBackend() {
        let item = ClipboardItem(content: "debounce me", type: .text)
        store.moveToTrash(item, evictCaches: { _ in }, didMove: {})

        // Wait for 500ms debounce + a small margin; the timer fires on
        // .main → MainActor.assumeIsolated → flushSave → saveTrashedItems
        // → backend.save. If any isolation link is broken, flushSave
        // crashes and the test fails.
        let exp = expectation(description: "debounced flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // Reload from the SAME backend instance to read what was saved
            let reload = TrashStore(backend: self.backend, defaults: self.testDefaults)
            XCTAssertEqual(reload.trashedItems.count, 1)
            XCTAssertEqual(reload.trashedItems.first?.content, "debounce me")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.5)
    }

    /// ID-LIFE-0023 (2026-07-31 Round 5): the debounced flush used to
    /// `cancel()` the reused timer source without nil-ing it — a cancelled
    /// GCD source silently ignores later `schedule()` calls, so after the
    /// FIRST debounced fire every subsequent trash save was lost until
    /// graceful quit. Two consecutive cycles must both reach the backend.
    func testSecondDebounceCycleStillPersists() {
        store.moveToTrash(ClipboardItem(content: "cycle1", type: .text), evictCaches: { _ in }, didMove: {})
        let exp1 = expectation(description: "debounce cycle 1")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.5)

        // Cycle 2 — pre-fix the dead source was reused and never fired.
        store.moveToTrash(ClipboardItem(content: "cycle2", type: .text), evictCaches: { _ in }, didMove: {})
        let exp2 = expectation(description: "debounce cycle 2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let reload = TrashStore(backend: self.backend, defaults: self.testDefaults)
            XCTAssertEqual(reload.trashedItems.count, 2,
                           "ID-LIFE-0023: second debounce cycle must still persist to the backend")
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.5)
    }

    // MARK: - ID-STORE-0003 (2026-07-31 audit): moveToTrash idempotency

    /// ID-STORE-0003: the same id moved twice via the single-item path
    /// (batch + single delete race, restore-then-retrash) must not create
    /// a duplicate trashed entry.
    func testMoveToTrashDuplicateIdIsSkipped() {
        let item = ClipboardItem(content: "once", type: .text)
        store.moveToTrash(item, evictCaches: { _ in }, didMove: {})
        store.moveToTrash(item, evictCaches: { _ in }, didMove: {})
        XCTAssertEqual(store.trashedItems.count, 1,
                       "ID-STORE-0003: duplicate id must be skipped idempotently")
    }

    /// ID-STORE-0003: the batch path skips items already in the bin AND
    /// duplicates within the batch itself.
    func testBatchMoveToTrashSkipsExistingAndDuplicateIds() {
        let a = ClipboardItem(content: "a", type: .text)
        let b = ClipboardItem(content: "b", type: .text)
        store.moveToTrash(a, evictCaches: { _ in }, didMove: {})
        // Batch re-includes `a` (already trashed), plus `b` twice.
        store.moveToTrash([a, b, b], evictCaches: { _ in }, didMove: {})
        XCTAssertEqual(store.trashedItems.count, 2,
                       "ID-STORE-0003: batch must dedup against existing bin and itself")
        XCTAssertEqual(Set(store.trashedItems.map { $0.id }), Set([a.id, b.id]))
    }
}

#if DEBUG
// MARK: - P1-AUDIT-2026-09-22 (P1-1) helpers + cross-launch recovery test

/// Minimal StorageBackend double seeded with a fixed items array.
/// Distinct from production `MemoryStorageBackend` to keep the test
/// self-contained: the test needs to construct instances with a
/// pre-known items payload before the recovery attempt, without
/// touching the production type's internal state.
final class InMemoryStorageBackend: StorageBackend {
    private let lock = NSLock()
    private var items: [ClipboardItem]

    init(items: [ClipboardItem] = []) {
        self.items = items
    }

    func load() throws -> [ClipboardItem] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func save(_ newItems: [ClipboardItem]) throws {
        lock.lock(); defer { lock.unlock() }
        items = newItems
    }

    func loadTags() throws -> [Tag] { [] }

    func saveTags(_ tags: [Tag]) throws {}
}

extension ClipboardItem {
    /// Test helper: minimal stub builder. UUID is fresh each call so two
    /// stubs don't collide; identity isn't load-bearing in the
    /// P1-AUDIT-2026-09-22 regression test.
    static func makeStub(content: String, type: ClipboardItemType) -> ClipboardItem {
        ClipboardItem(content: content, type: type)
    }
}

extension TrashStoreMainActorTests {
    /// P1-AUDIT-2026-09-22 (audit finding P1-1): once a persistent-failure
    /// sentinel was set on a previous launch's quarantined blob, the next
    /// launch must still ATTEMPT backend.load() and clear the sentinel as
    /// soon as a healthier blob is found. Otherwise every subsequent launch
    /// short-circuits to trashedItems=[] even after the user recovers.
    /// Regression test for the cross-launch permanent suppress.
    func testSentinelClearsOnRecoveryAcrossLaunches() throws {
        let suiteName = "p1-sentinel-clear-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Simulate "Launch N-1 left the sentinel set after a quarantine":
        // write the persistent-failure flag directly. We don't go through
        // quarantineCorruptBlob here because that also removes the storage
        // key — testing recovery means the storage key still has data.
        suite.set(true, forKey: TrashStore.loadFailedSentinelKey)

        // "Launch N": init with a healthy backend that has data. The
        // recovery-path branch at TrashStore.swift:143-159 must accept
        // these items AND clear the persistent sentinel. Otherwise the
        // cleanupOrphanedImages safety (lastLoadFailed=true) bypasses
        // everything the user is trying to recover.
        let healthyBackend = InMemoryStorageBackend(items: [
            ClipboardItem.makeStub(content: "recovered", type: .text)
        ])
        let store = TrashStore(backend: healthyBackend, defaults: suite)

        XCTAssertEqual(store.trashedItems.count, 1,
                       "P1-AUDIT-2026-09-22: recovered items must surface")
        XCTAssertFalse(store.lastLoadFailed,
                       "P1-AUDIT-2026-09-22: lastLoadFailed must clear on recovery")
        XCTAssertFalse(suite.bool(forKey: TrashStore.loadFailedSentinelKey),
                       "P1-AUDIT-2026-09-22: sentinel must be removed after recovery")

        // Also verify that the "still quarantined" case keeps the sentinel —
        // if load returns empty (e.g. user never moved anything + blob was
        // gone), the persistent-failure mode must persist so cleanupOrphaned
        // stays disabled. This guards the optimization H-2 introduced.
        suite.set(true, forKey: TrashStore.loadFailedSentinelKey)
        let stillQuarantined = InMemoryStorageBackend(items: [])
        let store2 = TrashStore(backend: stillQuarantined, defaults: suite)
        XCTAssertTrue(store2.lastLoadFailed,
                      "Empty load after sentinel=true must stay in persistent-failure mode")
        XCTAssertTrue(suite.bool(forKey: TrashStore.loadFailedSentinelKey),
                      "Empty load after sentinel=true must keep sentinel")
    }
}
#endif
