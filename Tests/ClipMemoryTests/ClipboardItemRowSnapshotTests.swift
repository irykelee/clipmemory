import XCTest
import SwiftUI
@testable import ClipMemory

/// Snapshot baselines for ClipboardItemRow.
///
/// Phase 1 of NEW-7: covers the most common rendering paths so that
/// subsequent ContentView refactors catch visual regressions before
/// merging. Two cases: a plain text item (default render) and a
/// sensitive text item (masked render path with bullet substitution
/// and orange tint).
///
/// ClipboardItem init (line 39 of ClipboardItem.swift): all parameters
/// after `type:` default to sensible values, so the tests supply only
/// the four that matter for visual differentiation.
final class ClipboardItemRowSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        snapshotTestSetUp()
    }

    override func tearDown() {
        snapshotTestTearDown()
        super.tearDown()
    }

    /// Renders a plain text item with `searchText = ""` and
    /// `isRevealed = false`. Captures the default, non-highlighted path
    /// with no selection state.
    @MainActor
    func testRendersPlainTextItem() {
        let item = ClipboardItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            content: "Hello, world!",
            type: .text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: false,
            isSensitive: false
        )
        let row = ClipboardItemRow(
            item: item,
            isRevealed: false,
            isKeyboardSelected: false,
            isCopied: false,
            isSelected: false,
            searchText: "",
            onCopyWithFeedback: nil,
            onPin: {},
            onDelete: {},
            onSelect: nil,
            onToggleReveal: {},
            onEditTags: {}
        )
        let image = renderToImage(row, size: CGSize(width: 600, height: 80))
        assertImageSnapshot(
            image,
            className: "ClipboardItemRowSnapshotTests",
            testName: "testRendersPlainTextItem"
        )
    }

    /// Renders a sensitive item in the masked (default) state. The masked
    /// path replaces content with bullet characters and tints them orange
    /// (visible regression sentinel for masking logic).
    @MainActor
    func testRendersSensitiveItemMasked() {
        let item = ClipboardItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            content: "AAbbCCddEEffGGhh11-22-33-44-55-66-77-88",
            type: .text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: false,
            isSensitive: true
        )
        let row = ClipboardItemRow(
            item: item,
            isRevealed: false,
            isKeyboardSelected: false,
            isCopied: false,
            isSelected: false,
            searchText: "",
            onCopyWithFeedback: nil,
            onPin: {},
            onDelete: {},
            onSelect: nil,
            onToggleReveal: {},
            onEditTags: {}
        )
        let image = renderToImage(row, size: CGSize(width: 600, height: 80))
        assertImageSnapshot(
            image,
            className: "ClipboardItemRowSnapshotTests",
            testName: "testRendersSensitiveItemMasked"
        )
    }
}