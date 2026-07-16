import XCTest
@testable import ClipMemory

/// Validates NewTagLogic — pure helpers backing NewTagSheet (sidebar's
/// "+ 新建标签" entry). The sheet itself is a SwiftUI view; the decision
/// logic lives here so we can unit-test it.
final class NewTagLogicTests: XCTestCase {

    /// Submitting a fresh name → store.addTag with isAutoSuggested=false
    /// and the chosen color. This is the sidebar path, distinct from the
    /// TagPickerSheet path where accepting a suggestion sets isAutoSuggested
    /// to true.
    func testSubmitNewNameCreatesManualTag() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let result = NewTagLogic.submit(name: "工作笔记", colorHex: "#FF6B6B", store: store)
        switch result {
        case .created(let id):
            let tag = store.tags[id]
            XCTAssertNotNil(tag)
            XCTAssertEqual(tag?.name, "工作笔记")
            XCTAssertEqual(tag?.colorHex, "#FF6B6B")
            XCTAssertFalse(tag?.isAutoSuggested ?? true,
                           "Sidebar manual path must set isAutoSuggested=false")
        case .reused:
            XCTFail("Fresh name should not be reused")
        case .none:
            XCTFail("Fresh name should not return nil")
        }
    }

    /// Submitting an existing name → return existing tag id, no new tag
    /// created. Mirrors the "使用现有" path in TagPickerSheet.
    func testSubmitExistingNameReturnsExisting() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let existing = Tag(name: "代码", colorHex: "#4ECDC4")
        store.addTag(existing)

        let result = NewTagLogic.submit(name: "代码", colorHex: "#FF6B6B", store: store)

        switch result {
        case .reused(let id):
            XCTAssertEqual(id, existing.id)
            XCTAssertEqual(store.tags.count, 1, "No new tag should be created")
        case .created:
            XCTFail("Existing name should be reused, not created")
        case .none:
            XCTFail("Existing name should not return nil")
        }
    }

    /// Whitespace-only name is rejected — no tag created, returns nil.
    func testSubmitWhitespaceNameReturnsNil() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let result = NewTagLogic.submit(name: "   ", colorHex: "#FF6B6B", store: store)
        XCTAssertNil(result)
        XCTAssertTrue(store.tags.isEmpty)
    }

    /// Name comparison trims whitespace so "代码" and " 代码 " match.
    func testSubmitExistingNameTrimsWhitespace() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let existing = Tag(name: "代码", colorHex: "#4ECDC4")
        store.addTag(existing)

        let result = NewTagLogic.submit(name: "  代码  ", colorHex: "#FF6B6B", store: store)
        switch result {
        case .reused(let id):
            XCTAssertEqual(id, existing.id)
        case .created:
            XCTFail("Trimmed name should match existing tag")
        case .none:
            XCTFail("Trimmed existing name should not return nil")
        }
    }
}