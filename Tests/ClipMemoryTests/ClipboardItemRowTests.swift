import XCTest
import SwiftUI
@testable import ClipMemory

/// ClipboardItemRow is Equatable so SwiftUI can avoid redundant redraws.
/// The custom == must account for every field that affects the rendered
/// output, including fields nested inside `item`.
final class ClipboardItemRowTests: XCTestCase {

    /// Regression: createdAt and decryptionFailed were once omitted from ==,
    /// causing two rows that differed only in those fields to compare equal
    /// and skip updates.
    func testEquatableIncludesCreatedAtAndDecryptionFailed() {
        let id = UUID()
        let base = ClipboardItem(
            id: id,
            content: "hello",
            type: .text,
            createdAt: Date(timeIntervalSince1970: 1000),
            isPinned: false,
            isSensitive: false
        )
        let differentDate = ClipboardItem(
            id: id,
            content: "hello",
            type: .text,
            createdAt: Date(timeIntervalSince1970: 2000),
            isPinned: false,
            isSensitive: false
        )
        let differentDecryption = ClipboardItem(
            id: id,
            content: "hello",
            type: .text,
            createdAt: Date(timeIntervalSince1970: 1000),
            isPinned: false,
            isSensitive: false,
            decryptionFailed: true
        )

        let rowA = ClipboardItemRow(
            item: base,
            isRevealed: false,
            onPin: {},
            onDelete: {},
            onToggleReveal: {}
        )
        let rowB = ClipboardItemRow(
            item: differentDate,
            isRevealed: false,
            onPin: {},
            onDelete: {},
            onToggleReveal: {}
        )
        let rowC = ClipboardItemRow(
            item: differentDecryption,
            isRevealed: false,
            onPin: {},
            onDelete: {},
            onToggleReveal: {}
        )

        XCTAssertNotEqual(rowA, rowB, "Rows should differ when createdAt differs")
        XCTAssertNotEqual(rowA, rowC, "Rows should differ when decryptionFailed differs")
    }

    // MARK: - H-7/H-8 (2026-07-24 audit)

    /// Minimum-valid RTF containing plaintext "Hello" after parsing. Mirrors
    /// ClipboardStoreRTFCacheTests.validRTF so the same fixture passes both
    /// layers. Keep in sync if the parser changes.
    private let validRTF = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2512\n{\\colortbl;\\red255\\green255\\blue255;}\n\\pard\\tx560\\tx1120\\tx1680\\tx2240\\tx2800\\tx3360\\tx3920\\tx4480\\tx5040\\tx5600\\tx6160\\tx6720\\li0\\ri0\\sa200\\sl240\\slmult1\\f0\\fs24 \\cf0 Hello\\cf0  }"
    private var validRTFBase64: String { Data(validRTF.utf8).base64EncodedString() }

    /// H-7/H-8: NSAttributedString RTF parse is a pure function. Extracting it
    /// to a static helper lets `loadRichText` invoke it via Task.detached so
    /// the 20–100ms parse doesn't block the main thread. This test asserts
    /// the helper returns AttributedString + plain text for a valid RTF.
    func testParseRichText_validRTF_returnsAttributedAndPlain() {
        let result = ClipboardItemRow.parseRichText(base64: validRTFBase64)
        XCTAssertNotNil(result, "Valid RTF must parse to non-nil result")
        XCTAssertTrue(result?.plain.contains("Hello") ?? false,
                      "Parsed plaintext must contain the RTF body text (\"Hello\")")
        XCTAssertFalse(result?.attributed.characters.isEmpty ?? true,
                       "Parsed AttributedString must not be empty")
    }

    /// H-7/H-8: bad base64 input → nil (no throw, no crash). loadRichText's
    /// caller treats nil as "skip", so a malformed item shows the placeholder.
    func testParseRichText_invalidBase64_returnsNil() {
        XCTAssertNil(ClipboardItemRow.parseRichText(base64: "this is not valid base64!!!"))
    }

    /// H-7/H-8: empty input → nil. Defensive — pasteboard with empty base64
    /// shouldn't trap.
    func testParseRichText_emptyString_returnsNil() {
        XCTAssertNil(ClipboardItemRow.parseRichText(base64: ""))
    }

    /// H-7/H-8: valid base64 but garbage RTF body → nil. NSAttributedString
    /// rejects with try? and the helper propagates nil.
    func testParseRichText_validBase64InvalidRTF_returnsNil() {
        let garbage = Data("this is not RTF at all".utf8).base64EncodedString()
        XCTAssertNil(ClipboardItemRow.parseRichText(base64: garbage))
    }
}
