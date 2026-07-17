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

    // MARK: - G.4 Unpin operations

    func testUnpinAllRemovesAllPins() {
        let item1 = ClipboardItem(content: "A", type: .text, isPinned: true)
        let item2 = ClipboardItem(content: "B", type: .text, isPinned: true)
        let item3 = ClipboardItem(content: "C", type: .text, isPinned: false)
        store.addItem(item1); store.addItem(item2); store.addItem(item3)
        store.flushPendingSaves()
        XCTAssertEqual(store.pinnedItems.count, 2)

        store.unpinAll()
        store.flushPendingSaves()
        XCTAssertEqual(store.pinnedItems.count, 0)
        XCTAssertEqual(store.items.count, 3)
    }

    func testUnpinTodayOnlyAffectsTodayItems() throws {
        let cal = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: now))
        let todayItem = ClipboardItem(content: "Today pinned", type: .text, createdAt: now, isPinned: true)
        let yesterdayItem = ClipboardItem(content: "Yesterday pinned", type: .text, createdAt: yesterday, isPinned: true)
        store.addItem(todayItem); store.addItem(yesterdayItem)
        store.flushPendingSaves()
        XCTAssertEqual(store.pinnedItems.count, 2)

        store.unpinToday()
        store.flushPendingSaves()
        XCTAssertEqual(store.pinnedItems.count, 1)
    }

    func testUnpinYesterdayOnlyAffectsYesterdayItems() throws {
        let cal = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: now))
        let todayItem = ClipboardItem(content: "Today", type: .text, createdAt: now, isPinned: true)
        let yesterdayItem = ClipboardItem(content: "Yesterday", type: .text, createdAt: yesterday, isPinned: true)
        store.addItem(todayItem); store.addItem(yesterdayItem)
        store.flushPendingSaves()

        store.unpinYesterday()
        store.flushPendingSaves()
        XCTAssertEqual(store.pinnedItems.count, 1)
    }

    func testUnpinOlderOnlyAffectsOlderItems() throws {
        let cal = Calendar.current
        let now = Date()
        let twoDaysAgo = try XCTUnwrap(cal.date(byAdding: .day, value: -2, to: now))
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: now))
        let olderItem = ClipboardItem(content: "Older", type: .text, createdAt: twoDaysAgo, isPinned: true)
        let yesterdayItem = ClipboardItem(content: "Yesterday", type: .text, createdAt: yesterday, isPinned: true)
        store.addItem(olderItem); store.addItem(yesterdayItem)
        store.flushPendingSaves()

        store.unpinOlder()
        store.flushPendingSaves()
        XCTAssertEqual(store.pinnedItems.count, 1)
    }

    func testUnpinWithNoPinnedItemsDoesNothing() {
        let item = ClipboardItem(content: "No pin", type: .text, isPinned: false)
        store.addItem(item)
        store.flushPendingSaves()

        store.unpinAll()
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.pinnedItems.count, 0)
    }

    // MARK: - G.5 Clear group operations

    func testClearTodayRemovesNonPinnedTodayItems() throws {
        let cal = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: now))
        let todayItem = ClipboardItem(content: "Today", type: .text, createdAt: now)
        let yesterdayItem = ClipboardItem(content: "Yesterday", type: .text, createdAt: yesterday)
        store.addItem(todayItem); store.addItem(yesterdayItem)
        store.flushPendingSaves()

        store.clearToday()
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)
        let d = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(d, "Yesterday")
    }

    func testClearYesterdayRemovesNonPinnedYesterdayItems() throws {
        let cal = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: now))
        let todayItem = ClipboardItem(content: "Today", type: .text, createdAt: now)
        let yesterdayItem = ClipboardItem(content: "Yesterday", type: .text, createdAt: yesterday)
        store.addItem(todayItem); store.addItem(yesterdayItem)
        store.flushPendingSaves()

        store.clearYesterday()
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)
        let d = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(d, "Today")
    }

    func testClearOlderRemovesNonPinnedOlderItems() throws {
        let cal = Calendar.current
        let now = Date()
        let twoDaysAgo = try XCTUnwrap(cal.date(byAdding: .day, value: -2, to: now))
        let olderItem = ClipboardItem(content: "Old", type: .text, createdAt: twoDaysAgo)
        let yesterdayItem = ClipboardItem(content: "Recent", type: .text, createdAt: now)
        store.addItem(olderItem); store.addItem(yesterdayItem)
        store.flushPendingSaves()

        store.clearOlder()
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)
        let d = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(d, "Recent")
    }

    func testClearGroupRespectsPinnedItems() throws {
        let cal = Calendar.current
        let now = Date()
        let pinnedToday = ClipboardItem(content: "Pinned", type: .text, createdAt: now, isPinned: true)
        let normalToday = ClipboardItem(content: "Normal", type: .text, createdAt: now, isPinned: false)
        store.addItem(pinnedToday); store.addItem(normalToday)
        store.flushPendingSaves()

        store.clearToday()
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].isPinned)
    }

    func testClearGroupOnEmptyStoreDoesNotCrash() {
        store.clearToday()
        store.clearYesterday()
        store.clearOlder()
        XCTAssertEqual(store.items.count, 0)
    }

    // MARK: - G.6 Edge cases: unpin after clear, clear after unpin

    func testUnpinThenClearRemovesExpectedItems() throws {
        let cal = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: now))
        let todayItem = ClipboardItem(content: "Today", type: .text, createdAt: now, isPinned: true)
        let yesterdayItem = ClipboardItem(content: "Yesterday", type: .text, createdAt: yesterday)
        store.addItem(todayItem); store.addItem(yesterdayItem)
        store.flushPendingSaves()

        store.unpinToday()
        store.flushPendingSaves()
        store.clearToday()
        store.flushPendingSaves()
        XCTAssertEqual(store.items.count, 1)
        let d = store.getDecryptedContent(store.items[0])
        XCTAssertEqual(d, "Yesterday")
    }

    // MARK: - G.7 Excluded bundle IDs parsing

    func testDefaultExcludedAppsLoaded() {
        let defaultStr = store.excludedBundleIdsString
        XCTAssertTrue(defaultStr.contains("com.1password.1password"))
        XCTAssertTrue(defaultStr.contains("com.bitwarden.desktop"))
    }

    func testExcludedAppsListCanBeParsed() {
        let ids = store.excludedBundleIdsString
            .split(separator: ",")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(ids.isEmpty)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
    }

    // MARK: - G.8 Language switching

    func testLanguageManagerAvailableLanguages() {
        let mgr = LanguageManager.shared
        XCTAssertFalse(mgr.availableLanguages.isEmpty)
        XCTAssertTrue(mgr.availableLanguages.contains { $0.code == "en" })
        XCTAssertTrue(mgr.availableLanguages.contains { $0.code == "zh-Hans" })
    }

    func testLanguageManagerCanChangeAndRevert() {
        let mgr = LanguageManager.shared
        let original = mgr.selectedLanguage

        mgr.selectedLanguage = "en"
        XCTAssertEqual(mgr.selectedLanguage, "en")

        mgr.selectedLanguage = original
        XCTAssertEqual(mgr.selectedLanguage, original)
    }

    // MARK: - G.9 Group counts (todayCount / yesterdayCount / olderCount)

    func testGroupCountsClassifyItemsByCreatedAt() {
        // G.9.1: All three buckets populated; pinned items excluded from counts.
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let now = Date()
        let yesterdayMid = startOfToday.addingTimeInterval(-3600)         // 1h into yesterday
        let olderMid = startOfToday.addingTimeInterval(-2 * 24 * 3600)     // 2 days ago

        let todayItem = ClipboardItem(content: "today-text", type: .text, createdAt: now)
        let yesterdayItem = ClipboardItem(content: "yest-text", type: .text, createdAt: yesterdayMid)
        let olderItem = ClipboardItem(content: "older-text", type: .text, createdAt: olderMid)
        let pinnedToday = ClipboardItem(content: "pinned-today", type: .text, createdAt: now, isPinned: true)

        store.addItem(todayItem)
        store.addItem(yesterdayItem)
        store.addItem(olderItem)
        store.addItem(pinnedToday)
        store.flushPendingSaves()

        XCTAssertEqual(store.todayCount, 1, "Only non-pinned 'today' should count")
        XCTAssertEqual(store.yesterdayCount, 1, "Only 'yesterday' window should count")
        XCTAssertEqual(store.olderCount, 1, "Items older than yesterday go here")
        XCTAssertEqual(store.pinnedItems.count, 1, "Pinned item should still appear in pinnedItems")
        XCTAssertEqual(store.items.count, 4, "All items still in store (groupCounts is a view, not a filter)")
    }

    func testGroupCountsAreZeroForEmptyStore() {
        // G.9.2: Edge case — no items means all counts are 0 (regression guard for nil-deref).
        XCTAssertEqual(store.todayCount, 0)
        XCTAssertEqual(store.yesterdayCount, 0)
        XCTAssertEqual(store.olderCount, 0)
    }

    // MARK: - G.10 clearSensitiveItems

    func testClearSensitiveItemsRemovesOnlyNonPinnedSensitive() {
        // G.10.1: clearSensitiveItems must:
        //   - Remove non-pinned sensitive items
        //   - Preserve pinned sensitive items
        //   - Preserve non-sensitive items (regardless of pinned status)
        let sensitiveNormal = ClipboardItem(content: "secret-token", type: .text, isPinned: false, isSensitive: true)
        let sensitivePinned = ClipboardItem(content: "pinned-secret", type: .text, isPinned: true, isSensitive: true)
        let normalText = ClipboardItem(content: "harmless", type: .text, isPinned: false, isSensitive: false)

        store.addItem(sensitiveNormal)
        store.addItem(sensitivePinned)
        store.addItem(normalText)
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 3)

        store.clearSensitiveItems()
        store.flushPendingSaves()

        XCTAssertEqual(store.items.count, 2, "Only the non-pinned sensitive item should be removed")
        let remainingIds = Set(store.items.map { $0.id })
        XCTAssertTrue(remainingIds.contains(sensitivePinned.id), "Pinned sensitive should be kept")
        XCTAssertTrue(remainingIds.contains(normalText.id), "Non-sensitive should be kept")
        XCTAssertFalse(remainingIds.contains(sensitiveNormal.id), "Non-pinned sensitive should be removed")
        XCTAssertEqual(store.pinnedItems.count, 1)
    }

    func testClearSensitiveItemsOnEmptyStoreIsNoOp() {
        // G.10.2: Edge case — no items means nothing to clear, no crash.
        store.clearSensitiveItems()
        XCTAssertEqual(store.items.count, 0)
    }

    // MARK: - G.11 isDecryptionFailed memoization (performance regression guard)

    func testIsDecryptionFailedSetsFlagOnFirstFailure() {
        // G.11.1: When getDecryptedContent returns nil for an encrypted item,
        // the item stored in the store must get decryptionFailed = true so
        // subsequent isDecryptionFailed reads are O(1) (no re-decryption).
        // Setup: backend pre-populated with a corrupt encrypted item
        let corrupt = ClipboardItem(
            id: UUID(),
            content: "v2-not-a-real-encrypted-blob-AAAAAAAAAAAAAAAAAAAA",
            type: .text,
            isEncrypted: true
        )
        let backendWithCorrupt = MemoryStorageBackend(items: [corrupt])
        let storeWithCorrupt = ClipboardStore(backend: backendWithCorrupt)
        storeWithCorrupt.loadItems()

        // Sanity: corrupt item loaded
        XCTAssertEqual(storeWithCorrupt.items.count, 1)
        XCTAssertFalse(storeWithCorrupt.items[0].isDecryptionFailed,
                      "Sanity: flag is false before any decrypt attempt")

        // First (and only) decrypt attempt should fail
        let result = storeWithCorrupt.getDecryptedContent(corrupt)
        XCTAssertNil(result, "Corrupt blob must fail decryption")

        // The flag must be set on the in-store copy of the item
        let storedItem = storeWithCorrupt.items.first(where: { $0.id == corrupt.id })
        XCTAssertNotNil(storedItem)
        XCTAssertTrue(storedItem?.isDecryptionFailed == true,
                     "After getDecryptedContent returns nil, the stored item must have decryptionFailed = true")
    }

    func testIsDecryptionFailedIsFalseForUnencryptedItems() {
        // G.11.2: Unencrypted items are not "decryption failed" — the field
        // applies only to items that were encrypted and cannot be decrypted.
        let plaintext = ClipboardItem(
            content: "not-encrypted",
            type: .text,
            isEncrypted: false
        )
        XCTAssertFalse(plaintext.isDecryptionFailed)
    }

    func testIsDecryptionFailedIsFalseForValidlyEncryptedItems() {
        // G.11.3: A successfully-decryptable item must NOT have the flag set.
        // (Verifies the flag is only set on actual failure, not on success.)
        let item = ClipboardItem(content: "valid", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        let stored = store.items[0]
        _ = store.getDecryptedContent(stored)
        XCTAssertFalse(stored.isDecryptionFailed,
                      "Successfully-decrypted items must not be flagged as failed")
    }

    // MARK: - G.12 dedup must not reset decryptionFailed flag (HIGH-1 regression)

    func testDedupDoesNotResetDecryptionFailedFlag() {
        // G.12.1: When addItem triggers a dedup hit on an item that already has
        // decryptionFailed = true (corrupt blob), the rebuild at ClipboardStore.swift
        // line 315-325 must preserve the flag. Otherwise the a00da7c perf fix is
        // silently undone every time the same content is re-copied.
        //
        // Setup: pre-populated backend with a corrupt encrypted item
        let corrupt = ClipboardItem(
            id: UUID(),
            content: "v2-not-a-real-encrypted-blob-AAAAAAAAAAAAAAAAAAAA",
            type: .text,
            isEncrypted: true
        )
        let backend = MemoryStorageBackend(items: [corrupt])
        let dedupStore = ClipboardStore(backend: backend)
        dedupStore.loadItems()

        // Sanity: corrupt item loaded, flag is initially false
        XCTAssertEqual(dedupStore.items.count, 1)
        XCTAssertFalse(dedupStore.items[0].isDecryptionFailed,
                      "Sanity: flag is false before any decrypt attempt")

        // Trigger getDecryptedContent which sets decryptionFailed = true
        XCTAssertNil(dedupStore.getDecryptedContent(corrupt))
        XCTAssertTrue(dedupStore.items[0].decryptionFailed,
                     "Sanity: flag must be set after getDecryptedContent returns nil")

        // Re-add same plaintext — should hit dedup path (line 313)
        let newItem = ClipboardItem(
            content: "v2-not-a-real-encrypted-blob-AAAAAAAAAAAAAAAAAAAA",
            type: .text
        )
        dedupStore.addItem(newItem)
        dedupStore.flushPendingSaves()

        // The flag must SURVIVE the dedup rebuild
        let storedAfter = dedupStore.items.first(where: { $0.id == corrupt.id })
        XCTAssertNotNil(storedAfter, "Original corrupt item must still exist (dedup, not new insert)")
        XCTAssertTrue(storedAfter?.decryptionFailed == true,
                     "decryptionFailed flag must NOT be reset on dedup rebuild (regression: HIGH-1)")
    }

    // MARK: - Copy-to-clipboard preserves tagIds

    /// Copying an already-tagged item back to the clipboard calls moveToTop,
    /// which previously rebuilt the ClipboardItem without tagIds. The moved
    /// item must retain its tags (and the decryptionFailed flag).
    func testCopyToClipboardPreservesTagIds() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.addItem(ClipboardItem(content: "copy me", type: .text))
        guard let item = store.items.first else {
            XCTFail("Item should exist after addItem")
            return
        }
        store.addTag(to: item.id, tagId: tag.id)
        store.flushPendingSaves()

        store.copyToClipboard(item)
        store.flushPendingSaves()

        let moved = store.items.first { $0.id == item.id }
        XCTAssertNotNil(moved, "Original item should still exist after copy/moveToTop")
        XCTAssertEqual(moved?.tagIds, [tag.id], "tagIds must survive moveToTop")
    }
}
