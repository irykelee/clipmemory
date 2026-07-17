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
}
