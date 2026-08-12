import XCTest
import SwiftUI
@testable import ClipMemory

@MainActor private struct SidebarViewTestHost: View {
    let store: ClipboardStore
    let tag: Tag

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        SidebarView(
            store: store,
            selectedTab: .constant(.all),
            searchText: .constant(""),
            isSearchFocused: $isSearchFocused,
            onSearchSubmit: {},
            selectedTagIds: [tag.id],
            tabCounts: [.all: 3, .text: 2, .image: 1],
            tagCounts: [tag.id: 2],
            sortedTags: [tag],
            onToggleTag: { _ in },
            onNewTag: {},
            onDeleteTag: { _ in },
            onClearType: { _ in },
            onTabChanged: {}
        )
    }
}

@MainActor final class SidebarViewTests: XCTestCase {
    func testTypeLabelMapsEveryClipboardItemType() {
        XCTAssertEqual(typeLabel(.text), L10n.filterText)
        XCTAssertEqual(typeLabel(.image), L10n.filterImage)
        XCTAssertEqual(typeLabel(.link), L10n.filterLink)
        XCTAssertEqual(typeLabel(.richText), L10n.filterRichText)
    }

    func testSidebarViewCanBeConstructedWithApprovedInterface() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let tag = Tag(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Work",
            colorHex: "#4ECDC4",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        _ = SidebarViewTestHost(store: store, tag: tag)
    }

    // ID-VIEW-0029 (2026-08-13, user-driven): sidebar badge for .pinned was
    // the only filter tab without a count. Assert computeTabCounts now
    // returns the correct .pinned aggregate, alongside the existing type
    // counts (regression guard).
    func testComputeTabCountsIncludesPinnedCount() {
        let items: [ClipboardItem] = [
            ClipboardItem(content: "a", type: .text, isPinned: true),
            ClipboardItem(content: "b", type: .text, isPinned: true),
            ClipboardItem(content: "c", type: .image, isPinned: false),
            ClipboardItem(content: "d", type: .link, isPinned: true),
            ClipboardItem(content: "e", type: .text, isPinned: false),
            ClipboardItem(content: "f", type: .richText, isPinned: true),
            ClipboardItem(content: "g", type: .image, isPinned: true)
        ]
        let counts = ContentView.computeTabCounts(items: items)

        XCTAssertEqual(counts[.all], 7)
        XCTAssertEqual(counts[.text], 3)
        XCTAssertEqual(counts[.image], 2)
        XCTAssertEqual(counts[.link], 1)
        XCTAssertEqual(counts[.richText], 1)
        XCTAssertEqual(counts[.pinned], 5, ".pinned must aggregate across all types")
    }
}
