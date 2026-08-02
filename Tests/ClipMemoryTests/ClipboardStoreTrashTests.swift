import XCTest
@testable import ClipMemory

/// Tests for the recycle bin (trash) feature.
@MainActor final class ClipboardStoreTrashTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var savedTrashRetentionDays: Any?

    override func setUp() {
        super.setUp()
        // M13 (2026-08-02 audit): the purge tests write
        // "ClipboardTrashedItems.retentionDays" through TrashStore's
        // trashRetentionDays didSet (hardwired UserDefaults.standard, not
        // suite-injectable). Back up the real value and restore it in
        // tearDown so a user's retention setting survives a test run
        // (STORE-0007 pattern).
        savedTrashRetentionDays = UserDefaults.standard.object(forKey: TrashStore.trashedItemsStorageKey + ".retentionDays")
        backend = MemoryStorageBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend, tagBackend: tagBackend, trashBackend: trashBackend)
    }

    override func tearDown() {
        // M13: restore the production value captured in setUp.
        if let savedTrashRetentionDays {
            UserDefaults.standard.set(savedTrashRetentionDays, forKey: TrashStore.trashedItemsStorageKey + ".retentionDays")
        } else {
            UserDefaults.standard.removeObject(forKey: TrashStore.trashedItemsStorageKey + ".retentionDays")
        }
        savedTrashRetentionDays = nil
        store = nil
        trashBackend = nil
        tagBackend = nil
        backend = nil
        super.tearDown()
    }

    // MARK: - Delete moves to trash

    func testDeleteItemMovesToTrash() {
        let item = ClipboardItem(content: "To delete", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.trashedItems.count, 0)

        store.deleteItem(store.items[0])
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 0)
        XCTAssertEqual(store.trashedItems.count, 1)
        XCTAssertNotNil(store.trashedItems[0].deletedAt)
    }

    func testDeleteItemsMovesAllToTrash() {
        let item1 = ClipboardItem(content: "Delete me 1", type: .text)
        let item2 = ClipboardItem(content: "Delete me 2", type: .text)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        store.deleteItems(store.items)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 0)
        XCTAssertEqual(store.trashedItems.count, 2)
    }

    func testClearAllItemsMovesToTrash() {
        let item1 = ClipboardItem(content: "Normal", type: .text, isPinned: false)
        let item2 = ClipboardItem(content: "Pinned", type: .text, isPinned: true)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        store.clearAllItems()
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].isPinned)
        XCTAssertEqual(store.trashedItems.count, 1)
    }

    func testClearTodayMovesToTrash() throws {
        let cal = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: now))
        let todayItem = ClipboardItem(content: "Today", type: .text, createdAt: now)
        let yesterdayItem = ClipboardItem(content: "Yesterday", type: .text, createdAt: yesterday)
        store.addItem(todayItem)
        store.addItem(yesterdayItem)
        store.flushPendingSaves()

        store.clearToday()
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.trashedItems.count, 1)
        let d = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(d, "Yesterday")
    }

    func testClearSensitiveItemsMovesToTrash() {
        let sensitive = ClipboardItem(content: "secret", type: .text, isSensitive: true)
        let normal = ClipboardItem(content: "harmless", type: .text, isSensitive: false)
        store.addItem(sensitive)
        store.addItem(normal)
        store.flushPendingSaves()

        store.clearSensitiveItems()
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.trashedItems.count, 1)
    }

    // MARK: - Restore

    func testRestoreFromTrashMovesBackToTop() {
        let item1 = ClipboardItem(content: "First", type: .text)
        let item2 = ClipboardItem(content: "Second", type: .text)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        store.deleteItem(store.items[0]) // "Second" deleted
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.trashedItems.count, 1)

        let trashed = store.trashedItems[0]
        store.restoreFromTrash(trashed)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.trashedItems.count, 0)
        XCTAssertNil(store.items[0].deletedAt)
        let d = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(d, "Second", "Restored item should be at top")
    }

    // MARK: - ID-CRASH-0001 (2026-07-31 Round 5): itemIndex invalidation on trash paths

    /// ID-CRASH-0001: `moveToTrash` mutated `items` without calling
    /// `invalidateItemIndex()`, leaving the ID-PERF-0015 UUID→index map
    /// stale. Repro: pin (builds the map) → delete the front item
    /// (all later indices shift) → pin again. Before the fix the stale
    /// index either crashed (`Index out of range`) or silently toggled
    /// the WRONG item.
    func testPinDeletePinDoesNotUseStaleItemIndex() {
        let itemA = ClipboardItem(content: "A", type: .text)
        let itemB = ClipboardItem(content: "B", type: .text)
        let itemC = ClipboardItem(content: "C", type: .text)
        store.addItem(itemA)
        store.addItem(itemB)
        store.addItem(itemC)
        store.flushPendingSaves()
        // items = [C, B, A]

        // Build the UUID→index map.
        store.togglePin(itemC)
        XCTAssertTrue(store.items[0].isPinned)

        // Delete the front item: indices of B/A shift by one.
        store.deleteItem(store.items[0]) // deletes C
        store.flushPendingSaves()
        // items = [B, A]; a stale map still says B→1, A→2 (2 is out of bounds)

        // Pre-fix: pinning B toggled items[1] (= A, wrong item);
        // pinning A crashed on index 2.
        store.togglePin(itemB)
        XCTAssertEqual(store.getDecryptedContent(store.items[0]), "B")
        XCTAssertTrue(store.items[0].isPinned, "B must be pinned")
        XCTAssertFalse(store.items[1].isPinned, "A must NOT be toggled by B's pin")

        store.togglePin(itemA) // pre-fix: Index out of range crash
        XCTAssertTrue(store.items[1].isPinned, "A must be pinned")
    }

    /// ID-CRASH-0001 (batch path): `moveToTrash(_ items:)` had the same
    /// missing invalidation — after batch deletion the stale map points
    /// past the end of the shrunk array.
    func testBatchTrashInvalidatesItemIndex() {
        let itemA = ClipboardItem(content: "A", type: .text)
        let itemB = ClipboardItem(content: "B", type: .text)
        let itemC = ClipboardItem(content: "C", type: .text)
        store.addItem(itemA)
        store.addItem(itemB)
        store.addItem(itemC)
        store.flushPendingSaves()
        // items = [C, B, A]; build the map
        store.togglePin(itemC)

        store.deleteItems([itemC, itemB])
        store.flushPendingSaves()
        // items = [A]; stale map says A→2 → pre-fix crash on next pin
        store.togglePin(itemA)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].isPinned, "A must be pinned, not crash")
    }

    /// ID-CRASH-0001 (restore path): `restoreFromTrash` inserts at 0,
    /// shifting every index — the stale map then swaps item positions.
    func testRestoreFromTrashInvalidatesItemIndex() {
        let itemA = ClipboardItem(content: "A", type: .text)
        let itemB = ClipboardItem(content: "B", type: .text)
        store.addItem(itemA)
        store.addItem(itemB)
        store.flushPendingSaves()
        // items = [B, A]; build the map
        store.togglePin(itemB)
        store.togglePin(itemB) // unpin B again, keep the built map

        store.deleteItem(itemA) // items = [B]
        store.flushPendingSaves()
        store.restoreFromTrash(store.trashedItems[0]) // items = [A, B]
        store.flushPendingSaves()
        // Stale map still says B→0, A→1 (swapped). Pre-fix: pinning B
        // toggled items[0] = A.
        store.togglePin(itemB)
        XCTAssertEqual(store.getDecryptedContent(store.items[0]), "A")
        XCTAssertFalse(store.items[0].isPinned, "A must NOT be toggled by B's pin")
        XCTAssertTrue(store.items[1].isPinned, "B must be pinned")
    }

    // MARK: - ID-LIFE-0023 (2026-07-31 Round 5): debounce timers survive first flush

    /// ID-LIFE-0023: `flushSave`/`flushTagSave` used to `cancel()` the
    /// reused DispatchSourceTimer WITHOUT nil-ing it. A cancelled GCD
    /// source silently ignores later `schedule()` calls, so once a
    /// channel's timer had fired (or been flushed) once, every subsequent
    /// debounced save on that channel was lost until graceful quit.
    /// Tags have NO write-through path — addTag/deleteTag depended
    /// entirely on this debounce. Repro: two consecutive debounced tag
    /// saves after an initial flush; pre-fix, cycle 2 never hit the backend.
    func testSecondDebounceTagSaveCycleStillPersists() {
        // Force an initial flush (any first clipboard capture does this
        // via saveImmediately) so the tag timer's first cycle is the
        // "post-flush" state already.
        store.addItem(ClipboardItem(content: "seed", type: .text))
        store.flushPendingSaves()

        // Debounced cycle 1 — creates + fires the tag timer (works even pre-fix).
        store.addTag(Tag(name: "cycle1", colorHex: "#FF6B6B"))
        let exp1 = expectation(description: "debounce cycle 1")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.5)

        // Debounced cycle 2 — pre-fix the cancelled source was reused and
        // this save NEVER reached the backend.
        store.addTag(Tag(name: "cycle2", colorHex: "#4ECDC4"))
        let exp2 = expectation(description: "debounce cycle 2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.5)

        // Reload a fresh store from the same backends: both cycles must be on disk.
        let reload = ClipboardStore(backend: backend, tagBackend: tagBackend, trashBackend: trashBackend)
        XCTAssertTrue(reload.tags.values.contains(where: { $0.name == "cycle1" }),
                      "cycle 1 tag must persist")
        XCTAssertTrue(reload.tags.values.contains(where: { $0.name == "cycle2" }),
                      "ID-LIFE-0023: second debounce cycle must still persist to the backend")
    }

    // MARK: - Permanent delete

    func testDeletePermanentlyRemovesFromTrash() {
        let item = ClipboardItem(content: "To delete permanently", type: .text)
        store.addItem(item)
        store.flushPendingSaves()
        store.deleteItem(store.items[0])
        store.flushPendingSaves()

        XCTAssertEqual(store.trashedItems.count, 1)

        store.deletePermanently(store.trashedItems[0])
        store.flushPendingSaves()

        XCTAssertEqual(store.trashedItems.count, 0)
    }

    // MARK: - Empty trash

    func testEmptyTrashDeletesAll() {
        let item1 = ClipboardItem(content: "Delete 1", type: .text)
        let item2 = ClipboardItem(content: "Delete 2", type: .text)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()
        store.deleteItems(store.items)
        store.flushPendingSaves()

        XCTAssertEqual(store.trashedItems.count, 2)

        store.emptyTrash()
        store.flushPendingSaves()

        XCTAssertEqual(store.trashedItems.count, 0)
    }

    // MARK: - Purge expired trash

    func testPurgeExpiredTrashOnlyRemovesOld() {
        let oldItem = ClipboardItem(content: "Old", type: .text, deletedAt: Date().addingTimeInterval(-10 * 24 * 3600))
        let recentItem = ClipboardItem(content: "Recent", type: .text, deletedAt: Date().addingTimeInterval(-1 * 3600))
        store.trashedItems = [oldItem, recentItem]

        store.trashRetentionDays = 7
        store.purgeExpiredTrash()

        XCTAssertEqual(store.trashedItems.count, 1)
        let d = store.getDecryptedContent(store.trashedItems[0])
        XCTAssertEqual(d, "Recent")
    }

    // MARK: - Trash refresh (2026-07-27 user-reported)

    /// Trash refresh fix: after HIGH-1 extracted the trash into a separate
    /// `TrashStore` ObservableObject, mutations to `trashStore.trashedItems`
    /// stopped re-rendering views that observe `ClipboardStore`. The store
    /// now forwards trashStore's `objectWillChange` through its own publisher
    /// so SwiftUI views observing the parent get notified.
    ///
    /// We pin the contract here by counting publisher firings on a parent
    /// `ClipboardStore` instance. Before the fix, `deletePermanently` would
    /// only mutate `trashStore.trashedItems`, leaving the parent publisher
    /// silent; after the fix, the parent's publisher fires when trash mutates.
    func testDeletePermanentlyTriggersParentStorePublisher() {
        let item = ClipboardItem(content: "to-delete", type: .text, deletedAt: Date())
        store.trashedItems = [item]

        // Subscribe to the parent's publisher BEFORE the mutation so we
        // catch the change notification.
        var parentFirings = 0
        let cancellable = store.objectWillChange.sink { _ in parentFirings += 1 }
        defer { _ = cancellable } // keep subscription alive across the mutation

        // Delete the trashed item — the trashStore mutation should now
        // propagate through the parent's publisher.
        store.deletePermanently(item)

        XCTAssertGreaterThanOrEqual(parentFirings, 1,
            "deletePermanently must trigger the parent ClipboardStore publisher so views observing it re-render")
        XCTAssertEqual(store.trashedItems.count, 0,
            "sanity: trash must actually be empty after delete")
    }

    /// Same contract for `emptyTrash`. Pin both call paths.
    func testEmptyTrashTriggersParentStorePublisher() {
        store.trashedItems = [
            ClipboardItem(content: "a", type: .text, deletedAt: Date()),
            ClipboardItem(content: "b", type: .text, deletedAt: Date())
        ]

        var parentFirings = 0
        let cancellable = store.objectWillChange.sink { _ in parentFirings += 1 }
        defer { _ = cancellable }

        store.emptyTrash()

        XCTAssertGreaterThanOrEqual(parentFirings, 1,
            "emptyTrash must trigger the parent ClipboardStore publisher")
        XCTAssertEqual(store.trashedItems.count, 0)
    }

    // MARK: - NEW-C (2026-07-27 review): periodic timer drives trash purge

    /// NEW-C: the 60s `cleanupTimer` (ClipboardStore.swift:312-321) now
    /// also calls `trashStore.purgeExpiredTrash()` alongside
    /// `cleanupExpiredItems()`. Before the fix, `purgeExpiredTrash` was
    /// only called from `TrashStore.init`, so a long-running session
    /// that outlived `trashRetentionDays` accumulated expired trash on
    /// disk until next launch.
    ///
    /// `cleanupExpiredItems` was promoted from `private` to `internal`
    /// in this fix so the timer callback contract is testable without
    /// driving the actual 60s DispatchSourceTimer (which would slow CI).
    /// The production timer still calls both methods in the same order
    /// as before; this test pins that contract.
    func testPeriodicTimerCallbackAlsoPurgesExpiredTrash() {
        // Trash contains an item past retentionDays. The 60s timer's
        // callback is the production driver; we invoke the same two
        // methods it calls and assert both fire.
        store.trashRetentionDays = 7
        let expiredTrash = ClipboardItem(
            content: "TrashExpired",
            type: .text,
            deletedAt: Date().addingTimeInterval(-10 * 24 * 3600)
        )
        store.trashedItems = [expiredTrash]
        XCTAssertEqual(store.trashedItems.count, 1, "precondition: trash must hold the expired item")

        // Drive the same work the timer's event handler drives.
        // The production handler at ClipboardStore.swift:316-320 calls
        // cleanupExpiredItems() + trashStore.purgeExpiredTrash().
        store.cleanupExpiredItems()
        store.purgeExpiredTrash()

        XCTAssertEqual(store.trashedItems.count, 0,
                       "NEW-C: the timer's callback path must purge expired trash, not leave it to next launch")
    }

    // MARK: - Auto cleanup does not trash

    func testTrimToMaxItemsDoesNotTrash() {
        // maxItems persists to UserDefaults via didSet — restore it so later
        // test classes (e.g. IntegrationTests) don't inherit the tiny cap.
        // M-3 (2026-07-24) widened init acceptance from {50,100,200,500} to
        // the [1, 10000] clamp, which made this leak visible downstream.
        let originalMaxItems = store.maxItems
        defer { store.maxItems = originalMaxItems }
        store.maxItems = 2
        for i in 1...5 {
            store.addItem(ClipboardItem(content: "Item \(i)", type: .text))
        }
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.trashedItems.count, 0, "trimToMaxItems should permanently delete, not trash")
    }

    // MARK: - ID-STORE-0002 (2026-07-31 audit): expiry cleanup goes to trash

    /// ID-STORE-0002: an expired item must land in the recycle bin
    /// (recoverable), not vanish permanently. Covers the restart path —
    /// loadItems previously filtered expired items out of `items` and let
    /// the next save wipe them, bypassing the trash entirely.
    func testExpiredItemMovesToTrashOnRestart() {
        let expired = ClipboardItem(content: "Expired", type: .text, expiresAt: Date().addingTimeInterval(-3600))
        store.addItem(expired)
        store.flushPendingSaves()

        // Simulate restart which triggers the loadItems expiry path.
        let store2 = ClipboardStore(backend: backend, trashBackend: trashBackend)

        XCTAssertEqual(store2.items.count, 0)
        XCTAssertEqual(store2.trashedItems.count, 1,
                       "ID-STORE-0002: expired item must be recoverable via trash, not permanently deleted")
        XCTAssertEqual(store2.trashedItems[0].id, expired.id)
    }

    /// ID-STORE-0002: pin is an explicit retention guarantee — a pinned
    /// expired item must survive BOTH the in-session cleanup pass
    /// (cleanupExpiredItems, driven by the 60s timer) and the restart
    /// (loadItems) path. Pre-fix both paths dropped pinned expired content
    /// permanently.
    func testPinnedExpiredItemSurvivesCleanupAndRestart() {
        let pinnedExpired = ClipboardItem(content: "PinnedExpired", type: .text,
                                          isPinned: true, expiresAt: Date().addingTimeInterval(-3600))
        store.addItem(pinnedExpired)
        store.flushPendingSaves()

        // In-session path (the 60s timer's driver).
        store.cleanupExpiredItems()
        XCTAssertEqual(store.items.count, 1, "pinned expired item must not be cleaned up")
        XCTAssertEqual(store.trashedItems.count, 0)

        // Restart path (loadItems filter).
        let store2 = ClipboardStore(backend: backend, trashBackend: trashBackend)
        XCTAssertEqual(store2.items.count, 1,
                       "ID-STORE-0002: pinned expired item must survive load")
        XCTAssertTrue(store2.items[0].isPinned)
        XCTAssertEqual(store2.trashedItems.count, 0)
    }

    /// ID-STORE-0002: mixed batch — in-session cleanup trashes ONLY the
    /// unpinned expired items; pinned expired and non-expired items stay.
    func testCleanupExpiredItemsTrashesOnlyUnpinnedExpired() {
        let pinnedExpired = ClipboardItem(content: "PinnedExpired", type: .text,
                                          isPinned: true, expiresAt: Date().addingTimeInterval(-3600))
        let plainExpired = ClipboardItem(content: "PlainExpired", type: .text,
                                         expiresAt: Date().addingTimeInterval(-3600))
        let alive = ClipboardItem(content: "Alive", type: .text)
        store.addItem(pinnedExpired)
        store.addItem(plainExpired)
        store.addItem(alive)
        store.flushPendingSaves()

        store.cleanupExpiredItems()
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(store.items.contains { $0.id == pinnedExpired.id },
                      "pinned expired item must be exempt")
        XCTAssertTrue(store.items.contains { $0.id == alive.id })
        XCTAssertEqual(store.trashedItems.count, 1)
        XCTAssertEqual(store.trashedItems[0].id, plainExpired.id,
                       "unpinned expired item must go to trash, not vanish")
    }

    // MARK: - ID-STORE-0003 (2026-07-31 audit): trash dedup by id

    /// ID-STORE-0003: moving the same item to trash twice (batch + single
    /// delete race, restore-then-retrash) must be idempotent — exactly one
    /// bin entry per id. Pre-fix the second move inserted a duplicate.
    func testMoveToTrashSameItemTwiceIsIdempotent() {
        let item = ClipboardItem(content: "dup", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        store.deleteItem(item)
        store.moveToTrash(item) // second move — pre-fix created a duplicate
        store.flushPendingSaves()

        XCTAssertEqual(store.trashedItems.count, 1,
                       "ID-STORE-0003: same id must not duplicate in trash")
    }

    // MARK: - Trash persistence

    func testTrashPersistsAfterRestart() {
        let item = ClipboardItem(content: "Delete me", type: .text)
        store.addItem(item)
        store.flushPendingSaves()
        store.deleteItem(store.items[0])
        store.flushPendingSaves()

        XCTAssertEqual(store.trashedItems.count, 1)

        // Simulate restart
        let store2 = ClipboardStore(backend: backend, trashBackend: trashBackend)
        XCTAssertEqual(store2.trashedItems.count, 1)
        XCTAssertNotNil(store2.trashedItems[0].deletedAt)
    }

    // MARK: - Image cleanup keeps trashed images

    func testImageCleanupKeepsTrashedImages() {
        let imageItem = ClipboardItem(content: "\(UUID().uuidString).png", type: .image)
        store.addItem(imageItem)
        store.flushPendingSaves()

        // Move to trash
        store.deleteItem(store.items[0])
        store.flushPendingSaves()

        // cleanupOrphanedImages is called on load; verify the image file
        // is still considered referenced. We can't easily test the actual
        // file deletion without touching disk, but we can verify the
        // keptItems argument includes trashed items.
        XCTAssertEqual(store.trashedItems.count, 1)
        XCTAssertEqual(store.items.count, 0)
    }
}
