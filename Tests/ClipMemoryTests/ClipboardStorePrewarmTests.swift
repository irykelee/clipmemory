import XCTest
@testable import ClipMemory

/// P0-3: prewarmDecryptionCache tests — verify background cache warming
/// populates contentCache + rtfPlaintextCache without blocking main thread.
@MainActor
final class ClipboardStorePrewarmTests: XCTestCase {

    private var store: ClipboardStore!

    /// ID-REVIEW-1037 (2026-10-26): the per-test settings suite.
    ///
    /// `ClipboardStore(backend:)` leaves `defaults` at its default value —
    /// `ClipboardStore.xcTestDefaults`, i.e. the PROCESS-SHARED
    /// `ClipboardStore-XCTest-isolation` suite. The memory backend keeps the
    /// BLOBS out of it, but the store's SETTINGS still go there — e.g. the
    /// image-integrity scan persists its mtime cache
    /// (`ImageIntegrity.scannedMtimes`), which the write guard named in
    /// five tests here. Injecting a per-test suite keeps the settings
    /// out of the shared suite.
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        // M12 (2026-08-01): per-test injected store — no reliance on
        // ClipboardStore.shared (fresh instance starts empty, so the prior
        // setUp/tearDown items/cache clearing is unnecessary).
        testDefaults = makeTestDefaults()
        store = ClipboardStore(backend: MemoryStorageBackend(), defaults: testDefaults)
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        store = nil
        if let suite = testDefaults {
            removeTestDefaults(suite)
            testDefaults = nil
        }
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
        // ID-FLAKE-0005 (2026-10-23): await the completion callback instead
        // of sleeping a fixed 0.5s. The sleep had NO margin over the
        // background decrypt, so under load the assertion below read a cold
        // cache. The completion fires after `group.wait()` — i.e. once every
        // decrypt of the batch has landed — which is precisely the state
        // these tests assert on.
        let exp = expectation(description: "prewarm completes")
        store.prewarmDecryptionCache(items: store.items) { exp.fulfill() }
        wait(for: [exp], timeout: 10.0)

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
        // ID-FLAKE-0005 (2026-10-23): await the completion callback instead
        // of sleeping a fixed 0.5s. The sleep had NO margin over the
        // background decrypt, so under load the assertion below read a cold
        // cache. The completion fires after `group.wait()` — i.e. once every
        // decrypt of the batch has landed — which is precisely the state
        // these tests assert on.
        let exp = expectation(description: "prewarm completes")
        store.prewarmDecryptionCache(items: store.items) { exp.fulfill() }
        wait(for: [exp], timeout: 10.0)

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
        // ID-FLAKE-0005 (2026-10-23): await the completion callback instead
        // of sleeping a fixed 0.5s. The sleep had NO margin over the
        // background decrypt, so under load the assertion below read a cold
        // cache. The completion fires after `group.wait()` — i.e. once every
        // decrypt of the batch has landed — which is precisely the state
        // these tests assert on.
        let exp = expectation(description: "prewarm completes")
        store.prewarmDecryptionCache(items: store.items) { exp.fulfill() }
        wait(for: [exp], timeout: 10.0)

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
        // ID-FLAKE-0005 (2026-10-23): await the completion callback instead
        // of sleeping a fixed 0.5s. The sleep had NO margin over the
        // background decrypt, so under load the assertion below read a cold
        // cache. The completion fires after `group.wait()` — i.e. once every
        // decrypt of the batch has landed — which is precisely the state
        // these tests assert on.
        let exp = expectation(description: "prewarm completes")
        store.prewarmDecryptionCache(items: store.items, cap: 5) { exp.fulfill() }
        wait(for: [exp], timeout: 10.0)

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
        // ID-FLAKE-0005 (2026-10-23): await the completion callback instead
        // of sleeping a fixed 0.5s. The sleep had NO margin over the
        // background decrypt, so under load the assertion below read a cold
        // cache. The completion fires after `group.wait()` — i.e. once every
        // decrypt of the batch has landed — which is precisely the state
        // these tests assert on.
        let exp = expectation(description: "prewarm completes")
        store.prewarmDecryptionCache(items: store.items) { exp.fulfill() }
        wait(for: [exp], timeout: 10.0)

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
        // ID-FLAKE-0005 (2026-10-23): await the completion callback instead
        // of sleeping a fixed 0.5s. The sleep had NO margin over the
        // background decrypt, so under load the assertion below read a cold
        // cache. The completion fires after `group.wait()` — i.e. once every
        // decrypt of the batch has landed — which is precisely the state
        // these tests assert on.
        let exp = expectation(description: "prewarm completes")
        store.prewarmDecryptionCache(items: store.items) { exp.fulfill() }
        wait(for: [exp], timeout: 10.0)

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

