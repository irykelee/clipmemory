import XCTest
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-13): capture path perf regression test.
///
/// Before the fix, `ClipboardStore.addItem()` called `saveImmediately()` which
/// synchronously invoked `flushSave()` → `saveItems()` → `itemEncodingQueue.sync`
/// (the `.sync` hop was CLIP-2's intentional design but the capture path
/// bypassed the 500ms debounce). With 10K items (10-50MB blob), every
/// clipboard capture blocked the main thread 50-200ms for JSON encode +
/// write. 100 captures piled up 5-20s of UI-blocking time per second.
///
/// After the fix, `addItem()` routes through the existing 500ms
/// `scheduleSave()` debounce timer (same pattern as metadata mutations).
/// Encoding runs once at the end of the burst, not per capture. The
/// write-through contract is preserved at termination via `flushPendingSaves()`
/// (already wired to AppDelegate.applicationWillTerminate + a willTerminate
/// observer).
@MainActor
final class ClipboardStoreTests: XCTestCase {

    /// Counts saveBlob invocations; P2-13's core symptom is "100 addItem
    /// calls → 100 saveBlob calls on the main thread". A debounced capture
    /// path keeps the count at 0 (timer hasn't fired) or 1 (timer fired
    /// once for the burst). The pre-fix write-through path made 100 calls.
    private final class SaveCountingBackend: StorageBackend {
        private let inner = MemoryStorageBackend()
        private(set) var saveBlobCount = 0

        func load() throws -> [ClipboardItem] { try inner.load() }
        func save(_ items: [ClipboardItem]) throws { try inner.save(items) }
        func loadTags() throws -> [Tag] { try inner.loadTags() }
        func saveTags(_ tags: [Tag]) throws { try inner.saveTags(tags) }
        func saveBlob(_ data: Data) throws {
            saveBlobCount += 1
            try inner.saveBlob(data)
        }
    }

    private var backend: SaveCountingBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var testDefaults: UserDefaults!
    private var originalCrypto: CryptoServiceProtocol?

    override func setUp() {
        super.setUp()
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(
            CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        )
        testDefaults = makeTestDefaults()
        backend = SaveCountingBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(
            backend: backend,
            tagBackend: tagBackend,
            trashBackend: trashBackend,
            defaults: testDefaults
        )
    }

    override func tearDown() {
        store = nil
        backend = nil
        trashBackend = nil
        tagBackend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
        if let originalCrypto {
            ServiceContainer.setCryptoForTesting(originalCrypto)
        }
        originalCrypto = nil
        super.tearDown()
    }

    /// P2-13: capture path must NOT call `saveBlob` synchronously per item.
    /// Pre-fix: each `addItem` triggered `saveImmediately` → `flushSave` →
    /// `saveItems` → `itemEncodingQueue.sync` → `saveBlob`, all on the main
    /// thread. 100 captures = 100 synchronous encode+write cycles = the
    /// 50-200ms-per-capture stall documented in the audit (multiplied by
    /// capture rate).
    /// Post-fix: `addItem` routes through `scheduleSave` (500ms debounce).
    /// The 100-item burst leaves `saveBlobCount == 0` (debounce timer
    /// hasn't fired yet) — the burst collapses into one coalesced write
    /// when the timer fires.
    ///
    /// This is a behavioural assertion (call count), not a wall-clock
    /// assertion, so it doesn't flake under CI load. It pins the P2-13
    /// audit finding directly: the perf bug was *structural* (100 sync
    /// writes per 100 captures), not a magic-ms number.
    func testCapture100ItemsDoesNotWriteThroughSynchronously() {
        // Drain any pending saves from setUp wiring so the count starts
        // at a clean baseline.
        store.flushPendingSaves()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(
            backend.saveBlobCount, 0,
            "pre-condition: no pending saves after flush + runloop drain"
        )

        // Burst: 100 captures must NOT result in 100 saveBlob calls.
        for i in 0..<100 {
            store.addItem(ClipboardItem(content: "x\(i)", type: .text))
        }

        XCTAssertEqual(
            backend.saveBlobCount, 0,
            "P2-13: 100 addItem calls must coalesce via debounce (no write-through per capture); saw \(backend.saveBlobCount) saveBlob calls"
        )
        XCTAssertEqual(store.items.count, 100,
                       "all 100 items must still be in-memory even though no disk write has happened yet")
    }
}
