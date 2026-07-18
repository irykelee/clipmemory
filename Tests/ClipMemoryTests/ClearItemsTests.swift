import XCTest
@testable import ClipMemory

/// Conditional clear (type × range) and tag deletion with content.
final class ClearItemsTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend, trashBackend: trashBackend)
    }

    override func tearDown() {
        store = nil
        trashBackend = nil
        backend = nil
        super.tearDown()
    }

    private func makeItem(_ content: String, _ type: ClipboardItemType, daysAgo: Int = 0, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(
            content: content,
            type: type,
            createdAt: Date().addingTimeInterval(-Double(daysAgo) * 86400),
            isPinned: pinned
        )
    }

    private func seed(_ items: [ClipboardItem]) {
        for item in items { store.addItem(item) }
    }

    // MARK: - clearItems(type:range:)

    func testClearByTypeKeepsOtherTypesAndPinned() {
        seed([
            makeItem("t1", .text),
            makeItem("t2", .text, pinned: true),
            makeItem("img1", .image),
            makeItem("link1", .link)
        ])
        let removed = store.clearItems(type: .text, range: .all)

        XCTAssertEqual(removed, 1, "only the unpinned text item is cleared")
        XCTAssertEqual(store.items.count, 3)
        XCTAssertTrue(store.items.contains { store.getDecryptedContent($0) == "t2" }, "pinned text item must survive")
        XCTAssertTrue(store.items.contains { store.getDecryptedContent($0) == "img1" })
        XCTAssertTrue(store.items.contains { store.getDecryptedContent($0) == "link1" })
        XCTAssertEqual(store.trashedItems.count, 1)
    }

    func testClearByRangeOlderKeepsTodayAndYesterday() {
        seed([
            makeItem("today", .text, daysAgo: 0),
            makeItem("yesterday", .text, daysAgo: 1),
            makeItem("old", .text, daysAgo: 5)
        ])
        let removed = store.clearItems(type: nil, range: .older)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(store.items.contains { store.getDecryptedContent($0) == "today" })
        XCTAssertTrue(store.items.contains { store.getDecryptedContent($0) == "yesterday" })
        XCTAssertFalse(store.items.contains { store.getDecryptedContent($0) == "old" })
    }

    func testClearCombinedImageOlderKeepsTodaysImages() {
        seed([
            makeItem("img-today", .image, daysAgo: 0),
            makeItem("img-old", .image, daysAgo: 3),
            makeItem("text-old", .text, daysAgo: 3)
        ])
        let removed = store.clearItems(type: .image, range: .older)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(store.items.contains { store.getDecryptedContent($0) == "img-today" }, "today's image must survive")
        XCTAssertTrue(store.items.contains { store.getDecryptedContent($0) == "text-old" }, "old text is out of scope (type filter)")
        XCTAssertFalse(store.items.contains { store.getDecryptedContent($0) == "img-old" })
    }

    func testClearEmptySelectionIsNoop() {
        seed([makeItem("only", .text)])
        let removed = store.clearItems(type: .image, range: .all)
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.trashedItems.count, 0)
    }

    // MARK: - deleteTag(includeItems:)

    func testDeleteTagKeepsItemsButStripsTagId() {
        let tag = Tag(name: "工作", colorHex: "#FF6B6B")
        store.addTag(tag)
        var item = makeItem("tagged", .text)
        item.tagIds = [tag.id]
        seed([item])

        store.deleteTag(id: tag.id, includeItems: false)

        XCTAssertNil(store.tags[tag.id], "tag definition removed")
        XCTAssertEqual(store.items.count, 1, "item kept")
        XCTAssertFalse(store.items[0].tagIds.contains(tag.id), "orphan tagId stripped")
        XCTAssertEqual(store.trashedItems.count, 0)
    }

    func testDeleteTagWithContentMovesItemsToTrash() {
        let tag = Tag(name: "工作", colorHex: "#FF6B6B")
        store.addTag(tag)
        var item = makeItem("tagged", .text)
        item.tagIds = [tag.id]
        seed([item, makeItem("untagged", .text)])

        store.deleteTag(id: tag.id, includeItems: true)

        XCTAssertNil(store.tags[tag.id])
        XCTAssertEqual(store.items.count, 1, "only untagged item remains")
        XCTAssertEqual(store.items.first.map { store.getDecryptedContent($0) }, "untagged")
        XCTAssertEqual(store.trashedItems.count, 1, "tagged item moved to recycle bin")
        XCTAssertEqual(store.trashedItems.first.map { store.getDecryptedContent($0) }, "tagged")
    }
}
