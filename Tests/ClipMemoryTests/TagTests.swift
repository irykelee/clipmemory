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
        // Pin a single Date instance so both tags share its hash exactly.
        // Swift Date's `==` uses a tolerance but `hashValue` does not, so
        // two separate Date() calls in close succession can compare equal
        // yet hash differently — making the test flaky on slow runners.
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let a = Tag(id: id, name: "X", colorHex: "#000000", createdAt: ts)
        let b = Tag(id: id, name: "X", colorHex: "#000000", createdAt: ts)
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

    /// Deleting a tag removes it from the dictionary.
    func testDeleteTagRemovesFromDictionary() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.deleteTag(id: tag.id)
        XCTAssertNil(store.tags[tag.id], "Tag should be removed from dictionary")
    }

    /// Deleting a tag also strips its id from every attached item — no dangling UUIDs.
    /// Two items: one with the deleted tag and one without. After deleteTag, only
    /// the first should have its tagIds set shrunk.
    func testDeleteTagStripsFromAllItems() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let itemA = ClipboardItem(content: "alpha", type: .text)
        let itemB = ClipboardItem(content: "beta", type: .text)
        store.items.append(itemA)
        store.items.append(itemB)
        let doomed = Tag(name: "工作", colorHex: "#4ECDC4")
        let kept = Tag(name: "学习", colorHex: "#FF6B6B")
        store.addTag(doomed)
        store.addTag(kept)
        store.addTag(to: itemA.id, tagId: doomed.id)
        store.addTag(to: itemA.id, tagId: kept.id)
        store.addTag(to: itemB.id, tagId: doomed.id)
        store.deleteTag(id: doomed.id)
        XCTAssertFalse(store.items.first { $0.id == itemA.id }!.tagIds.contains(doomed.id),
                       "Doomed tag should be stripped from itemA")
        XCTAssertTrue(store.items.first { $0.id == itemA.id }!.tagIds.contains(kept.id),
                      "Other tags should be untouched")
        XCTAssertFalse(store.items.first { $0.id == itemB.id }!.tagIds.contains(doomed.id),
                       "Doomed tag should be stripped from itemB")
    }

    /// Deleting a tag that doesn't exist is a no-op (no crash, no spurious changes).
    func testDeleteNonexistentTagIsNoOp() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let item = ClipboardItem(content: "alpha", type: .text)
        store.items.append(item)
        let real = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(real)
        store.addTag(to: item.id, tagId: real.id)
        store.deleteTag(id: UUID())
        XCTAssertEqual(store.tags.count, 1, "Real tag should be untouched")
        XCTAssertTrue(store.items[0].tagIds.contains(real.id), "Item should be untouched")
    }

    // MARK: - Persistence (loadTags / saveTags via UserDefaults key "ClipMemoryTags")

    /// Save tags via the store, then read the raw UserDefaults blob and verify
    /// it's a valid JSON array of Tags. We don't yet round-trip through a fresh
    /// store (which would require injecting a UserDefaults suite); we verify the
    /// write half, which is the side that can lose data if broken.
    func testSaveTagsPersistsJSONToUserDefaults() throws {
        // Use a real FileStorageBackend but isolate tag storage to a dedicated key
        // via a fresh FileStorageBackend(storageKey:) — proves the key parameter works.
        let tagBackend = FileStorageBackend(storageKey: "ClipMemoryTagsTest_SaveTags")
        let store = ClipboardStore(backend: MemoryStorageBackend(),
                                   tagBackend: tagBackend)
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.saveTags()

        // The FileStorageBackend dispatches to main async; spin runloop once.
        let exp = expectation(description: "wait for main queue")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let raw = UserDefaults.standard.data(forKey: "ClipMemoryTagsTest_SaveTags")
        XCTAssertNotNil(raw, "saveTags should write to UserDefaults")
        let decoded = try JSONDecoder().decode([Tag].self, from: raw!)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, tag.id)
        XCTAssertEqual(decoded[0].name, "工作")
        XCTAssertEqual(decoded[0].colorHex, "#4ECDC4")

        // Cleanup so we don't pollute real UserDefaults.
        UserDefaults.standard.removeObject(forKey: "ClipMemoryTagsTest_SaveTags")
    }

    /// loadTags reads from UserDefaults on init and populates `tags` dictionary.
    /// Pre-populate the key, then construct a fresh store and verify it sees the tags.
    func testLoadTagsReadsFromUserDefaultsOnInit() throws {
        let key = "ClipMemoryTagsTest_LoadTags"
        let tag = Tag(name: "学习", colorHex: "#FF6B6B")
        let data = try JSONEncoder().encode([tag])
        UserDefaults.standard.set(data, forKey: key)

        let store = ClipboardStore(backend: MemoryStorageBackend(),
                                   tagBackend: FileStorageBackend(storageKey: key))
        XCTAssertEqual(store.tags.count, 1)
        XCTAssertEqual(store.tags[tag.id]?.name, "学习")
        XCTAssertEqual(store.tags[tag.id]?.colorHex, "#FF6B6B")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: key)
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
