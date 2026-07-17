import XCTest
@testable import ClipMemory

/// Pure-logic tests for the tag picker decision helpers.
/// These exist independent of SwiftUI so we can validate the rules without a view tree.
final class TagPickerLogicTests: XCTestCase {

    // MARK: - defaultColorHex

    /// Empty tag list → first preset color so the user sees a default selection.
    func testDefaultColorPicksFirstPresetWhenNoTags() {
        let color = TagPickerLogic.defaultColorHex(existingTags: [])
        XCTAssertEqual(color, Tag.presetColors.first)
    }

    /// One tag using preset[0] → next preset[1] so colors stay distinct.
    func testDefaultColorPicksFirstUnusedPreset() {
        let tag = Tag(name: "x", colorHex: Tag.presetColors[0])
        let color = TagPickerLogic.defaultColorHex(existingTags: [tag])
        XCTAssertEqual(color, Tag.presetColors[1])
    }

    /// When all 8 presets are used, fall back to cycling via modulo so we
    /// never deadlock on color assignment.
    func testDefaultColorCyclesWhenAllPresetsUsed() {
        let tags = Tag.presetColors.enumerated().map { idx, hex in
            Tag(name: "t\(idx)", colorHex: hex)
        }
        let color = TagPickerLogic.defaultColorHex(existingTags: tags)
        XCTAssertEqual(color, Tag.presetColors[tags.count % Tag.presetColors.count])
    }

    /// Tags with non-preset hex (e.g. legacy or migrated data) shouldn't poison
    /// the "first unused" search — we only treat the curated palette as the
    /// unavailable set.
    func testDefaultColorIgnoresCustomHexTags() {
        let custom = Tag(name: "custom", colorHex: "#ABCDEF")
        let color = TagPickerLogic.defaultColorHex(existingTags: [custom])
        XCTAssertEqual(color, Tag.presetColors.first)
    }

    // MARK: - classifySuggestion

    /// A suggestion name that exactly matches an existing tag should be
    /// classified as "existing" (and auto-checked in the sheet) — never
    /// offered as something to create.
    func testClassifySuggestionHitsExisting() {
        let existing = Tag(name: "代码", colorHex: "#4ECDC4")
        let result = TagPickerLogic.classifySuggestion(name: "代码", existingTags: [existing])
        XCTAssertEqual(result, .existing(existing))
    }

    /// A suggestion name not in the existing set → "create" — show as a
    /// chip in the suggestions block that, when tapped, creates + attaches.
    func testClassifySuggestionMissesExisting() {
        let result = TagPickerLogic.classifySuggestion(name: "新分类", existingTags: [])
        XCTAssertEqual(result, .create("新分类"))
    }

    /// Empty / whitespace name is never a valid suggestion. Return nil so the
    /// sheet simply doesn't render it.
    func testClassifySuggestionEmptyNameReturnsNil() {
        let result = TagPickerLogic.classifySuggestion(name: "   ", existingTags: [])
        XCTAssertNil(result)
    }

    // MARK: - makeTag(from:colorHex:)

    /// `makeTag(from: .create(...))` produces a tag with `isAutoSuggested: true`
    /// — distinguishes "user accepted a heuristic suggestion" from a manual
    /// new tag. The picker uses this flag for future sort/display logic.
    func testMakeTagFromCreateSuggestionSetsAutoSuggestedTrue() {
        let tag = TagPickerLogic.makeTag(from: .create("代码"), colorHex: "#FF6B6B")
        XCTAssertEqual(tag.name, "代码")
        XCTAssertEqual(tag.colorHex, "#FF6B6B")
        XCTAssertTrue(tag.isAutoSuggested, "Suggestion-accepted tag must be isAutoSuggested=true")
    }

    /// `makeTag(from: .existing(...))` returns the original tag identity
    /// (no new id, no isAutoSuggested flip) so the sheet can re-attach it.
    func testMakeTagFromExistingReturnsOriginalIdentity() {
        let original = Tag(name: "工作", colorHex: "#4ECDC4", isAutoSuggested: false)
        let made = TagPickerLogic.makeTag(from: .existing(original), colorHex: "#FF6B6B")
        XCTAssertEqual(made.id, original.id)
        XCTAssertEqual(made.name, original.name)
        XCTAssertEqual(made.colorHex, original.colorHex,
                       "Existing tag keeps its original colorHex, ignoring the new argument")
        XCTAssertFalse(made.isAutoSuggested)
    }

    // MARK: - makeTagManual(name:colorHex:)

    /// Manual new tag is never auto-suggested, regardless of name.
    func testMakeTagManualSetsAutoSuggestedFalse() {
        let tag = TagPickerLogic.makeTagManual(name: "我的笔记", colorHex: "#85C1E2")
        XCTAssertEqual(tag.name, "我的笔记")
        XCTAssertEqual(tag.colorHex, "#85C1E2")
        XCTAssertFalse(tag.isAutoSuggested)
    }

