import XCTest
@testable import ClipMemory

/// Regression: an encrypted-but-undecryptable item must mark decryptionFailed
/// exactly once — never re-mark (which published during view updates and
/// froze the app at 100% CPU when rendering the QuickBar/main window).
final class DecryptionFailedLoopTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.crypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.crypto = originalCrypto }
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
}
