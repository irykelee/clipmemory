import XCTest
@testable import ClipMemory

/// G.1: CRUD complete flow — addItem → persist → restart → recover
/// G.3: Deduplication logic verification (contentHash + plaintext fallback)
final class IntegrationTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
    }

    override func tearDown() {
        store = nil
        backend = nil
        super.tearDown()
    }

    // MARK: - G.1.1 Add and Persist

    func testAddItemPersistsInBackend() {
        let item = ClipboardItem(content: "Hello, World!", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].type, .text)
        XCTAssertTrue(store.items[0].isEncrypted)
        XCTAssertNotEqual(store.items[0].content, "Hello, World!")
    }

    func testAddItemEncryptsContent() {
        let item = ClipboardItem(content: "Secret text", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        // Stored content should be different from original (encrypted)
        let storedContent = store.items[0].content
        XCTAssertNotEqual(storedContent, "Secret text")
        // But decrypted should match
        let decrypted = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(decrypted, "Secret text")
    }

    // MARK: - G.1.2 Restart and Recover

    func testRestartRecoversItemsFromBackend() {
        // Add two items and flush to backend
        let item1 = ClipboardItem(content: "First", type: .text)
        let item2 = ClipboardItem(content: "Second", type: .link)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)

        // Simulate restart: new store with same backend
        let store2 = ClipboardStore(backend: backend)

        // Items should be recovered
        XCTAssertEqual(store2.items.count, 2)
        // Verify by decrypting both
        let d1 = store2.getDecryptedContent(store2.items[0])
        let d2 = store2.getDecryptedContent(store2.items[1])
        XCTAssertTrue(d1 == "Second" || d1 == "First")
        XCTAssertTrue(d2 == "Second" || d2 == "First")
    }

    func testRestartPreservesItemMetadata() {
        let pastDate = Date(timeIntervalSince1970: 1_000_000)
        let item = ClipboardItem(
            content: "Persistent item",
            type: .text,
            createdAt: pastDate,
            isPinned: true
        )
        store.addItem(item)
        store.flushPendingSaves()

        // Simulate restart
        let store2 = ClipboardStore(backend: backend)

        XCTAssertEqual(store2.items.count, 1)
        XCTAssertEqual(store2.items[0].isPinned, true)
        XCTAssertEqual(store2.pinnedItems.count, 1)
    }

    // MARK: - G.1.3 Delete

    func testDeleteItemRemovesFromBackend() {
        let item1 = ClipboardItem(content: "To keep", type: .text)
        let item2 = ClipboardItem(content: "To delete", type: .text)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)

        store.deleteItem(store.items[1])
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
    }

    func testDeleteItemPersistsAfterRestart() {
        let item = ClipboardItem(content: "Will be deleted", type: .text)
        store.addItem(item)
        store.flushPendingSaves()
        store.deleteItem(store.items[0])
        store.flushPendingSaves()

        let store2 = ClipboardStore(backend: backend)
        XCTAssertEqual(store2.items.count, 0)
    }

    // MARK: - G.1.4 Update (Toggle Pin)

    func testTogglePinUpdatesAndPersists() {
        let item = ClipboardItem(content: "Pinnable", type: .text, isPinned: false)
        store.addItem(item)
        store.flushPendingSaves()

        XCTAssertFalse(store.items[0].isPinned)
        XCTAssertEqual(store.pinnedItems.count, 0)

        store.togglePin(store.items[0])
        store.flushPendingSaves()

        XCTAssertTrue(store.items[0].isPinned)
        XCTAssertEqual(store.pinnedItems.count, 1)

        // Restart and verify
        let store2 = ClipboardStore(backend: backend)
        XCTAssertTrue(store2.items[0].isPinned)
        XCTAssertEqual(store2.pinnedItems.count, 1)
    }

    // MARK: - G.1.5 Clear All

    func testClearAllRemovesNonPinnedItems() {
        let item1 = ClipboardItem(content: "Normal", type: .text, isPinned: false)
        let item2 = ClipboardItem(content: "Pinned", type: .text, isPinned: true)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        store.clearAllItems()
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].isPinned)
    }

    // MARK: - G.1.6 Trim to maxItems

    func testTrimToMaxItemsRemovesOldest() {
        let customBackend = MemoryStorageBackend()
        let customStore = ClipboardStore(backend: customBackend)
        customStore.maxItems = 3

        for i in 1...5 {
            let item = ClipboardItem(content: "Item \(i)", type: .text)
            customStore.addItem(item)
        }
        customStore.flushPendingSaves()

        XCTAssertEqual(customStore.items.count, 3)
    }

    // MARK: - G.1.7 Restart clears expired items

    func testRestartFiltersExpiredItems() {
        let past = Date().addingTimeInterval(-3600)
        let item = ClipboardItem(content: "Expired", type: .text, expiresAt: past)
        store.addItem(item)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].isExpired)

        let store2 = ClipboardStore(backend: backend)
        XCTAssertEqual(store2.items.count, 0, "Expired items should be filtered on load")
    }

    // MARK: - G.3.1 Deduplication by contentHash

    func testDeduplicateSameContentMovesToTop() {
        let itemA = ClipboardItem(content: "Hello", type: .text)
        let itemB = ClipboardItem(content: "World", type: .text)

        store.addItem(itemA)
        store.addItem(itemB)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2)

        // Decrypt to check order: "World" should be at index 0 (added last)
        let decrypted0 = store.getDecryptedContent(store.items[0])
        let decrypted1 = store.getDecryptedContent(store.items[1])
        XCTAssertEqual(decrypted0, "World", "Most recently added should be at top")
        XCTAssertEqual(decrypted1, "Hello")

        // Add "Hello" again — should deduplicate (moved to top, "World" pushed down)
        let itemAAgain = ClipboardItem(content: "Hello", type: .text)
        store.addItem(itemAAgain)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2, "Duplicate should not create new item")

        // Now "Hello" should be at top again
        let deduped0 = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(deduped0, "Hello", "Deduplicated item should move to top")
    }

    func testDeduplicateByContentHash() {
        let item1 = ClipboardItem(content: "Same text", type: .text)
        let item2 = ClipboardItem(content: "Same text", type: .text)

        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1, "Same content should deduplicate")
    }

    // MARK: - G.3.2 Deduplication preserves pinned status

    func testDeduplicatePinnedItemStaysPinned() {
        let item1 = ClipboardItem(content: "Secret", type: .text, isPinned: true)
        store.addItem(item1)
        store.flushPendingSaves()

        let item2 = ClipboardItem(content: "Secret", type: .text, isPinned: false)
        store.addItem(item2)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].isPinned, "Pinned status should be preserved on deduplication")
    }

    // MARK: - G.3.3 Different content does not deduplicate

    func testDifferentContentDoesNotDeduplicate() {
        let item1 = ClipboardItem(content: "Hello", type: .text)
        let item2 = ClipboardItem(content: "Hello!", type: .text)  // Note: extra !
        let item3 = ClipboardItem(content: "Hello", type: .link)   // Same text, different type

        store.addItem(item1)
        store.addItem(item2)
        store.addItem(item3)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 3)
    }

    // MARK: - G.3.4 Link vs Text deduplication

    func testLinkAndTextSameContentDoNotDeduplicate() {
        let item1 = ClipboardItem(content: "https://example.com", type: .link)
        let item2 = ClipboardItem(content: "https://example.com", type: .text)

        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2, "Different types should not deduplicate")
    }

    // MARK: - G.3.5 contentHash is computed correctly

    func testContentHashIsSetOnAddItem() {
        let item = ClipboardItem(content: "test", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        XCTAssertNotNil(store.items[0].contentHash, "contentHash should be computed")
        XCTAssertFalse(store.items[0].contentHash!.isEmpty)
    }

    // MARK: - G.3.6 Restart after deduplication still deduplicates

    func testRestartAfterDeduplicationStillDeduplicates() {
        let item1 = ClipboardItem(content: "Dedupe me", type: .text)
        let item2 = ClipboardItem(content: "Dedupe me", type: .text)
        store.addItem(item1)
        store.addItem(item2)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 1)

        // Restart
        let store2 = ClipboardStore(backend: backend)
        XCTAssertEqual(store2.items.count, 1)

        // Add same content again — should still deduplicate
        let item3 = ClipboardItem(content: "Dedupe me", type: .text)
        store2.addItem(item3)
        store2.flushPendingSaves()

        XCTAssertEqual(store2.items.count, 1, "Restarted store should still deduplicate correctly")
    }
}