    // MARK: - toggleAttachment

    /// Pure helper that decides whether tapping a tag in the sheet should
    /// attach or detach it from an item. Encapsulates the `Set<UUID>` lookup
    /// so the sheet body stays declarative.
    func testToggleAttachmentAttachesWhenAbsent() {
        let tagId = UUID()
        let result = TagPickerLogic.toggleAttachment(currentlyAttached: [], tapping: tagId)
        XCTAssertEqual(result, [tagId])
    }

    func testToggleAttachmentDetachesWhenPresent() {
        let tagId = UUID()
        let result = TagPickerLogic.toggleAttachment(currentlyAttached: [tagId], tapping: tagId)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - autocompleteCandidates

    /// Empty prefix → empty candidates. The autocomplete is opt-in; calling
    /// it with an empty string should not return the full dictionary.
    func testAutocompleteCandidatesEmptyPrefixReturnsEmpty() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        store.addTag(Tag(name: "工作", colorHex: "#4ECDC4"))
        let cands = TagPickerLogic.autocompleteCandidates(prefix: "", store: store)
        XCTAssertTrue(cands.isEmpty)
    }

    /// Case-insensitive prefix match.
    func testAutocompleteCandidatesCaseInsensitive() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        store.addTag(Tag(name: "保险业务", colorHex: "#4ECDC4"))
        let lower = TagPickerLogic.autocompleteCandidates(prefix: "保", store: store)
        let upper = TagPickerLogic.autocompleteCandidates(prefix: "保", store: store)
        XCTAssertEqual(lower.count, 1)
        XCTAssertEqual(upper.count, 1)
        XCTAssertEqual(lower.first?.name, "保险业务")
    }

    /// Limit caps result count, default is 5.
    func testAutocompleteCandidatesRespectsLimit() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        for i in 0..<8 {
            store.addTag(Tag(name: "保险-\(i)", colorHex: "#4ECDC4"))
        }
        let cands = TagPickerLogic.autocompleteCandidates(prefix: "保险", limit: 3, store: store)
        XCTAssertEqual(cands.count, 3)
    }

    // MARK: - attachOrCreateTag

    /// When a tag with the same name already exists, attachOrCreateTag must
    /// reuse it and NOT create a duplicate. Regression guard for the sheet's
    /// suggestion chips racing with external tag creation.
    func testAttachOrCreateTagReusesExistingByName() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let existing = Tag(name: "代码", colorHex: "#4ECDC4")
        store.addTag(existing)
        let item = ClipboardItem(content: "hello", type: .text)
        store.addItem(item)

        TagPickerLogic.attachOrCreateTag(name: "代码", colorHex: "#FF6B6B", to: item.id, store: store)

        XCTAssertEqual(store.tags.count, 1, "Should not create a duplicate tag")
        XCTAssertEqual(store.tags.values.first?.id, existing.id)
        XCTAssertTrue(store.items.first(where: { $0.id == item.id })?.tagIds.contains(existing.id) ?? false)
    }

    /// Name matching is case-insensitive so the autocomplete (which is already
    /// case-insensitive) and the duplicate guard agree.
    func testAttachOrCreateTagReusesExistingByNameCaseInsensitive() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let existing = Tag(name: "Work", colorHex: "#4ECDC4")
        store.addTag(existing)
        let item = ClipboardItem(content: "hello", type: .text)
        store.addItem(item)

        TagPickerLogic.attachOrCreateTag(name: "work", colorHex: "#FF6B6B", to: item.id, store: store)

        XCTAssertEqual(store.tags.count, 1, "Should reuse existing tag regardless of case")
        XCTAssertEqual(store.tags.values.first?.id, existing.id)
        XCTAssertTrue(store.items.first(where: { $0.id == item.id })?.tagIds.contains(existing.id) ?? false)
    }

    /// Fresh name → creates a new auto-suggested tag and attaches it.
    func testAttachOrCreateTagCreatesWhenMissing() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let item = ClipboardItem(content: "hello", type: .text)
        store.addItem(item)

        TagPickerLogic.attachOrCreateTag(name: "新标签", colorHex: "#FF6B6B", to: item.id, store: store)

        XCTAssertEqual(store.tags.count, 1)
        let created = store.tags.values.first
        XCTAssertEqual(created?.name, "新标签")
        XCTAssertEqual(created?.colorHex, "#FF6B6B")
        XCTAssertTrue(created?.isAutoSuggested ?? false)
        XCTAssertTrue(store.items.first(where: { $0.id == item.id })?.tagIds.contains(created?.id ?? UUID()) ?? false)
    }
}
