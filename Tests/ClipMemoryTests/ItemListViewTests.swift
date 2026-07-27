import XCTest
@testable import ClipMemory

final class ItemListViewTests: XCTestCase {
    func testGroupHeaderToggleIsDisabledDuringSearch() {
        XCTAssertFalse(ItemListView.shouldToggleGroupHeader(searchText: "abc"))
    }

    func testGroupHeaderToggleRemainsEnabledWithoutSearch() {
        XCTAssertTrue(ItemListView.shouldToggleGroupHeader(searchText: ""))
    }
}
