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

    /// Attaching a tag id to an item mutates the item's tagIds set so the
    /// sidebar filter can match by tag in O(1).
    func testAttachTagToItemAppendsTagId() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let item = ClipboardItem(content: "hello", type: .text)
        store.items.append(item)
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.addTag(to: item.id, tagId: tag.id)
        XCTAssertTrue(store.items[0].tagIds.contains(tag.id))
    }

    /// Removing a tag id strips it from the item's tagIds set without
    /// touching other tags on the same item.
    func testRemoveTagFromItemStripsTagId() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let item = ClipboardItem(content: "hello", type: .text)
        store.items.append(item)
        let a = Tag(name: "工作", colorHex: "#4ECDC4")
        let b = Tag(name: "学习", colorHex: "#FF6B6B")
        store.addTag(a); store.addTag(b)
        store.addTag(to: item.id, tagId: a.id)
        store.addTag(to: item.id, tagId: b.id)
        store.removeTag(from: item.id, tagId: a.id)
        XCTAssertFalse(store.items[0].tagIds.contains(a.id))
        XCTAssertTrue(store.items[0].tagIds.contains(b.id), "Other tags should be untouched")
    }
}

// MARK: - TagSuggestion heuristic engine

final class TagSuggestionTests: XCTestCase {

    /// Empty content has no signals — empty suggestions.
    func testEmptyContentReturnsEmpty() {
        XCTAssertTrue(TagSuggestion.suggest(for: .text, content: "").isEmpty)
    }

    /// Pure whitespace has no signals either.
    func testWhitespaceOnlyContentReturnsEmpty() {
        XCTAssertTrue(TagSuggestion.suggest(for: .text, content: "   \n\t  ").isEmpty)
    }

    /// A snippet with code markers ({, ;, =>, func, def) suggests "代码".
    func testCodeSnippetSuggestsCode() {
        let suggestions = TagSuggestion.suggest(for: .text, content: "func greet() { print(\"hi\") }")
        XCTAssertTrue(suggestions.contains("代码"), "Should detect code markers: \(suggestions)")
    }

    /// An email address triggers "邮箱".
    func testEmailContentSuggestsMail() {
        let suggestions = TagSuggestion.suggest(for: .text, content: "alice@example.com")
        XCTAssertTrue(suggestions.contains("邮箱"), "Should detect email: \(suggestions)")
    }

    /// Email embedded in surrounding text also triggers.
    func testEmailWithPrefix() {
        let s = TagSuggestion.suggest(for: .text, content: "at alice@example.com")
        XCTAssertTrue(s.contains("邮箱"), "prefix email failed: \(s)")
    }

    /// A long alphanumeric token (API key shape) suggests "账号".
    func testLongAlphanumericTokenSuggestsAccount() {
        let suggestions = TagSuggestion.suggest(for: .text, content: "token=abcdef1234567890ABCDEF")
        XCTAssertTrue(suggestions.contains("账号"), "Should detect account-like token: \(suggestions)")
    }

    /// Content with sensitive keywords (密码/密钥/token/password) suggests "敏感".
    func testSensitiveKeywordsSuggestSensitive() {
        let suggestions = TagSuggestion.suggest(for: .text, content: "我的密码是 123456")
        XCTAssertTrue(suggestions.contains("敏感"), "Should detect sensitive keywords: \(suggestions)")
    }

    /// Mixed CJK content suggests "中文".
    func testCJKContentSuggestsChinese() {
        let suggestions = TagSuggestion.suggest(for: .text, content: "你好世界")
        XCTAssertTrue(suggestions.contains("中文"), "Should detect CJK: \(suggestions)")
    }

    /// Latin word content suggests "English".
    func testLatinContentSuggestsEnglish() {
        let suggestions = TagSuggestion.suggest(for: .text, content: "The quick brown fox")
        XCTAssertTrue(suggestions.contains("English"), "Should detect Latin: \(suggestions)")
    }
}
