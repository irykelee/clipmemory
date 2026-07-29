import XCTest
@testable import ClipMemory

/// P0-3: prewarmDecryptionCache tests — verify background cache warming
/// populates contentCache + rtfPlaintextCache without blocking main thread.
@MainActor
final class ClipboardStorePrewarmTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        let store = ClipboardStore.shared
        store.items.removeAll()
        store.contentCache.removeAllObjects()
        store.diagnostics = .init()
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        let store = ClipboardStore.shared
        store.items.removeAll()
        store.contentCache.removeAllObjects()
        store.diagnostics = .init()
        super.tearDown()
    }

    // MARK: - Cache Population

    func testPrewarmPopulatesContentCache() {
        let store = ClipboardStore.shared
        for i in 0..<5 {
            let item = ClipboardItem(content: "prewarm-text-\(i)", type: .text)
            store.addItem(item)
        }
        store.contentCache.removeAllObjects()

        // Verify cache is cold
        let key = store.items[0].id.uuidString as NSString
        XCTAssertNil(store.contentCache.object(forKey: key), "cache must be cold before prewarm")

        // Pre-warm
        store.prewarmDecryptionCache(items: store.items)

        // Wait for background decrypt to complete
        let exp = expectation(description: "prewarm completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // Cache must be warm now
        XCTAssertNotNil(store.contentCache.object(forKey: key), "cache must be populated after prewarm")
    }

    func testPrewarmMakesGetDecryptedContentReturnCached() {
        let store = ClipboardStore.shared
        for i in 0..<5 {
            let item = ClipboardItem(content: "fast-path-\(i)", type: .text)
            store.addItem(item)
        }
        store.contentCache.removeAllObjects()

        // Pre-warm
        store.prewarmDecryptionCache(items: store.items)
        let exp = expectation(description: "prewarm completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // After pre-warm, getDecryptedContent returns cached value (no decrypt needed)
        for item in store.items {
            let result = store.getDecryptedContent(item)
            XCTAssertNotNil(result, "getDecryptedContent must return cached value after prewarm")
        }
    }

    // MARK: - Skip Already Cached

    func testPrewarmSkipsAlreadyCachedItems() {
        let store = ClipboardStore.shared
        for i in 0..<3 {
            let item = ClipboardItem(content: "skip-cached-\(i)", type: .text)
            store.addItem(item)
        }
        store.contentCache.removeAllObjects()

        // Manually warm one item by calling getDecryptedContent (sync decrypt)
        _ = store.getDecryptedContent(store.items[0])
        let cachedKey = store.items[0].id.uuidString as NSString
        XCTAssertNotNil(store.contentCache.object(forKey: cachedKey), "first item must be cached")

        // Pre-warm: should not re-decrypt the already-cached item (no side effects)
        store.prewarmDecryptionCache(items: store.items)
        let exp = expectation(description: "prewarm completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // All items should be cached now
        for item in store.items {
            let key = item.id.uuidString as NSString
            XCTAssertNotNil(store.contentCache.object(forKey: key), "all items must be cached after prewarm")
        }
    }

    // MARK: - Batch Size Cap

    func testPrewarmRespectsBatchSize() {
        let store = ClipboardStore.shared
        for i in 0..<50 {
            let item = ClipboardItem(content: "batch-\(i)", type: .text)
            store.addItem(item)
        }
        store.contentCache.removeAllObjects()

        // Pre-warm with cap = 5
        store.prewarmDecryptionCache(items: store.items, batchSize: 5)
        let exp = expectation(description: "prewarm completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // At most 5 items should be cached
        var cachedCount = 0
        for item in store.items {
            let key = item.id.uuidString as NSString
            if store.contentCache.object(forKey: key) != nil { cachedCount += 1 }
        }
        XCTAssertLessThanOrEqual(cachedCount, 5, "prewarm with batchSize=5 must cache at most 5 items")
        XCTAssertGreaterThan(cachedCount, 0, "prewarm must cache at least 1 item (cap > 0)")
    }

    // MARK: - Skip decryptionFailed

    func testPrewarmSkipsDecryptionFailedItems() {
        let store = ClipboardStore.shared
        // Add items normally
        for i in 0..<3 {
            let item = ClipboardItem(content: "df-skip-\(i)", type: .text)
            store.addItem(item)
        }
        store.contentCache.removeAllObjects()

        // Directly insert a decryptionFailed item into the items array
        let failedItem = ClipboardItem(
            content: "will-fail",
            type: .text,
            isEncrypted: true,
            decryptionFailed: true
        )
        store.items.insert(failedItem, at: 0)

        // Pre-warm
        store.prewarmDecryptionCache(items: store.items)
        let exp = expectation(description: "prewarm completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // decryptionFailed item must NOT be cached
        let failedKey = failedItem.id.uuidString as NSString
        XCTAssertNil(store.contentCache.object(forKey: failedKey),
                     "decryptionFailed item must not be pre-warmed")

        // Other items should be cached
        for item in store.items where item.id != failedItem.id {
            let key = item.id.uuidString as NSString
            XCTAssertNotNil(store.contentCache.object(forKey: key),
                           "non-failed item must be cached after prewarm")
        }
    }

    // MARK: - RTF Items (indirect verification — rtfPlaintextCache is private)

    func testPrewarmPopulatesRTFPlaintext() {
        let store = ClipboardStore.shared
        let rtfString = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Times;}}\n\\f0 Prewarm RTF\n}"
        guard let rtfData = rtfString.data(using: .utf8) else {
            XCTFail("failed to encode RTF")
            return
        }
        let rtfBase64 = rtfData.base64EncodedString()
        let item = ClipboardItem(content: rtfBase64, type: .richText)
        store.addItem(item)

        // Verify getRTFPlaintext works before prewarm (cold path, sync decrypt)
        let firstResult = store.getRTFPlaintext(store.items[0])
        XCTAssertEqual(firstResult, "Prewarm RTF", "getRTFPlaintext must return plaintext (cold)")

        // Pre-warm (should populate rtfPlaintextCache)
        store.prewarmDecryptionCache(items: store.items)
        let exp = expectation(description: "prewarm completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // After prewarm, getRTFPlaintext returns the same value (cache hit, fast path)
        let secondResult = store.getRTFPlaintext(store.items[0])
        XCTAssertEqual(secondResult, "Prewarm RTF", "getRTFPlaintext must return plaintext after prewarm")
    }

    // MARK: - Edge Cases

    func testPrewarmNoopWhenAllCached() {
        let store = ClipboardStore.shared
        for i in 0..<3 {
            let item = ClipboardItem(content: "noop-\(i)", type: .text)
            store.addItem(item)
        }
        // addItem triggers getDecryptedContent which populates contentCache

        // Pre-warm should be a no-op (no uncached items) — must not crash or hang
        store.prewarmDecryptionCache(items: store.items)
        XCTAssertTrue(true, "prewarm with all-cached must not crash")
    }

    func testPrewarmNoopWithEmptyItems() {
        let store = ClipboardStore.shared
        store.prewarmDecryptionCache(items: [])
        XCTAssertTrue(true, "prewarm with empty array must not crash")
    }
}
