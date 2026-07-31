import XCTest
@testable import ClipMemory

/// Regression: an encrypted-but-undecryptable item must mark decryptionFailed
/// exactly once — never re-mark (which published during view updates and
/// froze the app at 100% CPU when rendering the QuickBar/main window).
@MainActor final class DecryptionFailedLoopTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(CryptoService(customKeyData: Data((0..<32).map { UInt8($0) })))
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        store = nil
        backend = nil
        super.tearDown()
    }

    func testCorruptItemMarksFailedOnceThenStops() {
        // isEncrypted=true but content is garbage that will never decrypt.
        let bad = ClipboardItem(content: "not-valid-ciphertext", type: .text, isEncrypted: true)
        try? backend.save([bad])
        store.loadItems()

        // First access: returns nil and schedules the failure mark.
        XCTAssertNil(store.getDecryptedContent(bad))

        // C5: the mark is applied asynchronously on the main queue (never
        // synchronously inside a view update) — wait for the merge to land.
        let deadline = Date().addingTimeInterval(5)
        while store.items.first(where: { $0.id == bad.id })?.decryptionFailed != true,
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let markedOnce = store.items.first(where: { $0.id == bad.id })?.decryptionFailed
        XCTAssertEqual(markedOnce, true, "first failure must mark the flag")

        // Second access: early-out, nil again, and critically — items array
        // reference must not change (no publish storm).
        let before = store.items
        XCTAssertNil(store.getDecryptedContent(bad))
        XCTAssertNil(store.getDecryptedContent(bad))
        XCTAssertEqual(store.items, before, "repeat access must not re-mutate items")
    }

    func testPreFailedItemReturnsNilImmediately() {
        let failed = ClipboardItem(content: "x", type: .text, isEncrypted: true, decryptionFailed: true)
        try? backend.save([failed])
        store.loadItems()

        let before = store.items
        XCTAssertNil(store.getDecryptedContent(failed))
        XCTAssertEqual(store.items, before, "pre-failed items must not be touched at all")
    }

    // MARK: - ID-STORE-0001 (2026-07-31 audit): contentHash backfill skips decrypt failures

    /// ID-STORE-0001: when the legacy contentHash backfill can't decrypt an
    /// item (key not ready / corrupt blob), it must leave contentHash nil —
    /// retried on a later launch — instead of persisting an HMAC computed
    /// over the ciphertext fallback. The old `?? candidate.content` fallback
    /// wrote a WRONG dedup fingerprint that permanently poisoned dedup for
    /// the real content.
    func testBackfillSkipsItemWhenDecryptionFails() {
        // isEncrypted=true but content is garbage that will never decrypt.
        let bad = ClipboardItem(content: "not-valid-ciphertext", type: .text,
                                isEncrypted: true, contentHash: nil)
        try? backend.save([bad])
        store.loadItems()

        // The backfill runs on a utility queue and merges back on main —
        // give it time to settle. Pre-fix the merge wrote a bogus hash;
        // post-fix nothing is written.
        let exp = expectation(description: "backfill settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let loaded = store.items.first(where: { $0.id == bad.id })
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.contentHash,
                     "ID-STORE-0001: decrypt failure must not persist a bogus dedup fingerprint")
    }

    /// Positive control: a decryptable legacy item still gets its hash
    /// backfilled (guards against over-skipping in the ID-STORE-0001 fix).
    func testBackfillComputesHashWhenDecryptionSucceeds() {
        let crypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        let plaintext = "hello world"
        guard let ciphertext = crypto.encrypt(plaintext) else {
            XCTFail("test-key encrypt must succeed")
            return
        }
        let legacy = ClipboardItem(content: ciphertext, type: .text,
                                   isEncrypted: true, contentHash: nil)
        try? backend.save([legacy])
        store.loadItems()

        let deadline = Date().addingTimeInterval(5)
        while store.items.first(where: { $0.id == legacy.id })?.contentHash == nil,
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let loaded = store.items.first(where: { $0.id == legacy.id })
        XCTAssertEqual(loaded?.contentHash, crypto.hmacHex(for: plaintext),
                       "decryptable legacy item must get its contentHash backfilled")
    }
}
