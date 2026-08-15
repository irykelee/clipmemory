import XCTest
@testable import ClipMemory

final class ItemListViewTests: XCTestCase {
    func testGroupHeaderToggleIsDisabledDuringSearch() {
        XCTAssertFalse(ItemListView.shouldToggleGroupHeader(searchText: "abc"))
    }

    func testGroupHeaderToggleRemainsEnabledWithoutSearch() {
        XCTAssertTrue(ItemListView.shouldToggleGroupHeader(searchText: ""))
    }

    // ID-VIEW-0042 (2026-08-16 audit MEDIUM-5 fix): the empty-state
    // classifier must pick the filter_no_match branch whenever the user
    // has a non-empty query — that's the whole point of M-5: don't show
    // "No clipboard history" copy when the real problem is the search
    // bar.
    func testEmptyShapeHistoryTabWithEmptySearchIsNoHistory() {
        XCTAssertEqual(ItemListView.emptyShape(searchText: "", selectedTab: .all), .noHistory)
    }

    func testEmptyShapeHistoryTabWithNonEmptySearchIsFilterNoMatch() {
        XCTAssertEqual(
            ItemListView.emptyShape(searchText: "absent", selectedTab: .all),
            .filterNoMatch
        )
    }

    func testEmptyShapeHistoryTabWithWhitespaceOnlySearchIsFilterNoMatch() {
        // Whitespace-only queries are non-empty by Swift's string rules
        // (which is the same check the search filter uses). A user
        // pasting a stray space should still see "no matches" rather
        // than the empty-history copy.
        XCTAssertEqual(
            ItemListView.emptyShape(searchText: " ", selectedTab: .all),
            .filterNoMatch
        )
    }

    func testEmptyShapePinnedTabIgnoresSearchAndUsesNoPinned() {
        // You can't pin what doesn't exist, so a non-empty search on
        // the pinned tab still shows the pinned copy — there's no
        // filter context for the user to misread.
        XCTAssertEqual(
            ItemListView.emptyShape(searchText: "abc", selectedTab: .pinned),
            .noPinned
        )
    }

    // ID-VIEW-0042: copy + icon for each shape must be distinct. Without
    // this the user can't tell empty-history from no-matches, which was
    // the original M-5 audit bug.
    func testEmptyShapeDistinctTitleAndIcon() {
        let history = ItemListView.EmptyShape.noHistory
        let pinned = ItemListView.EmptyShape.noPinned
        let filter = ItemListView.EmptyShape.filterNoMatch
        XCTAssertNotEqual(history.title, filter.title)
        XCTAssertNotEqual(history.title, pinned.title)
        XCTAssertNotEqual(filter.title, pinned.title)
        XCTAssertNotEqual(history.icon, filter.icon)
        XCTAssertNotEqual(history.icon, pinned.icon)
    }

    // ID-VIEW-0042: new L10n keys must not return the raw key (which is
    // what `L10n.string(_:)` does on a missing localization). A raw-key
    // return would surface "empty.no.filter" as visible text — exactly
    // the same failure mode as ID-APP-0005 caught for accessibility
    // hints. The hint gets a length floor (must be informative — naming
    // the "clear search" action); the title has no floor because 4-char
    // Chinese ("无匹配结果") and 5-char Traditional ("無符合結果")
    // are perfectly readable as headings.
    func testEmptyFilterLocalizationKeysResolve() {
        XCTAssertNotEqual(L10n.emptyNoFilter, "empty.no.filter")
        XCTAssertNotEqual(L10n.emptyFilterHint, "empty.filter.hint")
        XCTAssertFalse(L10n.emptyNoFilter.isEmpty, "ID-VIEW-0042: empty title would be a localization bug")
        XCTAssertGreaterThan(L10n.emptyFilterHint.count, 10,
            "ID-VIEW-0042: hint must name the action (e.g. 'clear search to see all'), not be a one-word stub")
    }
}