        // ID-FLAKE-0005 (2026-10-23): await the completion callback instead
        // of sleeping a fixed 0.5s. The sleep had NO margin over the
        // background decrypt, so under load the assertion below read a cold
        // cache. The completion fires after `group.wait()` — i.e. once every
        // decrypt of the batch has landed — which is precisely the state
        // these tests assert on.
        let exp = expectation(description: "prewarm completes")
        store.prewarmDecryptionCache(items: store.items) { exp.fulfill() }
        wait(for: [exp], timeout: 10.0)

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
        // ID-FLAKE-0005 (2026-10-23): await BOTH completion callbacks
        // instead of sleeping a fixed 1.0s. The callbacks fire exactly when
        // their round finishes, so the verdict no longer depends on how
        // fast the machine is. A callback that fired TWICE would trip
        // XCTest's "multiple calls to fulfill()" API violation, so the
        // "exactly once" property is still enforced — and the counters
        // below assert it explicitly as well.
        let expA = expectation(description: "first completion fired")
        let expB = expectation(description: "coalesced completion fired")
        store.prewarmDecryptionCache(items: store.items) {
            lock.lock(); callsA += 1; aOnMain = Thread.isMainThread; lock.unlock()
            expA.fulfill()
        }
        store.prewarmDecryptionCache(items: store.items) {
            lock.lock(); callsB += 1; bOnMain = Thread.isMainThread; lock.unlock()
            expB.fulfill()
        }

        wait(for: [expA, expB], timeout: 10.0)

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

    // MARK: - ID-PERF-0024 (2026-08-03 audit): throttle drop must defer re-fire

    /// F-3 regression: when prewarmDecryptionCacheThrottled is called twice
    /// within the throttle window, the second call previously lost its items
    /// forever if no subsequent call landed after the window (active-state
    /// scenario: QuickBar close→reopen <window + stop). The fix schedules a
    /// delayed re-fire so the dropped items still get prewarmed once the
    /// window expires.
    ///
    /// Uses a short interval (0.5s) to keep the test fast; the trigger
    /// shape (two calls within window, no subsequent call) is the same.
    @MainActor
    func testPrewarmThrottleDeferredRefirePrewarmsDroppedItems() {
        let setA = (0..<3).map { ClipboardItem(content: "setA-\($0)", type: .text) }
        let setB = (0..<3).map { ClipboardItem(content: "setB-\($0)", type: .text) }
        store.items = setA + setB
        store.contentCache.removeAllObjects()

        // First call: lastViewPrewarmTime is .distantPast → no throttle →
        // prewarm fires immediately for setA.
        store.prewarmDecryptionCacheThrottled(items: setA, interval: 0.5)
        // ID-FLAKE-0005 (2026-10-23): wait for the CONDITION, not a fixed
        // 0.3s. `prewarmDecryptionCacheThrottled` exposes no completion
        // callback, so the exact signal available is the cache itself: the
        // items are cached once the background batch has landed. The old
        // 0.3s had no margin over that batch at all.
        XCTAssertTrue(waitForItemsCached(setA),
                      "ID-FLAKE-0005: setA must be cached after the first prewarm call")
        for item in setA {
            XCTAssertNotNil(store.contentCache.object(forKey: item.id.uuidString as NSString),
                            "setA must be cached after first prewarm call")
        }

        // Second call within window: throttled. Under old behavior, setB
        // items would be dropped forever. New behavior: deferred re-fire
        // scheduled to fire after the window expires.
        store.prewarmDecryptionCacheThrottled(items: setB, interval: 0.5)

        // The deferred re-fire is scheduled on the MAIN queue
        // (`DispatchQueue.main.asyncAfter`), so the main run loop has to
        // spin for it to happen at all — the poll below does that. The
        // bound has to clear the throttle window (0.5s) plus the batch
        // dispatch, but it must not be a FIXED sleep: the wait ends when
        // the items are actually cached.
        XCTAssertTrue(waitForItemsCached(setB),
                      "F-3 regression: deferred re-fire must prewarm items dropped by throttle")
        for item in setB {
            XCTAssertNotNil(store.contentCache.object(forKey: item.id.uuidString as NSString),
                            "F-3 regression: deferred re-fire must prewarm items dropped by throttle")
        }
    }

    // MARK: - ID-FLAKE-0005 helpers

    /// Polls until every given item has a cache entry.
    ///
    /// ID-FLAKE-0005: a fixed sleep raced the background batch; the
    /// verdict must depend on the write having happened, not on elapsed
    /// wall-clock time. The main run loop is spun on every poll because
    /// the throttled re-fire is scheduled on the main queue.
    private func waitForItemsCached(_ items: [ClipboardItem], timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if items.allSatisfy({ isCached($0) }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return items.allSatisfy({ isCached($0) })
    }

    private func isCached(_ item: ClipboardItem) -> Bool {
        store.contentCache.object(forKey: item.id.uuidString as NSString) != nil
    }
}
