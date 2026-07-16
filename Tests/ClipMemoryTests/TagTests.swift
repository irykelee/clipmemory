import XCTest
@testable import ClipMemory

final class TagTests: XCTestCase {

    // MARK: - Init / Equatable / Hashable

    func testInitDefaults() {
        // Default: empty name, neutral gray, user-created, fresh timestamp
        let tag = Tag(id: UUID(), name: "工作", colorHex: "#4ECDC4")
        XCTAssertEqual(tag.name, "工作")
        XCTAssertEqual(tag.colorHex, "#4ECDC4")
        XCTAssertFalse(tag.isAutoSuggested, "New tags default to user-created")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(tag.createdAt), 1.0)
    }

    func testEquatable() {
        let id = UUID()
        let a = Tag(id: id, name: "代码", colorHex: "#FF6B6B", isAutoSuggested: true, createdAt: Date(timeIntervalSince1970: 1000))
        let b = Tag(id: id, name: "代码", colorHex: "#FF6B6B", isAutoSuggested: true, createdAt: Date(timeIntervalSince1970: 1000))
        let c = Tag(id: id, name: "代码", colorHex: "#FF6B6B", isAutoSuggested: false, createdAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(a, b, "Same fields should be equal")
        XCTAssertNotEqual(a, c, "isAutoSuggested should affect equality")
    }

    func testHashable() {
        let id = UUID()
        let a = Tag(id: id, name: "X", colorHex: "#000000")
        let b = Tag(id: id, name: "X", colorHex: "#000000")
        var set = Set<Tag>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Identical tags should collapse to one Set entry")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = Tag(id: UUID(), name: "邮箱", colorHex: "#F7DC6F", isAutoSuggested: true, createdAt: Date(timeIntervalSince1970: 1700000000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Tag.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Preset colors

    func testPresetColorsAreNonEmpty() {
        XCTAssertGreaterThan(Tag.presetColors.count, 4,
                             "Need at least 5 preset colors so users can pick")
    }

    func testPresetColorsAreValidHex() {
        let hex = CharacterSet(charactersIn: "#0123456789ABCDEFabcdef")
        for color in Tag.presetColors {
            XCTAssertEqual(color.count, 7, "Color must be 7 chars: \(color)")
            XCTAssertTrue(color.unicodeScalars.allSatisfy { hex.contains($0) },
                          "Color must be valid hex: \(color)")
        }
    }
}

// MARK: - ClipboardStore tag dictionary API

final class ClipboardStoreTagTests: XCTestCase {

    /// Each ClipboardStore instance gets its own in-memory tag dictionary.
    /// Tags are keyed by UUID for O(1) lookup; the store is the source of truth.
    func testTagsDictionaryStartsEmpty() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        XCTAssertTrue(store.tags.isEmpty, "Fresh store should have zero tags")
    }

    /// addTag inserts the tag keyed by its id; querying by id returns the same instance.
    func testAddTagStoresTagById() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        XCTAssertEqual(store.tags[tag.id], tag)
    }
}