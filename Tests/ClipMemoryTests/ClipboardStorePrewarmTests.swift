import XCTest
@testable import ClipMemory

/// P0-3: prewarmDecryptionCache tests — verify background cache warming
/// populates contentCache + rtfPlaintextCache without blocking main thread.
@MainActor
final class ClipboardStorePrewarmTests: XCTestCase {

    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        // M12 (2026-08-01): per-test injected store — no reliance on
        // ClipboardStore.shared (fresh instance starts empty, so the prior
        // setUp/tearDown items/cache clearing is unnecessary).
        store = ClipboardStore(backend: MemoryStorageBackend())
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        store = nil
        super.tearDown()
    }

    // MARK: - Cache Population

    func testPrewarmPopulatesContentCache() {
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
        for i in 0..<50 {
            let item = ClipboardItem(content: "batch-\(i)", type: .text)
            store.addItem(item)
        }
        store.contentCache.removeAllObjects()

        // Pre-warm with cap = 5
        store.prewarmDecryptionCache(items: store.items, cap: 5)
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
        store.prewarmDecryptionCache(items: [])
        XCTAssertTrue(true, "prewarm with empty array must not crash")
    }

    // MARK: - OCR Cache

    func testPrewarmPopulatesOCRCacheForImageItems() {
        let crypto = CryptoService.shared

        guard let encryptedOCR = crypto.encrypt("ocr-text-in-image") else {
            XCTFail("failed to encrypt OCR payload")
            return
        }

        let imageItem = ClipboardItem(
            content: "image-file.png",
            type: .image,
            isEncrypted: true,
            ocrText: encryptedOCR,
            ocrAttempted: true
        )
        store.items.insert(imageItem, at: 0)
        store.contentCache.removeAllObjects()

        let ocrKey = (imageItem.id.uuidString + ".ocr") as NSString
        XCTAssertNil(store.contentCache.object(forKey: ocrKey), "OCR cache must be cold before prewarm")

        store.prewarmDecryptionCache(items: store.items)
        let exp = expectation(description: "prewarm completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertNotNil(store.contentCache.object(forKey: ocrKey),
                        "OCR cache must be populated after prewarm")
        XCTAssertEqual(store.contentCache.object(forKey: ocrKey) as? String,
                       "ocr-text-in-image", "cached OCR text must match")
    }

    // MARK: - ID-PERF-0019 (2026-08-01 audit): in-flight batch coalescing

    /// Rapid successive calls must not overlap independent background batches:
    /// the second call is coalesced as the pending "latest request" and
    /// drained as a follow-up round. Every completion fires exactly once,
    /// on the main thread.
    func testPrewarmCoalescesRapidSuccessiveCalls() {
        for i in 0..<10 {
            store.addItem(ClipboardItem(content: "coalesce-\(i)", type: .text))
        }
        store.contentCache.removeAllObjects()

        let lock = NSLock()
        var callsA = 0, callsB = 0
        var aOnMain = false, bOnMain = false

        // Call 1 sets prewarmInFlight synchronously (under lock) BEFORE
        // dispatching its batch, so call 2 — issued immediately after on the
        // same thread — deterministically takes the coalescing path (or, at
        // worst on an extremely fast machine, the all-cached early return;
        // the assertions hold either way).
        store.prewarmDecryptionCache(items: store.items) {
            lock.lock(); callsA += 1; aOnMain = Thread.isMainThread; lock.unlock()
        }
        store.prewarmDecryptionCache(items: store.items) {
            lock.lock(); callsB += 1; bOnMain = Thread.isMainThread; lock.unlock()
        }

        let exp = expectation(description: "coalesced rounds complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        lock.lock()
        XCTAssertEqual(callsA, 1, "first completion must fire exactly once")
        XCTAssertEqual(callsB, 1, "coalesced completion must fire exactly once")
        XCTAssertTrue(aOnMain, "first completion must fire on the main thread")
        XCTAssertTrue(bOnMain, "coalesced completion must fire on the main thread")
        lock.unlock()
        for item in store.items {
            XCTAssertNotNil(store.contentCache.object(forKey: item.id.uuidString as NSString),
                            "item must be cached after the coalesced rounds")
        }
    }

    /// The coalesced "latest request" must actually run: items that were only
    /// in the SECOND call's workingSet get decrypted by the follow-up round
    /// (not dropped because round 1 never saw them).
    func testPrewarmCoalescedFollowUpRoundDecryptsNewerItems() {
        var firstSet: [ClipboardItem] = []
        var secondSet: [ClipboardItem] = []
        for i in 0..<5 {
            firstSet.append(ClipboardItem(content: "round1-\(i)", type: .text))
            secondSet.append(ClipboardItem(content: "round2-\(i)", type: .text))
        }
        store.items = firstSet + secondSet
        store.contentCache.removeAllObjects()

        let doneB = expectation(description: "coalesced completion fired")
        store.prewarmDecryptionCache(items: firstSet)
        store.prewarmDecryptionCache(items: secondSet) { doneB.fulfill() }
        wait(for: [doneB], timeout: 5.0)

        // Cache writes happen before the completion hop, so by the time the
        // completion fired the follow-up round's results are visible.
        for item in secondSet {
            XCTAssertNotNil(store.contentCache.object(forKey: item.id.uuidString as NSString),
                            "follow-up round must decrypt the coalesced request's items")
        }
    }
}
