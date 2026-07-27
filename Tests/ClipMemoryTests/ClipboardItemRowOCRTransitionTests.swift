import XCTest
import SwiftUI
@testable import ClipMemory

final class ClipboardItemRowOCRTransitionTests: XCTestCase {

    func testRowEqualityFlipsWhenOcrTextTransitions() {
        let baseItem = ClipboardItem(
            content: "test.png",
            type: .image,
            ocrText: nil,
            ocrAttempted: false
        )
        var itemWithOCR = baseItem
        itemWithOCR.ocrText = "ENCRYPTED_BLOB"
        itemWithOCR.ocrAttempted = true

        let rowA = ClipboardItemRow(
            item: baseItem,
            isRevealed: false,
            searchText: "test",
            onPin: {},
            onDelete: {},
            onToggleReveal: {}
        )
        let rowB = ClipboardItemRow(
            item: itemWithOCR,
            isRevealed: false,
            searchText: "test",
            onPin: {},
            onDelete: {},
            onToggleReveal: {}
        )
        XCTAssertNotEqual(rowA, rowB)
    }
}
