import XCTest
@testable import ClipMemory

/// Validates TagChipStack's data-shape logic. We test the helper that
/// decides which tag ids become chips, rather than walking the SwiftUI view
/// tree (which has no public introspection).
final class TagChipStackTests: XCTestCase {

    /// Empty tagIds → empty result list.
    func testEmptyTagIdsReturnsEmpty() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let visible = TagChipStack.visibleTags(from: Set<UUID>(), store: store)
        XCTAssertTrue(visible.isEmpty)
    }

    /// Orphan UUIDs (tagId not in store.tags) are silently dropped. Defends
    /// against future code paths that might bypass ClipboardStore.deleteTag's
    /// item-sweep logic.
    func testOrphanUUIDsAreDropped() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let real = Tag(name: "real", colorHex: "#4ECDC4")
        store.addTag(real)
        let visible = TagChipStack.visibleTags(from: [real.id, UUID()], store: store)
        XCTAssertEqual(visible.count, 1, "Orphan UUID should be filtered out")
        XCTAssertEqual(visible.first?.id, real.id)
    }

    /// More than maxChipsVisible tags → only the first maxChipsVisible render.
    /// The rest are accessible via the picker sheet, not the row.
    func testRespectsMaxChipsVisibleCap() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        for i in 0..<(TagChipStack.maxChipsVisible + 3) {
            store.addTag(Tag(name: "t\(i)", colorHex: Tag.presetColors[i % Tag.presetColors.count]))
        }
        let visible = TagChipStack.visibleTags(from: Set(store.tags.keys), store: store)
        XCTAssertEqual(visible.count, TagChipStack.maxChipsVisible,
                       "Should cap at maxChipsVisible to avoid row-height explosion")
    }

    /// Valid tagIds that all exist in store → one tag per id (capped).
    func testAllAttainedTagsReturn() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        store.addTag(Tag(name: "a", colorHex: "#FF6B6B"))
        store.addTag(Tag(name: "b", colorHex: "#4ECDC4"))
        store.addTag(Tag(name: "c", colorHex: "#45B7D1"))
        let visible = TagChipStack.visibleTags(from: Set(store.tags.keys), store: store)
        XCTAssertEqual(visible.count, 3)
    }

    /// maxChipsVisible is itself pinned to a known value — guards against
    /// accidental edits that would change visual density.
    func testMaxChipsVisibleIsFixed() {
        XCTAssertEqual(TagChipStack.maxChipsVisible, 4)
    }

    /// visibleTags must be deterministic: sorted by localized tag name so the
    /// same set of ids always renders in the same order.
    func testVisibleTagsAreSortedByName() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let zebra = Tag(name: "zebra", colorHex: "#FF6B6B")
        let apple = Tag(name: "apple", colorHex: "#4ECDC4")
        let mango = Tag(name: "mango", colorHex: "#45B7D1")
        store.addTag(zebra)
        store.addTag(apple)
        store.addTag(mango)

        let visible = TagChipStack.visibleTags(from: [zebra.id, apple.id, mango.id], store: store)

        XCTAssertEqual(visible.map(\.name), ["apple", "mango", "zebra"])
    }
}
