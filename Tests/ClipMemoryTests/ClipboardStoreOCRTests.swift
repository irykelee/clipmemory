import XCTest
import AppKit
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-15): `ClipboardStore.getDecryptedOcrText`
/// calls `contentCache.setObject(_:forKey:)` without passing `cost:`,
/// which silently bypasses `totalCostLimit` (10 MB on `contentCache`).
/// Per ID-PERF-0017 the OCR plaintext cache can grow unbounded —
/// a few large items (book pages, screenshots) crowd out smaller
/// items and invalidate the cache's whole purpose. The fix passes
/// `plaintext.utf8.count` as the cost, matching the pattern already
/// used for `rtfPlaintextCache` (see ClipboardStore.swift:1697/1704/1712).
@MainActor final class ClipboardStoreOCRTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?
    private var testCrypto: CryptoService!

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
        testCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(testCrypto)
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        testCrypto = nil
        store = nil
        backend = nil
        super.tearDown()
    }

    /// Build an image item with `ocrText` already encrypted. The decrypted
    /// OCR plaintext will be exactly `plaintext`.
    private func makeImageItem(plaintext: String) throws -> ClipboardItem {
        let ciphertext = try XCTUnwrap(testCrypto.encrypt(plaintext))
        let hash = try XCTUnwrap(testCrypto.hmacHex(for: plaintext))
        return ClipboardItem(
            content: ciphertext,
            type: .image,
            isEncrypted: true,
            contentHash: hash,
            ocrText: ciphertext,
            ocrAttempted: true
        )
    }

    /// P2-15: when total cached plaintext exceeds `totalCostLimit`, the
    /// earliest (LRU) entry must be evicted. Without `cost:` set, NSCache
    /// uses cost = 0 for every entry, so `totalCostLimit` never triggers
    /// eviction regardless of plaintext size — only `countLimit` does,
    /// and `contentCache.countLimit` defaults to 500, far above what
    /// realistic OCR workloads hit on a single frame.
    func testOCRPlaintextCacheEvictsWhenTotalCostExceedsLimit() throws {
        // Shrink the limit so the test is deterministic without burning MB
        // of plaintext. 100 bytes forces eviction at the third insertion
        // (60 + 60 + 60 = 180 > 100) with healthy over-limit margin.
        store.contentCache.totalCostLimit = 100

        let plaintext = String(repeating: "x", count: 60)  // 60 bytes per item
        // 3 items × 60 bytes = 180 bytes > 100 byte totalCostLimit.
        let items = try (0..<3).map { _ in try makeImageItem(plaintext: plaintext) }

        // Warm the OCR plaintext cache for each item. The first call for
        // each id decrypts; subsequent calls hit the cache. Either way, the
        // setObject path is what we're testing — with cost set, NSCache
        // evicts items[0] (LRU) when items[2] pushes the total over the
        // limit; without cost set, items[0] stays put.
        for item in items {
            XCTAssertEqual(store.getDecryptedOcrText(item), plaintext,
                           "precondition: decrypt should round-trip the OCR plaintext")
        }

        let firstOCRKey = (items[0].id.uuidString + ".ocr") as NSString
        XCTAssertNil(
            store.contentCache.object(forKey: firstOCRKey),
            "P2-15: totalCostLimit must enforce — items[0] should have been "
            + "evicted (LRU) when total cost exceeded the limit; NSCache "
            + "requires the `cost:` parameter to track byte budgets."
        )
    }
}