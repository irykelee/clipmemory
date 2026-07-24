import XCTest
@testable import ClipMemory

/// Secondary CLIP-2 (2026-07-24 audit): pressing Return inside
/// TagPickerSheet's new-tag TextField fell through to the header Done
/// button (`.keyboardShortcut(.defaultAction)`) and dismissed the sheet,
/// discarding the in-progress draft. The TextField now routes Return via
/// `.onSubmit` into the same submit path as the Create / Use-existing
/// button, extracted to `TagPickerSheet.submitNewTag(name:colorHex:itemId:store:)`
/// so it's testable without a view tree.
final class TagPickerSheetSubmitTests: XCTestCase {

    private var store: ClipboardStore!
    private var item: ClipboardItem!

    override func setUp() {
        super.setUp()
        store = ClipboardStore(backend: MemoryStorageBackend())
        item = ClipboardItem(content: "hello", type: .text)
        store.addItem(item)
    }

    override func tearDown() {
        item = nil
        store = nil
        super.tearDown()
    }

    private func liveItem() -> ClipboardItem? {
        store.items.first { $0.id == item.id }
    }

    /// Fresh name → creates a manual (not auto-suggested) tag and attaches
    /// it. This is the path Return now takes instead of dismissing.
    func testSubmitCreatesAndAttachesNewTag() {
        let submitted = TagPickerSheet.submitNewTag(
            name: "工作", colorHex: "#FF6B6B", itemId: item.id, store: store
        )
        XCTAssertTrue(submitted)
        XCTAssertEqual(store.tags.count, 1)
        let tag = store.tags.values.first
        XCTAssertEqual(tag?.name, "工作")
        XCTAssertEqual(tag?.colorHex, "#FF6B6B")
        XCTAssertEqual(tag?.isAutoSuggested, false, "Manual creation must not flip isAutoSuggested")
        XCTAssertTrue(liveItem()?.tagIds.contains(tag?.id ?? UUID()) ?? false)
    }

    /// Name matching an existing tag (case-insensitive) → reuse, no
    /// duplicate — mirrors the button's "Use existing" behavior.
    func testSubmitReusesExistingTagCaseInsensitive() {
        let existing = Tag(name: "Work", colorHex: "#4ECDC4")
        store.addTag(existing)

        let submitted = TagPickerSheet.submitNewTag(
            name: "work", colorHex: "#FF6B6B", itemId: item.id, store: store
        )

        XCTAssertTrue(submitted)
        XCTAssertEqual(store.tags.count, 1, "Must not create a duplicate tag")
        XCTAssertTrue(liveItem()?.tagIds.contains(existing.id) ?? false)
    }

    /// Whitespace around the name is trimmed before the duplicate check and
    /// creation — "  工作  " must not create a second "工作".
    func testSubmitTrimsWhitespace() {
        let existing = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(existing)

        let submitted = TagPickerSheet.submitNewTag(
            name: "  工作  ", colorHex: "#FF6B6B", itemId: item.id, store: store
        )

        XCTAssertTrue(submitted)
        XCTAssertEqual(store.tags.count, 1)
        XCTAssertTrue(liveItem()?.tagIds.contains(existing.id) ?? false)
    }

    /// Empty / whitespace-only name → not submitted, nothing created,
    /// nothing attached. The sheet keeps the draft open (the view-level
    /// guard), so Return on an empty field is a no-op rather than either
    /// dismissing the sheet or creating an unnamed tag.
    func testSubmitEmptyNameIsRejected() {
        for name in ["", "   ", " \n\t "] {
            let submitted = TagPickerSheet.submitNewTag(
                name: name, colorHex: "#FF6B6B", itemId: item.id, store: store
            )
            XCTAssertFalse(submitted, "Empty name must not submit: \(name.debugDescription)")
        }
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertTrue(liveItem()?.tagIds.isEmpty ?? false)
    }
}
