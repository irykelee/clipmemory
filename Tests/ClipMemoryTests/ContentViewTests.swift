import XCTest
@testable import ClipMemory

/// H-10 (2026-07-24 audit): `visibleGlobalIndices` is the per-keypress O(n)
/// walk inside ContentView. The fix caches the result and only recomputes
/// when collapsedGroups / searchTextDebounced / cachedDisplayedItems change.
/// The pure computation is extracted to `ContentView.computeVisibleGlobalIndices`
/// so the logic is testable without spinning up a SwiftUI view.
final class ContentViewTests: XCTestCase {

    private let today = Date(timeIntervalSince1970: 30_000)
    private var yesterday: Date { Date(timeIntervalSince1970: 29_000) }

    private func makeItem(at secondsSince1970: TimeInterval, id: UUID = UUID()) -> ClipboardItem {
        ClipboardItem(
            id: id,
            content: "x",
            type: .text,
            createdAt: Date(timeIntervalSince1970: secondsSince1970),
            isPinned: false,
            isSensitive: false
        )
    }

    /// H-10: empty items → empty indices (defensive — handleKeyUp/Down/Return
    /// guard on `visibleIdx.isEmpty` so this never crashes, but we lock it in).
    func testComputeVisibleGlobalIndices_emptyItems_returnsEmpty() {
        let result = ContentView.computeVisibleGlobalIndices(
            items: [],
            collapsedGroups: [],
            searchText: "",
            today: today,
            yesterday: yesterday
        )
        XCTAssertEqual(result, [])
    }

    /// H-10: nothing collapsed, no search → every index is visible. This is
    /// the dominant case when the user hasn't touched the section chevrons.
    func testComputeVisibleGlobalIndices_noCollapsed_returnsAllIndices() {
        let items = [
            makeItem(at: 30_000), // today
            makeItem(at: 29_500), // today (still after yesterday)
            makeItem(at: 28_000)  // older
        ]
        let result = ContentView.computeVisibleGlobalIndices(
            items: items,
            collapsedGroups: [],
            searchText: "",
            today: today,
            yesterday: yesterday
        )
        XCTAssertEqual(result, [0, 1, 2])
    }

    /// H-10: collapsed "yesterday" group → indices whose item.group == .yesterday
    /// are excluded. ↑/↓ nav will skip them.
    func testComputeVisibleGlobalIndices_collapsedYesterday_excludesYesterdayIndices() {
        let realToday = Date(timeIntervalSince1970: 31_000)
        let realYesterday = Date(timeIntervalSince1970: 29_500)
        let items = [
            makeItem(at: 30_500), // yesterday (30_500 < 31_000 && >= 29_500)
            makeItem(at: 30_000), // yesterday
            makeItem(at: 28_000)  // older
        ]
        let result = ContentView.computeVisibleGlobalIndices(
            items: items,
            collapsedGroups: [.yesterday],
            searchText: "",
            today: realToday,
            yesterday: realYesterday
        )
        XCTAssertEqual(result, [2], "Only the older-group item (index 2) should remain visible")
    }

    /// H-10: search active → all groups force-expanded regardless of
    /// collapsedGroups. Matches the original computed property behavior:
    /// `effectiveCollapsed = searchText.isEmpty ? collapsedGroups : []`.
    func testComputeVisibleGlobalIndices_searchActive_ignoresCollapsedGroups() {
        let realToday = Date(timeIntervalSince1970: 31_000)
        let realYesterday = Date(timeIntervalSince1970: 29_500)
        let items = [
            makeItem(at: 30_500), // yesterday
            makeItem(at: 30_000), // yesterday
            makeItem(at: 28_000)  // older
        ]
        let result = ContentView.computeVisibleGlobalIndices(
            items: items,
            collapsedGroups: [.yesterday, .older],
            searchText: "needle",
            today: realToday,
            yesterday: realYesterday
        )
        XCTAssertEqual(result, [0, 1, 2], "Active search must force-expand all groups")
    }
}