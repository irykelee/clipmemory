import XCTest
@testable import ClipMemory

/// ID-CRASH-0002 (2026-07-31 audit): `maskedHighlightedContent` (and the
/// first-match offset in `highlightedContent`) computed match ranges on a
/// `lowercased()` COPY and applied them to the original string. Unicode
/// case-fold that changes grapheme count ("İ"→"i̇", 1→2 chars; "ß"→"ss")
/// shifted every index past the fold point — a main-thread trap when a
/// sensitive item containing such text matched a search. These tests pin
/// the fixed behavior: the search runs on the ORIGINAL string via
/// `.caseInsensitive`, so all indices belong to one string.
final class ClipboardItemRowUnicodeHighlightTests: XCTestCase {

    /// "İ" lowercases to "i̇" (2 graphemes) — the exact BUG-008 example.
    /// Before the fix, 40 leading "İ" inflated the lowercased copy by 40
    /// chars, pushing the "needle" match range past `content.endIndex`.
    func testMaskedHighlight_turkishDottedIPrefix_doesNotCrashAndHighlights() {
        let content = String(repeating: "İ", count: 40) + " needle " + String(repeating: "x", count: 20)
        let result = ClipboardItemRow.maskedHighlightedContent(content, highlight: "needle")
        XCTAssertTrue(String(result.characters).contains("needle"),
                      "match after a case-fold-expanding prefix must still be located")
    }

    /// "ß" uppercases to "SS" (another length-changing fold). The uppercase
    /// "SECRET" must be found case-insensitively without crossing strings.
    func testMaskedHighlight_sharpSPrefix_uppercaseMatch_doesNotCrash() {
        let content = "straße SECRET " + String(repeating: "y", count: 30)
        let result = ClipboardItemRow.maskedHighlightedContent(content, highlight: "secret")
        XCTAssertTrue(String(result.characters).contains("SECRET"))
    }

    /// No match → fully masked fallback (also must not crash on İ text).
    func testMaskedHighlight_noMatch_returnsMaskedContent() {
        let result = ClipboardItemRow.maskedHighlightedContent("İstanbul plain", highlight: "zzz")
        XCTAssertFalse(String(result.characters).contains("İstanbul"),
                       "no-match path must return masked bullets, not the raw content")
    }

    /// The same cross-string trap lived in `highlightedContent`: `mso` was a
    /// distance in the lowercased copy, applied to `text` via a NON-limited
    /// `offsetBy:` — 60 leading "İ" pushed it 60 chars past the end.
    func testHighlightedContent_turkishDottedIPrefix_doesNotCrash() {
        let text = String(repeating: "İ", count: 60) + " needle here"
        let result = ClipboardItemRow.highlightedContent(text, highlight: "needle")
        XCTAssertTrue(String(result.characters).contains("needle"))
    }

    /// Regression guard: ordinary case-insensitive match keeps working.
    func testHighlightedContent_plainCaseMismatch_stillHighlights() {
        let result = ClipboardItemRow.highlightedContent("große straße mit Needle drin", highlight: "needle")
        XCTAssertTrue(String(result.characters).contains("Needle"))
    }
}
