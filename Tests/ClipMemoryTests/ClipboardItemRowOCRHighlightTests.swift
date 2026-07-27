import XCTest
import SwiftUI
@testable import ClipMemory

final class ClipboardItemRowOCRHighlightTests: XCTestCase {

    // Sanitization (review 4.2)
    func testNulBytesAreStrippedDoNotCrashAttributedStringInit() {
        let ocr = "hello\0world"
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "hello")
        let s = String(attr.characters)
        XCTAssertTrue(s.contains("hello"))
        XCTAssertFalse(s.contains("\0"))
    }

    func testAllControlOcrTextReturnsNonCrashableAttributedString() {
        let ocr = "\0\0\0"
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "x")
        XCTAssertEqual(attr.characters.count, 0)
    }

    // Empty highlight
    func testEmptyHighlightReturnsPrefixOfOcrText() {
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: "abcdefghij", highlight: "")
        XCTAssertEqual(String(attr.characters), "abcdefghij")
    }

    // No match (review 4.3)
    func testSearchWithNoMatchReturnsEmptyAttributedString() {
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: "hello world", highlight: "xyz")
        XCTAssertEqual(attr.characters.count, 0)
    }

    // Single match
    func testSingleMatchIsHighlightedWithCyanBackground() {
        let ocr = "请在 2026 年前提交发票原件【收件人】张三"
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "发票")
        var foundCyan = false
        for run in attr.runs where run.backgroundColor != nil {
            foundCyan = true
            break
        }
        XCTAssertTrue(foundCyan)
        XCTAssertTrue(String(attr.characters).contains("发票"))
    }

    // Multiple matches
    func testMultipleMatchesAllHighlighted() {
        let ocr = "发票 抬头 发票 内容 发票 备注"
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "发票")
        let cyanCount = attr.runs.filter { $0.backgroundColor != nil }.count
        XCTAssertGreaterThanOrEqual(cyanCount, 3)
    }

    // Unicode correctness (review 1.1)
    func testTurkishIMatchPositionsCorrect() {
        let ocr = "İSTANBUL"  // 8 graphemes
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "istanbul")
        let s = String(attr.characters)
        // After fix: the highlighted run corresponds to original "İSTANBUL" (8 chars),
        // NOT the lowercased "i̇stanbul" (9 graphemes).
        XCTAssertTrue(s.contains("İSTANBUL") || s.contains("…İSTANBUL…"))
    }

    // Emoji / ZWJ sequence (review 1.1 stronger case)
    func testFamilyEmojiZwjSequenceDoesNotCrash() {
        let ocr = "hello 👨‍👩‍👧 world"
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "family")
        // No match expected — emoji is not text "family". Just must not crash.
        XCTAssertEqual(attr.characters.count, 0)
    }

    // Bounds guard (review 1.2)
    func testEndOffAtEndIndexDoesNotProduceZeroLengthHighlightRange() {
        let ocr = "abc123abc"
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "abc")
        var cyanCount = 0
        for run in attr.runs where run.backgroundColor != nil {
            let len = attr[run.range].characters.count
            XCTAssertEqual(len, 3)
            cyanCount += 1
        }
        XCTAssertEqual(cyanCount, 2)
    }

    // Centered excerpt
    func testLeadingEllipsisAddedWhenMatchFarFromStart() {
        let ocr = String(repeating: "x", count: 200) + "MATCH" + String(repeating: "y", count: 50)
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "MATCH")
        let s = String(attr.characters)
        XCTAssertTrue(s.hasPrefix("…"))
        XCTAssertTrue(s.contains("MATCH"))
    }

    func testShortOcrReturnsWholeTextWhenMatchFits() {
        let ocr = "abc MATCH def"
        let attr = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: "MATCH")
        let s = String(attr.characters)
        XCTAssertFalse(s.hasPrefix("…"))
        XCTAssertFalse(s.hasSuffix("…"))
        XCTAssertTrue(s.contains("abc MATCH def"))
    }

    // Cache hit / invalidation (review 5.2 + 1.3)
    func testCacheHitReturnsSameAttributedStringOnSecondCall() {
        let ocr = "请在 2026 年前提交发票"
        let search = "发票"
        let attr1 = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: search)
        let attr2 = ClipboardItemRow.highlightedOcrContent(ocrText: ocr, highlight: search)
        // Equality on AttributedString is value-based when runs match.
        XCTAssertEqual(attr1, attr2)
    }

    func testCacheKeyChangesWhenOcrTextChanges() {
        let attr1 = ClipboardItemRow.highlightedOcrContent(ocrText: "first OCR with KEY", highlight: "KEY")
        let attr2 = ClipboardItemRow.highlightedOcrContent(ocrText: "second OCR with KEY", highlight: "KEY")
        XCTAssertNotEqual(String(attr1.characters), String(attr2.characters))
    }
}