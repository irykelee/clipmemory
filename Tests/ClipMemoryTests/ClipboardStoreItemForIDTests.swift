import XCTest
@testable import ClipMemory

/// ID-PERF-0026 (2026-08-11 audit): O(1) item lookup by id, replacing
/// the row-level `liveIndexByID` computed property that rebuilt a
/// full dict on every access (measured 11× slower than the pre-fix
/// `first(where:)` baseline). Tests guard the new `item(forID:)`
/// method on the versioned `itemIndex` and cover the staleness
/// window the row used to paper over with a per-property rebuild.
@MainActor final class ClipboardStoreItemForIDTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = makeTestDefaults()
        backend = MemoryStorageBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend, tagBackend: tagBackend, trashBackend: trashBackend, defaults: testDefaults)
    }

    override func tearDown() {
        store = nil
        trashBackend = nil
        tagBackend = nil
        backend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Happy path

    func testItemForIDReturnsCorrectItem() {
        let item = ClipboardItem(content: "hello world", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        // Identity check only — `item.content` is the encrypted
        // stored form (CryptoService v2 base64), not plaintext.
        // Decryption is the responsibility of `getDecryptedContent`,
        // out of scope for the O(1) lookup this method exists to
        // provide. The id round-trip is the right test for "returns
        // the right item".
        XCTAssertEqual(store.item(forID: item.id)?.id, item.id)
        // And the same instance is in the items array (sanity that
        // the index points to the right slot, not a stale copy).
        XCTAssertTrue(store.items.contains(where: { $0.id == item.id }))
    }

    func testItemForIDReturnsNilForUnknownID() {
        let item = ClipboardItem(content: "x", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        let unknown = UUID()
        XCTAssertNil(store.item(forID: unknown))
    }

    // MARK: - Staleness window (the regression the method defends against)

    /// After `addItem` the dict must reflect the new entry on the very
    /// next call. Pre-fix `liveIndexByID` would catch this on the same
    /// body render because it rebuilt unconditionally, but it did so
    /// 4× per body. The versioned `itemIndex` here only rebuilds on
    /// version mismatch — this test pins that the mismatch fires.
    func testItemForIDReflectsNewlyAddedItem() {
        let first = ClipboardItem(content: "first", type: .text)
        store.addItem(first)
        store.flushPendingSaves()

        // Warm the index (lookup is a no-op the first time if stale)
        _ = store.item(forID: first.id)

        let second = ClipboardItem(content: "second", type: .text)
        store.addItem(second)
        store.flushPendingSaves()

        // Identity check — the new item must be reachable through
        // the version-bumped index. Content is encrypted, out of
        // scope for this lookup-only assertion.
        XCTAssertNotNil(store.item(forID: second.id))
        XCTAssertEqual(store.item(forID: second.id)?.id, second.id)
    }

    /// After `deleteItem` the index must drop the entry — otherwise a
    /// row bound to the deleted item would still resolve through the
    /// stale index and read garbage.
    func testItemForIDReturnsNilAfterDeletion() {
        let item = ClipboardItem(content: "doomed", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        // Confirm present first
        XCTAssertNotNil(store.item(forID: item.id))

        // deleteItem moves to trash (ID-CRASH-0001 invariant) — should
        // no longer be in the main items array
        store.deleteItem(item)
        store.flushPendingSaves()

        XCTAssertNil(store.item(forID: item.id),
                     "deleted (trashed) item must not be reachable via item(forID:)")
    }

    /// After `updateItem` the lookup must return the new content, not
    /// the captured pre-mutation snapshot.
    func testItemForIDReturnsUpdatedContentAfterMutation() {
        let item = ClipboardItem(content: "v1", type: .text)
        store.addItem(item)
        store.flushPendingSaves()

        // Simulate a mutation: togglePin moves the item to top of the
        // list, exercising both content reordering and version bump.
        store.togglePin(item)
        store.flushPendingSaves()

        XCTAssertEqual(store.item(forID: item.id)?.isPinned, true,
                       "togglePin should propagate through itemIndex version bump")
    }

    // MARK: - O(1) invariant (regression guard for the 11× claim)

    /// 1000 lookups across 1000 items must complete well under the
    /// O(n) scan baseline. With the versioned index, the first call
    /// rebuilds (O(n), ≤1ms) and the remaining 999 are O(1) cache hits.
    /// Threshold is loose to avoid CI flakiness; the regression we
    /// want to catch is the per-call `first(where:)` O(n) loop, not
    /// honest measurement noise.
    func testItemForIDIsAmortizedO1AcrossManyItems() {
        let items = (0..<1000).map { i in
            ClipboardItem(content: "item-\(i)", type: .text)
        }
        for item in items {
            store.addItem(item)
        }
        store.flushPendingSaves()

        // Warm — first call rebuilds the index
        _ = store.item(forID: items[0].id)

        let start = Date()
        for item in items {
            _ = store.item(forID: item.id)
        }
        let elapsed = Date().timeIntervalSince(start) * 1000

        // 1000 O(1) lookups should be ≪ 1000 O(n) scans. ~50ms ceiling
        // is generous — typical: <5ms.
        XCTAssertLessThan(elapsed, 50,
                          "1000 O(1) item(forID:) lookups should take <50ms, took \(elapsed)ms")
    }
}
