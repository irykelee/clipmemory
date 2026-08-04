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
}
