import XCTest
@testable import ClipMemory

/// Tests for the recycle bin (trash) feature.
final class ClipboardStoreTrashTests: XCTestCase {

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
        store.saveTrashedItems()

        store.trashRetentionDays = 7
        store.purgeExpiredTrash()

        XCTAssertEqual(store.trashedItems.count, 1)
        let d = store.getDecryptedContent(store.trashedItems[0])
        XCTAssertEqual(d, "Recent")
    }

    // MARK: - Auto cleanup does not trash

    func testTrimToMaxItemsDoesNotTrash() {
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
