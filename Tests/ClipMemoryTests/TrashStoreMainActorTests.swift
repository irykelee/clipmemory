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
    /// ID-FLAKE-0004 (2026-10-23): the wait is now CONDITIONAL rather than
    /// fixed. The old form waited `asyncAfter(+0.7)` and asserted inside the
    /// callback — but the debounce interval is 500ms, so the margin was only
    /// 200ms. Under CI load the timer fires late and the assertion reads the
    /// backend before the write landed, which is the confirmed flake shape.
    /// Polling for the state makes the verdict depend on "did the write
    /// happen", not on how fast the machine is.
    ///
    /// Future improvement: inject `debounceInterval` so tests can use a
    /// shorter value and avoid the wait below.
    func testScheduleSaveDebouncesAndFlushesToBackend() {
        let item = ClipboardItem(content: "debounce me", type: .text)
        store.moveToTrash(item, evictCaches: { _ in }, didMove: {})

        // The flush runs .main → MainActor.assumeIsolated → flushSave →
        // saveTrashedItems → backend.save. If any isolation link is broken,
        // flushSave crashes and the test fails.
        XCTAssertTrue(
            waitForPersistedTrashCount(1),
            "ID-FLAKE-0004: the debounced flush must reach the backend"
        )

        // Reload from the SAME backend instance to read what was saved.
        let reload = TrashStore(backend: backend, defaults: testDefaults)
        XCTAssertEqual(reload.trashedItems.count, 1)
        XCTAssertEqual(reload.trashedItems.first?.content, "debounce me")
    }

    /// ID-LIFE-0023 (2026-07-31 Round 5): the debounced flush used to
    /// `cancel()` the reused timer source without nil-ing it — a cancelled
    /// GCD source silently ignores later `schedule()` calls, so after the
    /// FIRST debounced fire every subsequent trash save was lost until
    /// graceful quit. Two consecutive cycles must both reach the backend.
    ///
    /// ID-FLAKE-0004 (2026-10-23): the two fixed `asyncAfter(+0.7)` waits
    /// are replaced by conditional waits (see the sibling test).
    func testSecondDebounceCycleStillPersists() {
        store.moveToTrash(ClipboardItem(content: "cycle1", type: .text), evictCaches: { _ in }, didMove: {})
        XCTAssertTrue(
            waitForPersistedTrashCount(1),
            "ID-FLAKE-0004: the first debounce cycle must reach the backend"
        )

        // Cycle 2 — pre-fix the dead source was reused and never fired.
        store.moveToTrash(ClipboardItem(content: "cycle2", type: .text), evictCaches: { _ in }, didMove: {})
        XCTAssertTrue(
            waitForPersistedTrashCount(2),
            "ID-LIFE-0023: second debounce cycle must still persist to the backend"
        )

        let reload = TrashStore(backend: backend, defaults: testDefaults)
        XCTAssertEqual(reload.trashedItems.count, 2,
                       "ID-LIFE-0023: second debounce cycle must still persist to the backend")
    }

    // MARK: - ID-FLAKE-0004 helpers

    /// Polls until the backend really holds `expected` trashed entries.
    ///
    /// ID-FLAKE-0004: a fixed sleep would race the debounce timer; the
    /// verdict must depend on the write having happened, not on elapsed
    /// wall-clock time.
    private func waitForPersistedTrashCount(_ expected: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if persistedTrashCount() == expected { return true }
            // Yield the main thread: the debounce timer lives on
            // `saveTimerQueue` (utility queue) and the flush is dispatched
            // to `.main`, so it only runs while the main run loop spins.
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return persistedTrashCount() == expected
    }

    /// How many entries the backend currently holds in its TRASH dimension
    /// (-1 when it cannot be read).
    ///
    /// ID-FLAKE-0004: this must read the trash dimension, NOT the main
    /// items array. Since PR-C the recycle bin is its own store
    /// (`MemoryStorageBackend._trashItems` / `FileStorageBackend`'s trash
    /// key), so `backend.load()` answers "how many ITEMS are there" — a
    /// permanently-zero answer that would make this wait time out on a
    /// perfectly healthy store.
    private func persistedTrashCount() -> Int {
        (try? backend.loadTrashAll())?.count ?? -1
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

    /// ID-CRASH-0022 (2026-10-20): while the trash load is in a FAILED
    /// state, the store must NOT write an EMPTY collection.
    ///
    /// `FileStorageBackend.save(_:)` is a WHOLE-ARRAY REPLACE. An empty
    /// write while the load has failed would replace the store's
    /// content with a known-empty collection — and in the
    /// persistent-failure branch the unreadable blob is still sitting
    /// in the main key (that branch does not quarantine it), so the
    /// empty write is exactly what would destroy it.
    ///
    /// NOTE: this was originally written as "refuse EVERY write", on
    /// the theory that the in-memory collection never represents the
    /// store. That theory was wrong (a failed load quarantines the
    /// blob and REMOVES the main key, so there is nothing left to
    /// destroy) and the guard was narrowed — see
    /// `testFailedLoadStillPersistsNewlyTrashedItem` for the other
    /// half of the contract.
    ///
    /// This is the blob-side twin of the guard that already protects the
    /// image side (`ClipboardStore.loadItems` skips
    /// `cleanupOrphanedImages` while `lastLoadFailed` is true).
    ///
    /// Discriminating power: widen the guard back to "refuse every
    /// write" and this test goes red (the empty array reaches the
    /// store).
    func testFailedLoadRefusesToWriteOverStore() {
        // Launch-1 failure state: the sentinel is set, the blob is gone.
        testDefaults.set(true, forKey: TrashStore.loadFailedSentinelKey)
        testDefaults.removeObject(forKey: TrashStore.trashedItemsStorageKey)

        let recorder = SaveRecordingTrashBackend()
        let failingStore = TrashStore(backend: recorder, defaults: testDefaults)
        XCTAssertTrue(failingStore.lastLoadFailed,
                      "the sentinel short-circuit must set lastLoadFailed")

        failingStore.saveTrashedItems()

        XCTAssertEqual(recorder.savesObserved, 0,
                       "a failed load must not be followed by a write — it would replace the store with an empty array")
    }

    /// The counterpart of `testFailedLoadRefusesToWriteOverStore`: a
    /// HEALTHY store must still be able to write an EMPTY collection.
    ///
    /// The ID-CRASH-0022 guard keys on the load-failed flag, NOT on
    /// emptiness — "the user emptied the recycle bin" is a legitimate
    /// empty write, and it is the only way to clear the bin. If the
    /// guard were written as "never write an empty array", the user
    /// could never empty their recycle bin and this test goes red.
    func testHealthyStoreStillWritesAnEmptyCollection() {
        let recorder = SaveRecordingTrashBackend()
        let healthy = TrashStore(backend: recorder, defaults: testDefaults)
        XCTAssertFalse(healthy.lastLoadFailed,
                       "a store with no sentinel and a healthy backend is not in the failed state")

        healthy.saveTrashedItems()

        XCTAssertEqual(recorder.savesObserved, 1,
                       "an empty write from a healthy store is legitimate — it is how the user empties the recycle bin")
    }

    /// ID-CRASH-0022 (2026-10-20, corrected later the same day): the
    /// other half of the corrected guard.
    ///
    /// The ORIGINAL guard refused EVERY write while `lastLoadFailed`
    /// was true. A probe proved it protected nothing (the quarantine
    /// MOVES the blob to a `.corrupt-*` key and REMOVES the main key,
    /// so there was no store content left to destroy — and the
    /// quarantined copy is byte-identical after any write).
    ///
    /// What it did cost was real: an item the user trashed during a
    /// degraded launch stayed in memory only, and the app could never
    /// leave the degraded state (the sentinel path only clears itself
    /// when the blob comes back non-empty).
    ///
    /// So the guard is now narrow: an EMPTY write is still refused, a
    /// NON-EMPTY write is allowed. This test pins the allowed half.
    func testFailedLoadStillPersistsNewlyTrashedItem() {
        // Launch-1 failure state: the sentinel is set, the blob is gone.
        testDefaults.set(true, forKey: TrashStore.loadFailedSentinelKey)
        testDefaults.removeObject(forKey: TrashStore.trashedItemsStorageKey)

        let recorder = SaveRecordingTrashBackend()
        let failingStore = TrashStore(backend: recorder, defaults: testDefaults)
        XCTAssertTrue(failingStore.lastLoadFailed,
                      "the sentinel short-circuit must set lastLoadFailed")

        let item = ClipboardItem(content: "trashed during a degraded launch", type: .text)
        failingStore.moveToTrash(item, evictCaches: { _ in }, didMove: {})
        failingStore.saveTrashedItems()

        XCTAssertEqual(recorder.savesObserved, 1,
                       "a newly trashed item must still reach the store — the failed-load state is not a reason to lose the user's data")
        XCTAssertEqual(recorder.savedItems.first?.content, "trashed during a degraded launch",
                       "the persisted collection must carry the new item, not an empty array")
    }

    /// ID-CRASH-0022 (2026-10-20): the retention purge is a DELETE —
    /// it removes every item past the retention window and the whole
    /// bin is then rewritten as `[]`. It used to run with NO
    /// user-visible signal at all, which is exactly how the 2026-10-20
    /// incident emptied 106 items in one launch without saying
    /// anything.
    ///
    /// The third leg of the data-deletion gate (报错 / 重试 / 用户可见)
    /// requires the user to be told. This pins the notice: the count of
    /// removed items and the window that was applied.
    func testRetentionPurgeAnnouncesHowManyItemsItRemoved() throws {
        let suiteName = "purge-notice-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let expired = ClipboardItem(
            content: "expired",
            type: .text,
            deletedAt: Date().addingTimeInterval(-40 * 24 * 60 * 60)
        )
        let fresh = ClipboardItem(
            content: "fresh",
            type: .text,
            deletedAt: Date()
        )
        let backend = InMemoryStorageBackend(items: [expired, fresh])

        let exp = expectation(description: "purge notice posted")
        var received: [AnyHashable: Any]?
        let token = NotificationCenter.default.addObserver(
            forName: .trashItemsExpired, object: nil, queue: .main
        ) { note in
            received = note.userInfo
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let store = TrashStore(backend: backend, defaults: suite)
        // The notice is posted asynchronously on purpose (the purge runs
        // inside `TrashStore.init`, before the AppDelegate registers its
        // observers) — spin the run loop until it arrives.
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(received?["count"] as? Int, 1,
                       "the notice must say how many items the purge removed")
        XCTAssertEqual(received?["retentionDays"] as? Int, 7,
                       "the notice must say which retention window was applied")
        XCTAssertEqual(store.trashedItems.count, 1,
                       "only the expired item may be removed")
        XCTAssertEqual(store.trashedItems.first?.content, "fresh",
                       "the item inside the retention window must survive the purge")
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

    /// P1-AUDIT-2026-09-22 (audit finding P1-3): the legacy
    /// scheduleSaveRetry() guarded on `needsSave`, but flushSave flips
    /// needsSave=false BEFORE calling saveTrashedItems(). On failure the
    /// retry guard immediately returned — retry was dead code, just like
    /// ClipboardStore's pre-H-1 needsSave race that was fixed 2026-08-09.
    /// Regression test: a failing backend save followed by a healthy one
    /// 6s later must persist the recovered items.
    func testRetryActuallyReschedulesAfterSaveFailure() throws {
        let suiteName = "p1-retry-actually-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Backend that fails on first save, then succeeds.
        let flakyBackend = FlakyStorageBackend(failFirstN: 1)

        let store = TrashStore(backend: flakyBackend, defaults: suite)
        XCTAssertEqual(store.trashedItems.count, 0, "Starts empty")

        // Move an item to trash. This calls scheduleSave → flushSave →
        // saveTrashedItems → first save THROWS.
        let item = ClipboardItem.makeStub(content: "retry-me", type: .text)
        store.moveToTrash(item, evictCaches: { _ in }, didMove: {})

        // Wait for the retry save to actually happen.
        // ID-FLAKE-0004 (2026-10-23): the old form waited a FIXED 7.0s and
        // asserted inside the callback — a 2s margin over the 5s retry
        // deadline, which is the same fragile shape as the debounce waits
        // fixed earlier in this file. The wait is now conditional: poll
        // until the backend has recorded the retry save.
        //
        // The main run loop has to spin either way: the retry timer lives
        // on the .utility queue and dispatches its flushSave() closure to
        // .main. (A Thread.sleep loop on an @MainActor-isolated test method
        // blocks the main thread and prevents the timer→main dispatch
        // chain from ever firing.)
        XCTAssertTrue(
            waitForSaveCount(2, in: flakyBackend),
            "P1-AUDIT-2026-09-22: failure path must trigger a retry save"
        )
        XCTAssertEqual(flakyBackend.savesObserved, 2,
                       "P1-AUDIT-2026-09-22: exactly one retry save — not more")
    }

    /// Polls until the backend has recorded at least `expected` saves.
    ///
    /// ID-FLAKE-0004: a fixed sleep races the retry timer; the verdict
    /// must depend on the write having happened, not on elapsed time.
    private func waitForSaveCount(
        _ expected: Int,
        in backend: FlakyStorageBackend,
        timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if backend.savesObserved >= expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return backend.savesObserved >= expected
    }
}

/// StorageBackend that fails the first N saves then succeeds.
final class FlakyStorageBackend: StorageBackend, @unchecked Sendable {
    private var failuresRemaining: Int
    private let lock = NSLock()
    private(set) var savesObserved = 0
    private var savedItems: [ClipboardItem] = []

    init(failFirstN: Int) { self.failuresRemaining = failFirstN }

    func load() throws -> [ClipboardItem] {
        lock.lock(); defer { lock.unlock() }
        return savedItems
    }

    func save(_ items: [ClipboardItem]) throws {
        lock.lock(); defer { lock.unlock() }
        savesObserved += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw BackupPackageError.archiveFailed
        }
        savedItems = items
    }

    func loadTags() throws -> [Tag] { [] }

    func saveTags(_ tags: [Tag]) throws {}
}

/// StorageBackend that records every save, so a test can prove that a
/// write did (or did not) reach the store.
///
/// ID-CRASH-0022 (2026-10-20) helper — the whole-array-replace hazard
/// is invisible unless you can count the writes.
final class SaveRecordingTrashBackend: StorageBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var savesObserved = 0
    private(set) var savedItems: [ClipboardItem] = []

    func load() throws -> [ClipboardItem] {
        lock.lock(); defer { lock.unlock() }
        return savedItems
    }

    func save(_ items: [ClipboardItem]) throws {
        lock.lock(); defer { lock.unlock() }
        savesObserved += 1
        savedItems = items
    }

    func loadTags() throws -> [Tag] { [] }

    func saveTags(_ tags: [Tag]) throws {}
}
#endif
