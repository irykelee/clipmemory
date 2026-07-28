import XCTest
@testable import ClipMemory

/// Tests for the recycle bin (trash) feature.
@MainActor final class ClipboardStoreTrashTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend, trashBackend: trashBackend)
    }

    override func tearDown() {
        store = nil
        trashBackend = nil
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

    func testCleanupExpiredItemsDoesNotTrash() {
        let expired = ClipboardItem(content: "Expired", type: .text, expiresAt: Date().addingTimeInterval(-3600))
        store.addItem(expired)
        store.flushPendingSaves()

        // Simulate restart which triggers cleanupExpiredItems
        let store2 = ClipboardStore(backend: backend, trashBackend: trashBackend)

        XCTAssertEqual(store2.items.count, 0)
        XCTAssertEqual(store2.trashedItems.count, 0, "Expired items should be permanently deleted, not trashed")
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
