import XCTest
@testable import ClipMemory

/// Secondary CLIP-3 (2026-07-24 audit): TagPickerSheet.loadSuggestions ran
/// the full TagSuggestion pipeline twice per sheet open — once via
/// `detect(for:content:)` and again via `suggest(for:content:)`, which
/// internally re-detects (trim + heuristics + NLTagger, on the main
/// thread). The kind → tag-name mapping is now exposed as
/// `TagSuggestion.tagNames(for:)` so the picker derives names from the
/// facets it already computed. These tests lock the mapping itself and
/// the equivalence between the shim and the derived path.
final class TagSuggestionTagNamesTests: XCTestCase {

    /// Each non-plain kind maps to exactly its localized tag name.
    /// Assertions reference L10n rather than hardcoded strings so the suite
    /// passes regardless of the host's system language.
    func testTagNamesMapsEachKindToItsLocalizedName() {
        XCTAssertEqual(TagSuggestion.tagNames(for: .code), [L10n.tagSuggestionKindCode])
        XCTAssertEqual(TagSuggestion.tagNames(for: .email), [L10n.tagSuggestionKindEmail])
        XCTAssertEqual(TagSuggestion.tagNames(for: .credential), [L10n.tagSuggestionKindCredential])
        XCTAssertEqual(TagSuggestion.tagNames(for: .sensitive), [L10n.tagSuggestionKindSensitive])
    }

    /// Plain content shape → no tag names (nothing to auto-suggest).
    func testTagNamesPlainReturnsEmpty() {
        XCTAssertTrue(TagSuggestion.tagNames(for: .plain).isEmpty)
    }

    /// Every KindFacet case is handled — a future case added to the enum
    /// without a mapping here fails loudly instead of silently dropping
    /// suggestions.
    func testTagNamesCoversAllKindCases() {
        for kind in KindFacet.allCases {
            let names = TagSuggestion.tagNames(for: kind)
            if kind == .plain {
                XCTAssertTrue(names.isEmpty)
            } else {
                XCTAssertEqual(names.count, 1, "Kind \(kind) lost its tag-name mapping")
            }
        }
    }

    /// Equivalence guard: the picker's new derivation
    /// (`tagNames(for: detect(...).kind)`) must produce exactly what the
    /// old second `suggest(for:content:)` call returned. If these drift,
    /// the sheet's suggestion chips change behavior.
    func testSuggestShimEqualsTagNamesDerivedFromDetect() {
        let contents = [
            "func greet() { print(\"hi\") }",   // code
            "alice@example.com",                // email
            "ABCDEFGHIJKLMNOPabcdef1234",       // credential
            "我的密码是 123456",                  // sensitive
            "hello world",                      // plain
            ""                                  // empty
        ]
        for content in contents {
            let viaShim = TagSuggestion.suggest(for: .text, content: content)
            let viaFacets = TagSuggestion.tagNames(
                for: TagSuggestion.detect(for: .text, content: content).kind
            )
            XCTAssertEqual(viaShim, viaFacets, "Shim vs facet-derived mismatch for: \(content)")
        }
    }
}
