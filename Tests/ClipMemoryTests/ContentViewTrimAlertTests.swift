import XCTest
@testable import ClipMemory

/// CLIP-3 (2026-07-24 audit): the maxItems trim-confirmation alert was
/// attached to `itemList`, which is absent from the view tree while the
/// Settings tab is active — the only place the alert can be triggered from.
/// The alert now lives at the outer `withKeyAndSheets` level, and its
/// confirm/cancel decisions are extracted to static helpers
/// (`ContentView.applyTrimConfirmation` / `applyTrimCancellation`) so the
/// logic is testable without rendering the view hierarchy.
@MainActor final class ContentViewTrimAlertTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // ID-CRASH-0057 rework 3 (auto-review-20261002-124153 P1): store.maxItems
        // writes through to the store's defaults in didSet. Under XCTest the
        // store defaults to the shared "ClipboardStore-XCTest-isolation" suite,
        // so a limit set by one test leaked into the next test of this suite:
        // testConfirmTrimApplies... persisted maxItems=2, the next makeStore
        // then capped its items at 2 and items[3] trapped (deterministic host
        // crash). Per-test suites isolate the write. The previous
        // UserDefaults.standard save/restore was a no-op — the store never
        // writes .standard under XCTest (same dead-code finding as
        // Audit20260720RegressionTests C-1).
        testDefaults = makeTestDefaults()
    }

    override func tearDown() {
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    private func makeStore(itemCount: Int) -> ClipboardStore {
        let store = ClipboardStore(backend: MemoryStorageBackend(), defaults: testDefaults)
        for i in 0..<itemCount {
            store.addItem(ClipboardItem(content: "item \(i)", type: .text))
        }
        return store
    }

    /// Confirm path: the reduced limit is applied and the overflow is
    /// evicted, keeping the most recent items.
    func testConfirmTrimAppliesNewLimitAndTrimsOverflow() throws {
        let store = makeStore(itemCount: 5)
        XCTAssertEqual(store.items.count, 5)

        ContentView.applyTrimConfirmation(
            pair: PendingMaxItemsReduction(old: 100, new: 2),
            store: store
        )

        XCTAssertEqual(store.maxItems, 2)
        XCTAssertEqual(store.items.count, 2)
        // trimToMaxItems keeps the newest (front of the array).
        XCTAssertEqual(store.getDecryptedContent(store.items[0]), "item 4")
        XCTAssertEqual(store.getDecryptedContent(store.items[1]), "item 3")
    }

    /// Confirm path persists: after flush, a restarted store on the same
    /// backend sees the trimmed history, not the pre-trim one.
    func testConfirmTrimPersistsTrimmedItems() throws {
        let backend = MemoryStorageBackend()
        let store = ClipboardStore(backend: backend, defaults: testDefaults)
        for i in 0..<5 {
            store.addItem(ClipboardItem(content: "item \(i)", type: .text))
        }

        ContentView.applyTrimConfirmation(
            pair: PendingMaxItemsReduction(old: 100, new: 1),
            store: store
        )

        let restarted = ClipboardStore(backend: backend, defaults: testDefaults)
        // ID-CRASH-0057: init no longer auto-waits for the background load;
        // restart-simulation tests must await it explicitly.
        XCTAssertTrue(restarted.waitForFirstLoadSync(timeout: 15.0),
                      "restart load must complete before assertions")
        XCTAssertEqual(restarted.items.count, 1)
        XCTAssertEqual(restarted.getDecryptedContent(restarted.items[0]), "item 4")
    }

    /// Cancel path: the previous limit is restored and no item is evicted.
    /// Regression guard — the old alert's cancel wrote `store.maxItems =
    /// pair.old`; dropping that write in the refactor would leave the
    /// picker's tentative value in place.
    func testCancelTrimRestoresOldLimitWithoutTrimming() throws {
        let store = makeStore(itemCount: 5)
        let before = store.items.map(\.id)

        ContentView.applyTrimCancellation(
            pair: PendingMaxItemsReduction(old: 100, new: 2),
            store: store
        )

        XCTAssertEqual(store.maxItems, 100)
        XCTAssertEqual(store.items.map(\.id), before, "Cancel must not trim history")
    }

    /// Cancel path with a pinned item in the overflow: nothing is lost even
    /// if confirm follows a cancel (pinned items are a retention guarantee).
    func testConfirmTrimKeepsPinnedItems() throws {
        let store = makeStore(itemCount: 4)
        let pinned = store.items[3] // "item 0" — oldest
        store.togglePin(pinned)

        ContentView.applyTrimConfirmation(
            pair: PendingMaxItemsReduction(old: 100, new: 2),
            store: store
        )

        // 1 pinned + 1 newest non-pinned fill the cap of 2; the two middle
        // items are evicted. The pinned item must survive.
        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(store.items.contains { $0.id == pinned.id })
        XCTAssertTrue(store.items.contains { $0.id == store.items[0].id })
    }
}
