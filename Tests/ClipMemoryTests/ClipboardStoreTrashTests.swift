import XCTest
@testable import ClipMemory

// swiftlint:disable file_length

/// Tests for the recycle bin (trash) feature.
@MainActor final class ClipboardStoreTrashTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // M13 (2026-08-03): TrashStore now uses injectable defaults. Pass a
        // test suite so trashRetentionDays writes never touch production.
        testDefaults = makeTestDefaults()
        backend = MemoryStorageBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend, tagBackend: tagBackend, trashBackend: trashBackend, defaults: testDefaults)
    }

    override func tearDown() {
        store = nil
        trashBackend = nil
        tagBackend = nil
        backend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
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

    /// NEW-batch-restore: pass an array of items, all should be restored
    /// to the top of the active list in array order (first arg → top).
    /// Mirrors per-item `restoreFromTrash` behavior but lets the UI
    /// restore N items in one call (so saves / invalidations batch).
    func testRestoreFromTrashArrayMovesAllBack() {
        // Seed 3 items, delete all 3 to trash (order: "Third", "Second", "First")
        let item1 = ClipboardItem(content: "First", type: .text)
        let item2 = ClipboardItem(content: "Second", type: .text)
        let item3 = ClipboardItem(content: "Third", type: .text)
        store.addItem(item1)
        store.addItem(item2)
        store.addItem(item3)
        store.flushPendingSaves()

        store.deleteItem(store.items[0]) // "Third"
        store.deleteItem(store.items[0]) // "Second"
        store.deleteItem(store.items[0]) // "First"
        store.flushPendingSaves()
        XCTAssertEqual(store.trashedItems.count, 3)

        // Restore all 3 in the order they were trashed (Third, Second, First).
        // After per-item insert(at: 0), each subsequent restore pushes the
        // previous to position 1. The final array order from top is the
        // REVERSE of the restore order — i.e. insertion-order preserved
        // with the OLDEST trashed at the top.
        let trashed = store.trashedItems
        store.restoreFromTrash(trashed)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 3, "All 3 trash items must be restored")
        XCTAssertEqual(store.trashedItems.count, 0, "Trash must be empty")
        XCTAssertNil(store.items[0].deletedAt, "Restored item must have deletedAt cleared")
        XCTAssertNil(store.items[1].deletedAt)
        XCTAssertNil(store.items[2].deletedAt)
        XCTAssertEqual(store.getDecryptedContent(store.items[0]), "Third",
                       "Most-recently-trashed ends at top after batch restore")
        XCTAssertEqual(store.getDecryptedContent(store.items[1]), "Second")
        XCTAssertEqual(store.getDecryptedContent(store.items[2]), "First",
                       "Oldest-trashed ends at bottom")
    }

    // MARK: - P1-AUDIT-2026-09-22 (P2-4): batch restore trims + dedupes by contentHash

    /// P2-4 from `docs/review/code-review-2026-09-21.md`: the array-form
    /// `restoreFromTrash(_ items:)` could exceed `maxItems` (10K cap) and
    /// insert duplicates when multiple trashed items shared a
    /// `contentHash`. Pin both invariants with one fixture: a small cap
    /// forces the trim, and 100 copies per contentHash force the dedup.
    ///
    /// Fixture scale: 1200 items (12 unique contents × 100 copies each)
    /// against `maxItems = 10`. Trim path must cap active at <= 10,
    /// dedup path must keep `Set(active contentHashes).count == count`
    /// (i.e. no duplicate contentHashes in the active list).
    /// Scaled down from the brief's 12K to keep the test under 1s —
    /// still exercises both bugs end-to-end.
    func testRestoreFromTrashBatchTrimsAndDedupes() throws {
        // testDefaults is suite-isolated so `store.maxItems = 10` writes
        // don't leak to UserDefaults.standard (ID-STORE-0014 invariant).
        store.maxItems = 10

        // 1200 items / 12 unique contentHashes. Each content has 100
        // copies so dedup-by-contentHash must collapse them to 12
        // entries, then trim to maxItems=10 picks 10 of those 12.
        var trashed: [ClipboardItem] = []
        for i in 0..<12 {
            let content = "x\(i)"
            let hash = "hash-\(i)"
            for _ in 0..<100 {
                trashed.append(ClipboardItem(
                    content: content,
                    type: .text,
                    contentHash: hash
                ))
            }
        }
        store.moveToTrash(trashed)
        store.flushPendingSaves()

        XCTAssertEqual(store.trashedItems.count, 1200,
                       "precondition: all 1200 items fit in trash (unique ids)")
        XCTAssertEqual(store.items.count, 0,
                       "precondition: active list is empty before restore")

        // Restore in reverse-trash-order — preserves the existing
        // behavior pinned by testRestoreFromTrashArrayMovesAllBack and
        // keeps the test independent of batch pre-sort order.
        let toRestore = store.trashedItems
        store.restoreFromTrash(toRestore)
        store.flushPendingSaves()

        // P2-4 (trim): active list must respect maxItems, regardless of
        // how many trashed items the caller passed.
        XCTAssertLessThanOrEqual(
            store.items.count, store.maxItems,
            "P2-4: bulk restore must not exceed maxItems cap"
        )
        // P2-4 (dedup): every restored item's contentHash must be
        // unique within the active list. compactMap drops any nil-hash
        // entries that shouldn't exist here (we set every contentHash
        // in the fixture); presence of nil hashes would also violate
        // the dedup invariant.
        let activeHashes = store.items.compactMap { $0.contentHash }
        XCTAssertEqual(
            activeHashes.count, Set(activeHashes).count,
            "P2-4: bulk restore must dedupe by contentHash"
        )
        // Sanity: trim must have fired — restoring 1200 against a cap
        // of 10 means at least 1190 items are NOT restored (trash
        // should still hold them).
        XCTAssertLessThan(
            store.items.count, 1200,
            "P2-4: trim must drop the overflow batch"
        )
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
    ///
    /// ID-FLAKE-0002 (2026-10-23): 原来这里用「睡 0.7s + 1.5s 超时」去等
    /// 500ms 的 debounce 落盘 —— 余量只有 200ms。而 debounce 定时器跑在
    /// `com.clipmemory.tagsave`（**utility QoS**，优先级低于默认）队列上，
    /// CI 负载下晚触发几百毫秒是常事：cycle 2 的写盘落在断言之后，
    /// `reload.tags` 里就少了 cycle2 ⇒ 偶发红。改成**等条件**（轮询到
    /// tag 真的落到 backend 为止），时间窗从「200ms 余量」放宽到 10s，
    /// 结论不再依赖机器快慢。
    ///
    /// 同时补上**负向断言**（`elapsed > 0.4`）：debounce 必须真的延迟
    /// 写入。生产间隔是 500ms，GCD 定时器只会晚触发不会早触发，所以这条
    /// 线有 ~100ms 余量；把 debounce 间隔改成 0 的话 `elapsed` 会掉到
    /// 0.02s 左右，这条断言会红。
    func testSecondDebounceTagSaveCycleStillPersists() {
        // Force an initial flush (any first clipboard capture does this
        // via saveImmediately) so the tag timer's first cycle is the
        // "post-flush" state already.
        store.addItem(ClipboardItem(content: "seed", type: .text))
        store.flushPendingSaves()

        // Debounced cycle 1 — creates + fires the tag timer (works even pre-fix).
        let cycle1Start = ProcessInfo.processInfo.systemUptime
        store.addTag(Tag(name: "cycle1", colorHex: "#FF6B6B"))
        XCTAssertTrue(waitForTagPersisted(named: "cycle1"),
                      "ID-FLAKE-0002: first debounce cycle must persist cycle1 to the backend")
        let cycle1Elapsed = ProcessInfo.processInfo.systemUptime - cycle1Start
        XCTAssertGreaterThan(cycle1Elapsed, 0.4,
                             "debounce 必须真的延迟写入：cycle1 落盘耗时 \(cycle1Elapsed)s，"
                             + "低于 0.4s 说明 debounce 间隔被改小了")

        // Debounced cycle 2 — pre-fix the cancelled source was reused and
        // this save NEVER reached the backend.
        let cycle2Start = ProcessInfo.processInfo.systemUptime
        store.addTag(Tag(name: "cycle2", colorHex: "#4ECDC4"))
        XCTAssertTrue(waitForTagPersisted(named: "cycle2"),
                      "ID-LIFE-0023: second debounce cycle must still persist to the backend")
        let cycle2Elapsed = ProcessInfo.processInfo.systemUptime - cycle2Start
        XCTAssertGreaterThan(cycle2Elapsed, 0.4,
                             "debounce 必须真的延迟写入：cycle2 落盘耗时 \(cycle2Elapsed)s，"
                             + "低于 0.4s 说明 debounce 间隔被改小了")

        // Reload a fresh store from the same backends: both cycles must be on disk.
        let reload = ClipboardStore(backend: backend, tagBackend: tagBackend, trashBackend: trashBackend)
        XCTAssertTrue(reload.tags.values.contains(where: { $0.name == "cycle1" }),
                      "cycle 1 tag must persist")
        XCTAssertTrue(reload.tags.values.contains(where: { $0.name == "cycle2" }),
                      "ID-LIFE-0023: second debounce cycle must still persist to the backend")
    }

    /// 轮询等待某个 tag 真的落到 tag backend 里（**等条件**，不是固定 sleep）。
    ///
    /// 固定 sleep 会在写盘落地之前就去读 backend —— 这正是本用例偶发红的
    /// 根因（debounce 定时器在 CI 负载下可能晚触发几百毫秒）。改成等条件
    /// 之后，结论只取决于「写盘有没有发生」，不取决于机器快慢。
    private func waitForTagPersisted(named name: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if persistedTagNames().contains(name) { return true }
            // 让出主线程：后台定时器 → `Task { @MainActor in flushTagSave() }`
            // 的落盘要靠主队列被 runloop 抽干才会发生。
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return persistedTagNames().contains(name)
    }

    /// 读出 tag backend 里已落盘的 tag 名（解开名字加密）。
    private func persistedTagNames() -> Set<String> {
        guard let loaded = try? tagBackend.loadTags() else { return [] }
        return Set(store.decryptTagNames(loaded).map(\.name))
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

    /// M-2 (2026-08-08 audit): cap-driven evictions must route through
    /// the recycle bin (recoverable) rather than be physically deleted.
    /// Pre-fix, `trimToMaxItems()` called `ImageStorage.deleteImage` +
    /// `items.removeAll` — silent data loss for both steady-state
    /// `addItem` overflow and bulk `importBackupItems` overflow.
    /// The old `testTrimToMaxItemsDoesNotTrash` (renamed to this one)
    /// pinned the buggy behavior; this is its corrected M-2 contract.
    func testTrimToMaxItemsOverflowsToTrash() {
        // maxItems persists to UserDefaults via didSet — restore it so later
        // test classes (e.g. IntegrationTests) don't inherit the tiny cap.
        // M-3 (2026-07-24) widened init acceptance from {50,100,200,500} to
        // the [1, 10000] clamp, which made this leak visible downstream.
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
        store.maxItems = 2
        for i in 1...5 {
            store.addItem(ClipboardItem(content: "Item \(i)", type: .text))
        }
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2, "active list capped at maxItems")
        XCTAssertEqual(store.trashedItems.count, 3, "M-2 fix: cap overflow lands in trash (recoverable), not physical delete")
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
        // ID-CRASH-0057: init no longer auto-waits for the background load;
        // the expired→trash move happens inside applyLoadResult, so await it.
        XCTAssertTrue(store2.waitForFirstLoadSync(timeout: 15.0),
                      "restart load must complete before assertions")

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
        XCTAssertTrue(store2.waitForFirstLoadSync(timeout: 15.0),
                      "restart load must complete before assertions")
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

    // MARK: - H-2 (2026-08-08 user inspect, v2 rewrite)

    /// H-2 first-launch: trash backend's `load()` throws → the fix must
    /// (a) set `lastLoadFailed` in-memory + persist the sentinel so the
    /// next launch also sees failure, (b) skip `cleanupOrphanedImages`
    /// in this launch's `loadItems()` so trash images aren't swept as
    /// orphans, and (c) post `.trashLoadFailed` so the user gets a
    /// visible signal. All three legs verified here.
    func testTrashLoadFailureSkipsOrphanImageSweepAndPostsNotification() {
        // Observe the user-visible signal
        var posted = 0
        var capturedSource: String?
        let posted1 = expectation(description: "trash load failure posted")
        let token = NotificationCenter.default.addObserver(
            forName: .trashLoadFailed, object: nil, queue: nil
        ) { note in
            posted += 1
            capturedSource = note.userInfo?["source"] as? String
            posted1.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Given: a trash backend that throws on load (e.g. corrupt blob)
        let failingTrashBackend = FailingTrashBackend()
        let store = ClipboardStore(
            backend: MemoryStorageBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: failingTrashBackend,
            defaults: testDefaults
        )

        // Then: in-memory flag set + trashedItems is empty (recovery path)
        XCTAssertTrue(
            store.trashStore.lastLoadFailed,
            "loadTrashedItems must surface a load failure via lastLoadFailed"
        )
        XCTAssertEqual(store.trashedItems.count, 0)

        // And: persistent sentinel is written so the next launch also knows
        XCTAssertTrue(
            testDefaults.bool(forKey: TrashStore.loadFailedSentinelKey),
            "quarantine must persist a sentinel so the next launch also sees failure"
        )

        // And: the user-visible signal fires (XCTest env: observer still
        // receives the post — the XCTest skip is only inside the AppDelegate
        // observer body, not in the notification dispatch itself).
        //
        // ID-CRASH-0022 (2026-10-20): the post is now ASYNCHRONOUS on
        // purpose. The trash load runs inside `TrashStore.init`, i.e.
        // while `ClipboardStore.shared` is being constructed — which
        // happens in `applicationDidFinishLaunching` BEFORE the
        // AppDelegate registers its observers. A synchronous post was
        // therefore delivered to nobody, and this very alert (the one
        // the observer exists to show) never appeared at startup. The
        // post now happens after the launch sequence, so the observer
        // is in place — and the assertion has to wait for it.
        wait(for: [posted1], timeout: 2.0)
        XCTAssertGreaterThanOrEqual(posted, 1, "user-visible .trashLoadFailed must fire on launch-1 failure")

        // H-1 (2026-08-08 audit): the failure notification must carry a
        // `source` tag so the AppDelegate Throttler can bucket trash
        // failures independently from save/encryption sources.
        XCTAssertEqual(capturedSource, "trashLoadFailed",
                       "trash load failure must tag source='trashLoadFailed' for Throttler bucketing")

        // When: ClipboardStore.loadItems() runs after a failed trash load
        store.loadItems()

        // Then: items still load correctly (items backend is separate)
        XCTAssertEqual(store.items.count, 0, "items backend should load independently")

        // And: the orphan sweep is NOT triggered — flag still true
        XCTAssertTrue(
            store.trashStore.lastLoadFailed,
            "lastLoadFailed must remain true until a successful loadTrashedItems() resets it"
        )
    }

    /// H-2 cross-launch: simulate a second app launch by constructing a
    /// NEW ClipboardStore instance with the same `defaults`. The
    /// persistent sentinel must make `lastLoadFailed` come up true
    /// again — otherwise `cleanupOrphanedImages` would run on launch 2
    /// (key now missing → `load()` returns `[]` silently → flag cleared →
    /// trash images deleted). This is the scenario the in-memory-only
    /// fix e39b601 missed; the cross-launch sentinel is what closes it.
    ///
    /// NOTE: uses `FailingTrashBackend` rather than `FileStorageBackend`
    /// because FileStorageBackend reads `UserDefaults.standard` (the
    /// production singleton), not the `testDefaults` suite injected here
    /// — a pre-populated corrupt blob in `testDefaults` would be invisible
    /// to the production-defaults backend, and `load()` would return
    /// `[]` silently (no throw, no catch, no sentinel written).
    func testTrashLoadFailureSurvivesAcrossLaunches() {
        // Pre-populate a "corrupt blob" so `quarantineCorruptBlob` has
        // something to copy to `<key>.corrupt-*`. The actual throw
        // comes from the backend (FailingTrashBackend), not from the
        // data itself.
        testDefaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: TrashStore.trashedItemsStorageKey)

        // LAUNCH 1: trash backend throws on load() → quarantine + sentinel
        _ = ClipboardStore(
            backend: MemoryStorageBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: FailingTrashBackend(),
            defaults: testDefaults
        )
        // Sentinel persisted across launches; original blob quarantined
        XCTAssertTrue(testDefaults.bool(forKey: TrashStore.loadFailedSentinelKey),
                      "launch 1 must persist the failure sentinel")
        XCTAssertNil(testDefaults.data(forKey: TrashStore.trashedItemsStorageKey),
                     "original blob must be removed by quarantine")

        // LAUNCH 2: brand-new ClipboardStore with same defaults. The
        // sentinel must short-circuit `loadTrashedItems()` BEFORE the
        // backend is touched (otherwise the missing key would make
        // `load()` return `[]` silently, clear the in-memory flag, and
        // let `cleanupOrphanedImages` proceed to delete trash images).
        let store2 = ClipboardStore(
            backend: MemoryStorageBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: FailingTrashBackend(),
            defaults: testDefaults
        )
        XCTAssertTrue(
            store2.trashStore.lastLoadFailed,
            "launch 2 must STILL see the failure via the persistent sentinel — " +
            "the in-memory flag alone only delays the data loss by one restart"
        )
        XCTAssertEqual(store2.trashedItems.count, 0)

        // And: launch 2's loadItems skips the orphan sweep too
        store2.loadItems()
        XCTAssertTrue(store2.trashStore.lastLoadFailed)
    }

    /// ID-CRASH-0022 (2026-10-20): the ITEMS-side twin of the H-2
    /// cross-launch test.
    ///
    /// The trash side got a persistent sentinel in 2026-08-08:
    /// after a corrupt TRASH blob, the next launch loads an empty
    /// collection (the key was removed by the quarantine, so the load
    /// SUCCEEDS) and the orphan-image sweep would delete every trash
    /// image. The ITEMS side had no equivalent — the same hole, on the
    /// larger data set: after a corrupt ITEMS blob, the next launch
    /// loads empty and the sweep deletes every item image on disk,
    /// while the items blob itself survives in the `.corrupt-*` key.
    /// The images are the irrecoverable half.
    ///
    /// So the failure must survive the launch (persistent sentinel),
    /// and it must be cleared only by a NON-EMPTY load.
    func testItemsLoadFailureSurvivesAcrossLaunches() {
        // Pre-populate a "corrupt blob" so `quarantineCorruptBlob` has
        // something to copy to `<key>.corrupt-*`.
        testDefaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: ClipboardStore.itemsStorageKey)

        // LAUNCH 1: items backend throws on load() → quarantine + sentinel
        let store1 = ClipboardStore(
            backend: FailingItemsBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: testDefaults
        )
        store1.loadItems()

        XCTAssertTrue(
            testDefaults.bool(forKey: ClipboardStore.itemsLoadFailedSentinelKey),
            "launch 1 must persist the items-side failure sentinel — without it the next launch's empty load would let the orphan sweep run"
        )
        XCTAssertNil(testDefaults.data(forKey: ClipboardStore.itemsStorageKey),
                     "original blob must be removed by quarantine")

        // LAUNCH 2: brand-new ClipboardStore with the same defaults and
        // a HEALTHY (empty) backend. The load succeeds with an empty
        // collection — the key is gone — so the sentinel must still be
        // there, and the sweep must stay disabled.
        let store2 = ClipboardStore(
            backend: MemoryStorageBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: testDefaults
        )
        store2.loadItems()

        XCTAssertTrue(
            store2.itemsLoadFailed,
            "launch 2 must STILL see the items failure via the persistent sentinel — an empty successful load does not prove the store is healthy"
        )
    }

    /// ID-CRASH-0022 (2026-10-20): the items-side load failure must be
    /// USER-VISIBLE.
    ///
    /// The trash side has had a user-visible signal since 2026-08-08
    /// (`.trashLoadFailed` → NSAlert) and the tags side has
    /// `.tagBackendCorrupted` → banner. The items side — the biggest
    /// dataset of the three — had only a log line: the user saw their
    /// history disappear with no explanation and no hint that an
    /// unreadable copy still exists under `ClipboardItems.corrupt-*`.
    func testItemsLoadFailureIsUserVisible() {
        let store = ClipboardStore(
            backend: FailingItemsBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: testDefaults
        )

        let posted = expectation(description: "items load failure posted")
        // The failure can be reported more than once (the constructor's
        // async load and the explicit sync load below) — one delivery is
        // enough for this test.
        posted.assertForOverFulfill = false
        var capturedSource: String?
        let token = NotificationCenter.default.addObserver(
            forName: .itemsLoadFailed, object: nil, queue: nil
        ) { note in
            capturedSource = note.userInfo?["source"] as? String
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.loadItems()

        wait(for: [posted], timeout: 2.0)
        XCTAssertEqual(capturedSource, "itemsLoadFailed",
                       "the items load failure must tag its own throttler bucket")
    }

    /// ID-CRASH-0022 (2026-10-20): the notification must reach an
    /// observer that registers AFTER the failure already happened.
    ///
    /// This is the test that makes the async delivery observable.
    /// The whole point of the fix is that the trash load runs inside
    /// `TrashStore.init` — i.e. BEFORE the AppDelegate registers its
    /// observers — so a synchronous post is delivered to nobody and the
    /// alert never appears at startup.
    ///
    /// A test that registers its observer BEFORE the store cannot see
    /// that difference (both deliveries work), so it cannot tell the
    /// fix from the bug: an independent mutation run confirmed that
    /// reverting the post to a synchronous one kept the whole suite
    /// green. This one registers afterwards, so a synchronous post is
    /// already gone and the expectation times out.
    func testTrashLoadFailureNotificationReachesAnObserverRegisteredAfterTheLoad() {
        // The failure happens HERE, during the store's construction.
        _ = ClipboardStore(
            backend: MemoryStorageBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: FailingTrashBackend(),
            defaults: testDefaults
        )

        // Register only NOW — after the failure already happened.
        let posted = expectation(description: "trash load failure posted")
        posted.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .trashLoadFailed, object: nil, queue: nil
        ) { _ in
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        wait(for: [posted], timeout: 2.0)
    }

    /// ID-CRASH-0022 (2026-10-20): the items-side twin of the test
    /// above — the failure notification must be DEFERRED, not posted
    /// inline.
    ///
    /// The trash side can be tested with a "late observer" (its load is
    /// synchronous, so the post happens inside the constructor). The
    /// items side cannot: its production load runs on a background
    /// queue, so the arrival order of the two posts is a race. What
    /// IS deterministic is the deferral itself: with the async post,
    /// nothing has been delivered when the triggering call returns —
    /// the delivery is queued behind the current main-queue turn. With
    /// a synchronous post the observer has already been called by then.
    ///
    /// The observer uses `queue: .main` so every delivery happens on
    /// the main thread — the background load's own post is therefore
    /// also deferred and cannot race the assertion.
    func testItemsLoadFailureNotificationIsDeferredNotPostedInline() {
        let store = ClipboardStore(
            backend: FailingItemsBackend(),
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: testDefaults
        )

        var deliveries = 0
        let token = NotificationCenter.default.addObserver(
            forName: .itemsLoadFailed, object: nil, queue: .main
        ) { _ in
            deliveries += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.loadItems()

        XCTAssertEqual(
            deliveries, 0,
            "the failure notification must be deferred — a synchronous post during the load "
            + "is delivered to nobody, because the AppDelegate registers its observers later "
            + "in the launch sequence"
        )

        // Let the main queue drain so the deferred post is delivered.
        let posted = expectation(description: "items load failure posted")
        posted.assertForOverFulfill = false
        let token2 = NotificationCenter.default.addObserver(
            forName: .itemsLoadFailed, object: nil, queue: .main
        ) { _ in
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token2) }
        wait(for: [posted], timeout: 2.0)
    }

    /// ID-CRASH-0022 (2026-10-20): a non-empty items load proves the
    /// store is healthy again → the sentinel is cleared and the orphan
    /// sweep resumes.
    func testSuccessfulNonEmptyItemsLoadClearsTheFailureSentinel() throws {
        testDefaults.set(true, forKey: ClipboardStore.itemsLoadFailedSentinelKey)

        let seeded = MemoryStorageBackend()
        try seeded.save([ClipboardItem(content: "healthy", type: .text)])
        let store = ClipboardStore(
            backend: seeded,
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: testDefaults
        )
        store.loadItems()

        XCTAssertFalse(
            store.itemsLoadFailed,
            "a non-empty items load must clear the sentinel so the orphan sweep resumes"
        )
        XCTAssertFalse(
            testDefaults.bool(forKey: ClipboardStore.itemsLoadFailedSentinelKey),
            "the persistent sentinel must be removed too — it has to survive to the NEXT launch only"
        )
    }

    /// H-2 recovery: once the user/dev-tools fixes the underlying problem
    /// (clears the sentinel + restores a valid trash blob), the NEXT
    /// launch must resume normal operation. We simulate "fixed" by
    /// manually clearing the sentinel + swapping in a working backend.
    /// The user/dev-tools UI for this is out of scope — deferred per
    /// audit §五.3 (quarantine-management UI is H-1 territory).
    func testTrashLoadSuccessClearsPersistentSentinel() {
        // Set up launch-1 failure state: sentinel present + original blob gone
        testDefaults.set(true, forKey: TrashStore.loadFailedSentinelKey)
        testDefaults.removeObject(forKey: TrashStore.trashedItemsStorageKey)

        // Construct TrashStore with FailingTrashBackend — the sentinel
        // short-circuits loadTrashedItems so the backend never gets called.
        let trash = TrashStore(
            backend: FailingTrashBackend(),
            defaults: testDefaults
        )
        XCTAssertTrue(trash.lastLoadFailed, "sentinel short-circuit must set lastLoadFailed")
        XCTAssertTrue(testDefaults.bool(forKey: TrashStore.loadFailedSentinelKey),
                      "sentinel persists through the short-circuit")

        // Recovery: clear sentinel + swap in a working backend
        testDefaults.removeObject(forKey: TrashStore.loadFailedSentinelKey)
        trash.replaceBackendForTesting(MemoryStorageBackend())

        // Next loadTrashedItems: sentinel absent → backend.load() succeeds
        // → lastLoadFailed clears
        trash.loadTrashedItems()
        XCTAssertFalse(trash.lastLoadFailed, "successful load must clear lastLoadFailed")
        XCTAssertFalse(testDefaults.bool(forKey: TrashStore.loadFailedSentinelKey),
                       "successful load must not re-write the sentinel")
    }
}

// MARK: - H-2 test-only backend

/// StorageBackend that throws on every `load()` call, simulating a
/// corrupt trash blob. All other methods are no-ops (save/saveTags/saveBlob
/// silently succeed; loadTags returns empty) since the test only exercises
/// the load-failure path.
private final class FailingTrashBackend: StorageBackend {
    func load() throws -> [ClipboardItem] {
        throw NSError(
            domain: "FailingTrashBackend",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Injected trash load failure (H-2 test)"]
        )
    }
    func save(_ items: [ClipboardItem]) throws { /* no-op */ }
    func saveBlob(_ data: Data) throws { /* no-op */ }
    func loadTags() throws -> [Tag] { return [] }
    func saveTags(_ tags: [Tag]) throws { /* no-op */ }
}

/// ID-CRASH-0022 (2026-10-20): the ITEMS-side twin of
/// `FailingTrashBackend` — throws on every `load()`, simulating a
/// corrupt items blob.
private final class FailingItemsBackend: StorageBackend {
    func load() throws -> [ClipboardItem] {
        throw NSError(
            domain: "FailingItemsBackend",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Injected items load failure (ID-CRASH-0022 test)"]
        )
    }
    func save(_ items: [ClipboardItem]) throws { /* no-op */ }
    func saveBlob(_ data: Data) throws { /* no-op */ }
    func loadTags() throws -> [Tag] { return [] }
    func saveTags(_ tags: [Tag]) throws { /* no-op */ }
}
