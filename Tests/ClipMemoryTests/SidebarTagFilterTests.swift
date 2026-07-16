import XCTest
@testable import ClipMemory

/// Validates SidebarTagFilter.apply — the pure helper behind ContentView's
/// multi-section sidebar (类型 AND 标签段内 OR). Date + search filters
/// remain in ContentView's filterItems; this helper covers only the
/// sidebar-driven filter dimensions so each can be unit-tested in isolation.
final class SidebarTagFilterTests: XCTestCase {

    private let tagA = Tag(name: "工作", colorHex: "#FF6B6B")
    private let tagB = Tag(name: "代码", colorHex: "#4ECDC4")
    private let tagC = Tag(name: "学习", colorHex: "#45B7D1")

    private func makeItem(_ content: String,
                          type: ClipboardItemType = .text,
                          tagIds: Set<UUID> = [],
                          isPinned: Bool = false) -> ClipboardItem {
        var item = ClipboardItem(content: content, type: type)
        item.isPinned = isPinned
        item.tagIds = tagIds
        return item
    }

    // MARK: - Empty selection

    /// Empty selectedTagIds → no tag filtering applied.
    func testEmptySelectedTagIdsShowsAll() {
        let items = [
            makeItem("a", tagIds: [tagA.id]),
            makeItem("b", tagIds: []),
            makeItem("c", tagIds: [tagB.id])
        ]
        let result = SidebarTagFilter.apply(items: items,
                                            typeFilter: nil,
                                            pinnedOnly: false,
                                            selectedTagIds: [])
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - Single tag (AND with type tab)

    /// Single tag selected → items must contain it.
    func testSingleSelectedTagFiltersItems() {
        let items = [
            makeItem("a", tagIds: [tagA.id]),
            makeItem("b", tagIds: []),
            makeItem("c", tagIds: [tagB.id])
        ]
        let result = SidebarTagFilter.apply(items: items,
                                            typeFilter: nil,
                                            pinnedOnly: false,
                                            selectedTagIds: [tagA.id])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.content, "a")
    }

    // MARK: - Multiple tags = OR within section

    /// Two tags selected → items matching EITHER survive (union).
    /// This is "段内 OR" per the design — users select multiple tag rows
    /// in the sidebar to broaden the match.
    func testMultipleSelectedTagsAreOR() {
        let items = [
            makeItem("a", tagIds: [tagA.id]),
            makeItem("b", tagIds: [tagB.id]),
            makeItem("c", tagIds: [tagC.id]),
            makeItem("d", tagIds: [])
        ]
        let result = SidebarTagFilter.apply(items: items,
                                            typeFilter: nil,
                                            pinnedOnly: false,
                                            selectedTagIds: [tagA.id, tagB.id])
        XCTAssertEqual(Set(result.map(\.content)), Set(["a", "b"]))
    }

    // MARK: - Type tab AND tag section

    /// Type tab (.text) AND tag section (code) → item must satisfy BOTH.
    /// This is the "跨段 AND" half of the design.
    func testTagFilterCombinedWithTypeTabIsAND() {
        let items = [
            makeItem("text+code", type: .text, tagIds: [tagB.id]),
            makeItem("text+other", type: .text, tagIds: [tagC.id]),
            makeItem("image+code", type: .image, tagIds: [tagB.id])
        ]
        let result = SidebarTagFilter.apply(items: items,
                                            typeFilter: .text,
                                            pinnedOnly: false,
                                            selectedTagIds: [tagB.id])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.content, "text+code")
    }

    // MARK: - Pinned + tag

    /// Pinned tab AND tag filter behaves like any other type tab.
    func testPinnedTabWithTagFilter() {
        let items = [
            makeItem("pinned+code", tagIds: [tagB.id], isPinned: true),
            makeItem("pinned+other", tagIds: [tagC.id], isPinned: true),
            makeItem("unpinned+code", tagIds: [tagB.id], isPinned: false)
        ]
        let result = SidebarTagFilter.apply(items: items,
                                            typeFilter: nil,
                                            pinnedOnly: true,
                                            selectedTagIds: [tagB.id])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.content, "pinned+code")
    }

    // MARK: - Orphan UUID = empty result

    /// selectedTagIds contains a UUID that no item has → no matches.
    /// Orphan cleanup is ContentView's responsibility; the filter itself
    /// just does set intersection.
    func testTagFilterWithOrphanUUIDReturnsEmpty() {
        let orphan = UUID()
        let items = [
            makeItem("a", tagIds: [tagA.id])
        ]
        let result = SidebarTagFilter.apply(items: items,
                                            typeFilter: nil,
                                            pinnedOnly: false,
                                            selectedTagIds: [orphan])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Pinned tab ignores type

    /// When pinnedOnly = true, items are matched on isPinned rather than
    /// their type (the caller passes typeFilter: nil for the pinned tab).
    func testPinnedOnlyIgnoresType() {
        let items = [
            makeItem("pinned-text", type: .text, isPinned: true),
            makeItem("pinned-image", type: .image, isPinned: true),
            makeItem("unpinned-image", type: .image, isPinned: false)
        ]
        let result = SidebarTagFilter.apply(items: items,
                                            typeFilter: nil,
                                            pinnedOnly: true,
                                            selectedTagIds: [])
        XCTAssertEqual(result.count, 2)
    }
}