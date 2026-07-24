import XCTest
@testable import ClipMemory

/// CLIP-4 (2026-07-24 audit): QuickBarView.displayedItems was an uncached
/// computed property consumed 4+ times per body evaluation (section label,
/// empty state, ForEach + dividers, keyboard handlers) — each evaluation an
/// O(n) filter with per-item decrypt/RTF-plaintext lookups. The result is
/// now cached in @State and recomputed only when store.items /
/// searchTextDebounced change (mirrors the ContentView visibleGlobalIndices
/// pattern, H-10). The filter itself is extracted to
/// `QuickBarView.computeDisplayedItems` so the logic is testable without a
/// SwiftUI view body.
final class QuickBarViewTests: XCTestCase {

    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        store = ClipboardStore(backend: MemoryStorageBackend())
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func addItems(_ contents: [String]) {
        for content in contents {
            store.addItem(ClipboardItem(content: content, type: .text))
        }
    }

    /// No search → the first `maxItems` entries, in store order (newest
    /// first). This is the dominant popover-open path.
    func testComputeDisplayedItemsEmptySearchReturnsPrefix() {
        addItems((1...10).map { "item \($0)" })
        let result = QuickBarView.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: "",
            maxItems: 8,
            store: store
        )
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.map(\.id), Array(store.items.prefix(8)).map(\.id))
    }

    /// Fewer items than the cap → all of them, no padding/truncation crash.
    func testComputeDisplayedItemsEmptySearchWithFewerItemsReturnsAll() {
        addItems(["alpha", "beta", "gamma"])
        let result = QuickBarView.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: "",
            maxItems: 8,
            store: store
        )
        XCTAssertEqual(result.count, 3)
    }

    /// Active search → case-insensitive substring match against decrypted
    /// content, over the FULL history (not just the first-8 prefix).
    func testComputeDisplayedItemsSearchFiltersCaseInsensitive() {
        addItems(["Hello World", "goodbye", "HELLO again"])
        let result = QuickBarView.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: "hello",
            maxItems: 8,
            store: store
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains { (store.getDecryptedContent($0) ?? "") == "goodbye" })
    }

    /// Search must match the DECRYPTED plaintext, not the stored ciphertext
    /// — regression guard for the CLIP-1 getDecryptedContent path inside
    /// the extracted helper.
    func testComputeDisplayedItemsSearchMatchesDecryptedPlaintext() {
        addItems(["secret needle text"])
        // Stored content is ciphertext; searching the plaintext must hit.
        XCTAssertNotEqual(store.items[0].content, "secret needle text")
        let result = QuickBarView.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: "needle",
            maxItems: 8,
            store: store
        )
        XCTAssertEqual(result.count, 1)
    }

    /// Decryption-failed items are excluded from search results even when
    /// their raw content would match — surfacing them would show the
    /// "decryption failed" placeholder as a search hit.
    func testComputeDisplayedItemsSearchExcludesDecryptionFailed() {
        store.addItem(ClipboardItem(content: "needle visible", type: .text))
        store.addItem(ClipboardItem(content: "needle broken", type: .text, decryptionFailed: true))
        let result = QuickBarView.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: "needle",
            maxItems: 8,
            store: store
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.contains { $0.isDecryptionFailed })
    }

    /// Search with no matches → empty (drives the "no results" empty state).
    func testComputeDisplayedItemsSearchNoMatchReturnsEmpty() {
        addItems(["alpha", "beta"])
        let result = QuickBarView.computeDisplayedItems(
            items: store.items,
            searchTextDebounced: "zzz-no-such-text",
            maxItems: 8,
            store: store
        )
        XCTAssertTrue(result.isEmpty)
    }
}
