import XCTest
@testable import ClipMemory

/// Model CLIP-2 (2026-07-24 audit): TagSuggestion.containsEmail validated
/// the TLD against everything after the FIRST dot of the raw remainder,
/// which produced three false-negative classes:
///   1. mid-sentence emails ("mail bob@example.com please" → TLD candidate
///      "com please" contains a space → rejected);
///   2. trailing punctuation ("bob@example.com." → "com." rejected);
///   3. subdomains ("bob@mail.example.com" → "example.com" rejected).
/// The fix truncates the domain candidate at the first whitespace, strips
/// trailing punctuation, and validates against the LAST dot. These tests
/// go through the public `detect(for:content:)` API (kind == .email), the
/// same path the tag picker consumes.
final class TagSuggestionEmailBoundaryTests: XCTestCase {

    private func kind(for content: String) -> KindFacet {
        TagSuggestion.detect(for: .text, content: content).kind
    }

    // MARK: - Positives (previously missed)

    /// Baseline: bare email still detects (guard against over-correction).
    func testBareEmailStillDetected() {
        XCTAssertEqual(kind(for: "alice@example.com"), .email)
    }

    /// Existing behavior kept: email with text before it.
    func testEmailWithPrefixStillDetected() {
        XCTAssertEqual(kind(for: "at alice@example.com"), .email)
    }

    /// Mid-sentence: text on BOTH sides. The old TLD candidate swallowed
    /// the trailing words and failed the all-letters check.
    func testEmailMidSentenceDetected() {
        XCTAssertEqual(kind(for: "Contact bob@example.com please"), .email)
    }

    /// Trailing sentence punctuation must not poison the TLD check.
    func testEmailWithTrailingPeriodDetected() {
        XCTAssertEqual(kind(for: "bob@example.com."), .email)
    }

    func testEmailWithTrailingCommaDetected() {
        XCTAssertEqual(kind(for: "write to bob@example.com, then wait"), .email)
    }

    /// Subdomain: the LAST dot determines the TLD, not the first.
    func testSubdomainEmailDetected() {
        XCTAssertEqual(kind(for: "alice@mail.example.com"), .email)
    }

    /// Subdomain + multi-part TLD.
    func testSubdomainMultiPartTldDetected() {
        XCTAssertEqual(kind(for: "mail me at alice@mail.example.co.uk"), .email)
    }

    /// Newline terminates the token the same way a space does.
    func testEmailFollowedByNewlineDetected() {
        XCTAssertEqual(kind(for: "send to alice@example.com\nnext line"), .email)
    }

    // MARK: - Negatives (must stay rejected)

    /// No dot in the domain → not an email.
    func testDomainWithoutDotRejected() {
        XCTAssertNotEqual(kind(for: "alice@example"), .email)
    }

    /// Empty domain label before the dot.
    func testEmptyDomainLabelRejected() {
        XCTAssertNotEqual(kind(for: "alice@.com"), .email)
    }

    /// One-character TLD is below the >= 2 floor.
    func testSingleCharTldRejected() {
        XCTAssertNotEqual(kind(for: "alice@example.c"), .email)
    }

    /// Digits in the TLD candidate — version strings, not emails.
    func testDigitInTldRejected() {
        XCTAssertNotEqual(kind(for: "alice@example.c1"), .email)
    }

    /// Domain that is only punctuation after the @ — nothing to validate.
    func testPunctuationOnlyDomainRejected() {
        XCTAssertNotEqual(kind(for: "alice@..."), .email)
    }

    /// No @ at all — decimal numbers must not trip the dot/TLD logic.
    func testVersionStringRejected() {
        XCTAssertNotEqual(kind(for: "version 3.2 is out"), .email)
    }
}
