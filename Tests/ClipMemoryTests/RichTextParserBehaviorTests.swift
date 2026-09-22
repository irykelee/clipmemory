import XCTest
import AppKit
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-19): behavior tests for `Utils/RichTextParser.swift`.
/// The audit found the malformed-base64 and empty-input fallback branches
/// were untested — any future regression in the guard sequence would ship
/// silently and crash callers that pass non-RTF strings. These tests
/// exercise the actual public API (two `plaintext(from:fallback:)` overloads)
/// with garbage, empty, valid-base64-but-not-RTF, and hand-rolled valid RTF
/// inputs.
///
/// Adapted from brief: brief used `RichTextParser.parse(...)` placeholder;
/// the actual API is `RichTextParser.plaintext(from base64RTF:fallback:)`
/// and `RichTextParser.plaintext(from rtfData:fallback:)`.
final class RichTextParserBehaviorTests: XCTestCase {

  // Hand-rolled minimum-valid RTF: contains plaintext "Hello" after parsing.
  // Same fixture as ClipboardStoreRTFCacheTests; reproducing it here keeps
  // this test file self-contained (no need to import the RTF-cache test seam).
  private let validRTF = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2512\n{\\colortbl;\\red255\\green255\\blue255;}\n\\pard\\tx560\\tx1120\\tx1680\\tx2240\\tx2800\\tx3360\\tx3920\\tx4480\\tx5040\\tx5600\\tx6160\\tx6720\\li0\\ri0\\sa200\\sl240\\slmult1\\f0\\fs24 \\cf0 Hello\\cf0  }"
  private var validRTFBase64: String { Data(validRTF.utf8).base64EncodedString() }

  // MARK: - Base64 string overload: fallback branches

  /// Empty input must return the default fallback ("Rich Text") and not
  /// crash. The chip UI relies on this — if it returned "" the rich-text
  /// chip would render blank.
  func testEmptyStringReturnsDefaultFallback() {
    let result = RichTextParser.plaintext(from: "")
    XCTAssertEqual(result, "Rich Text",
                   "P2-19: empty input must return default fallback 'Rich Text'")
  }

  /// Empty input with a caller-provided fallback must return that
  /// fallback verbatim. Pins the parameter pass-through.
  func testEmptyStringReturnsCustomFallback() {
    let result = RichTextParser.plaintext(from: "", fallback: "custom-fallback")
    XCTAssertEqual(result, "custom-fallback",
                   "P2-19: empty input must return caller-provided fallback")
  }

  /// Malformed base64 (`!!!invalid base64!!!` is not valid base64) must
  /// hit the `Data(base64Encoded:)` nil branch and return the default
  /// fallback. The brief flagged this branch as untested.
  func testMalformedBase64ReturnsDefaultFallback() {
    let result = RichTextParser.plaintext(from: "!!!invalid base64!!!")
    XCTAssertEqual(result, "Rich Text",
                   "P2-19: malformed base64 must return default fallback")
  }

  /// Valid base64 of arbitrary non-RTF bytes must also hit the fallback
  /// (NSAttributedString RTF parse fails). Pins the second guard branch.
  func testValidBase64OfGarbageBytesReturnsDefaultFallback() {
    let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF]).base64EncodedString()
    let result = RichTextParser.plaintext(from: garbage)
    XCTAssertEqual(result, "Rich Text",
                   "P2-19: valid base64 of non-RTF bytes must return fallback")
  }

  // MARK: - Base64 string overload: happy path

  /// Valid base64-encoded RTF must round-trip to the embedded plaintext.
  /// Pins that the parser actually parses (not just passes through).
  func testValidBase64RTFReturnsParsedPlaintext() {
    let result = RichTextParser.plaintext(from: validRTFBase64)
    XCTAssertTrue(result.contains("Hello"),
                  "P2-19: valid RTF base64 must parse to embedded plaintext, got: \(result)")
  }

  // MARK: - Data overload

  /// Empty Data must return the Data-overload's default fallback ("" by
  /// spec — the base64 overload's "Rich Text" default is a presentation
  /// concern; the Data overload is for raw pasteboard bytes where the
  /// caller chooses the display strategy).
  func testEmptyDataReturnsDefaultFallback() {
    let result = RichTextParser.plaintext(from: Data())
    XCTAssertEqual(result, "",
                   "P2-19: empty Data must return empty default fallback")
  }

  /// Valid RTF Data must parse to the embedded plaintext.
  func testValidRTFDataReturnsParsedPlaintext() {
    let data = Data(validRTF.utf8)
    let result = RichTextParser.plaintext(from: data)
    XCTAssertTrue(result.contains("Hello"),
                  "P2-19: valid RTF Data must parse to embedded plaintext, got: \(result)")
  }

  /// Non-RTF Data must hit the fallback path. The guard
  /// `try? NSAttributedString(data:options:...)` returns nil on garbage
  /// and the function returns fallback.
  func testInvalidRTFDataReturnsCustomFallback() {
    let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
    let result = RichTextParser.plaintext(from: garbage, fallback: "raw-fallback")
    XCTAssertEqual(result, "raw-fallback",
                   "P2-19: invalid RTF Data must return caller-provided fallback")
  }

  // MARK: - Default fallback parameter value

  /// Pins that the default `fallback` parameter is the localized-friendly
  /// "Rich Text" placeholder. A regression that changed the default to
  /// "" would silently blank rich-text chips.
  func testDefaultFallbackIsRichText() {
    // Trigger the fallback branch via empty input — the function will
    // use the default parameter value, which we pin here.
    let result = RichTextParser.plaintext(from: "")
    XCTAssertEqual(result, "Rich Text",
                   "P2-19: default fallback must be 'Rich Text' for chip rendering")
  }
}