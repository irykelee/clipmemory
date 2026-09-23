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

    // MARK: - P2-14: startup decode off main thread

    /// P1-AUDIT-2026-09-22 (P2-14) regression test. Simulates a 10K-item
    /// history with a backend whose `load()` blocks for 200ms (the order
    /// of magnitude of the JSON decode the audit measured). Asserts that
    /// `ClipboardStore.init` returns in well under 100ms — the heavy
    /// load must happen off the main thread, NOT block init — and that
    /// items arrive via the background load.
    func testStartupDoesNotBlockMainThreadOver100ms() {
        // Build a 10K-item fixture set. Real production JSON would be
        // 10-50MB; we just need N items so the count assertion is
        // meaningful — the slow part is the artificial delay, not the
        // payload size.
        let tenKItems = (0..<10_000).map { i in
            ClipboardItem(content: "p2-14-fixture-\(i)", type: .text)
        }
        let slowBackend = SlowStorageBackend(
            items: tenKItems,
            loadDelaySeconds: 0.2  // ~200ms — audit measured 100-300ms
        )

        // Pre-populate maxClipboardItems so the post-load `trimToMaxItems()`
        // does not trim the 10K fixture set down to the default 100-item
        // cap (which would mask the load and the assertion would pass for
        // the wrong reason). maxMaxItems hard-clamp is 10_000.
        let tenKDefaults = makeTestDefaults()
        tenKDefaults.set(10_000, forKey: "maxClipboardItems")

        let start = Date()
        let freshStore = ClipboardStore(
            backend: slowBackend,
            tagBackend: MemoryStorageBackend(),
            trashBackend: MemoryStorageBackend(),
            defaults: tenKDefaults
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 0.1,
            "P2-14: init must return in <100ms even with 10K-item history; load runs in background. measured=\(elapsed)s"
        )

        // Background load should still complete (200ms artificial delay).
        let didLoad = freshStore.waitForFirstLoadSync(timeout: 5.0)
        XCTAssertTrue(
            didLoad,
            "P2-14: background load must complete within 5s; otherwise the items never arrive"
        )
        XCTAssertEqual(
            freshStore.items.count, 10_000,
            "P2-14: all 10K items must arrive via the background load"
        )

        // Cleanup so the next test's setUp starts from a fresh defaults suite.
        removeTestDefaults(tenKDefaults)
    }
}

// MARK: - Test helpers (P2-14)

/// StorageBackend whose `load()` blocks for a configurable delay so
/// P2-14's regression test can simulate the JSON-decode wall-clock cost
/// of a 10K-item history without actually encoding 10K items into
/// UserDefaults (which would dominate test setup time). The rest of
/// the protocol is a no-op pass-through to the in-memory items.
private final class SlowStorageBackend: StorageBackend {
    private let storedItems: [ClipboardItem]
    private let loadDelaySeconds: TimeInterval

    init(items: [ClipboardItem], loadDelaySeconds: TimeInterval) {
        self.storedItems = items
        self.loadDelaySeconds = loadDelaySeconds
    }

    func load() throws -> [ClipboardItem] {
        // Busy-wait to simulate CPU-bound JSON decode without
        // depending on Thread.sleep (which under CI scheduling can
        // return earlier than requested, making the test flaky).
        let deadline = Date().addingTimeInterval(loadDelaySeconds)
        var acc: UInt64 = 0
        while Date() < deadline {
            // Tight loop — prevents the scheduler from parking us.
            for k in 0..<1000 { acc &+= UInt64(k) }
        }
        _ = acc  // silence unused warning
        return storedItems
    }

    func save(_ items: [ClipboardItem]) throws {}
    func loadTags() throws -> [Tag] { [] }
    func saveTags(_ tags: [Tag]) throws {}
}
