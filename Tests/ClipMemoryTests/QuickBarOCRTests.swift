import XCTest
import SwiftUI
@testable import ClipMemory

final class QuickBarOCRTests: XCTestCase {
    func testNarrowWindowProducesAtMost80CharExcerptForQuickBar() {
        let ocr = String(repeating: "x", count: 200) + "MATCH" + String(repeating: "y", count: 200)
        let attr = ClipboardItemRow.highlightedOcrContentNarrow(ocrText: ocr, highlight: "MATCH")
        let s = String(attr.characters)
        XCTAssertLessThanOrEqual(s.count, 80)
        XCTAssertTrue(s.contains("MATCH"))
    }
}
