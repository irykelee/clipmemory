import XCTest
@testable import ClipMemory

/// ID-PERF-0018 (2026-07-31 audit): `TagSuggestion.detect` had no input
/// length cap, so an oversized clipboard item (long text / big RTF
/// plaintext) made the regex + NLTagger pipeline unbounded. Analysis now
/// truncates to the first `maxAnalysisLength` characters before classifying.
final class TagSuggestionLengthCapTests: XCTestCase {

    func testDetect_oversizedContent_rawTextIsCapped() {
        let huge = String(repeating: "a", count: 500_000)
        let facets = TagSuggestion.detect(for: .text, content: huge)
        XCTAssertLessThanOrEqual(facets.rawText.count, TagSuggestion.maxAnalysisLength,
                                 "rawText must reflect the truncated analysis input")
    }

    /// A signal token past the cap must NOT be analyzed — proves truncation
    /// happens BEFORE classification, not just on the stored rawText.
    func testDetect_signalBeyondCap_isNotDetected() {
        let padded = String(repeating: "x ", count: 20_000) + " bob@example.com"
        let facets = TagSuggestion.detect(for: .text, content: padded)
        XCTAssertNotEqual(facets.kind, .email,
                          "content past maxAnalysisLength must be excluded from analysis")
    }

    /// A signal token inside the cap is still detected (no behavior
    /// regression for normal-size items).
    func testDetect_signalInsideCap_stillDetected() {
        let facets = TagSuggestion.detect(for: .text, content: "contact bob@example.com please")
        XCTAssertEqual(facets.kind, .email)
    }
}
