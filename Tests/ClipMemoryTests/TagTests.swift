import XCTest
import SwiftUI
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

    func testColorHexRejectsInvalidLengths() {
        // 2026-07-20 audit LOW: fallback is `.accentColor` (keeps chips
        // visible in both light/dark) instead of `.black` (invisible on
        // dark Material). Equality with `.accentColor` is fine because
        // SwiftUI resolves it to the same dynamic system color in a given
        // run — XCAssertEqual compares the resolved values.
        XCTAssertEqual(Color(hex: "#FFF"), Color.accentColor, "3-digit hex should fall back to accentColor")
        XCTAssertEqual(Color(hex: "#FF00FF00"), Color.accentColor, "8-digit hex should fall back to accentColor")
        XCTAssertEqual(Color(hex: "not-a-color"), Color.accentColor, "Non-hex string should fall back to accentColor")
        XCTAssertEqual(Color(hex: "#GGG"), Color.accentColor, "Invalid characters should fall back to accentColor")
    }

    // MARK: - Color.toHex()

    func testColorToHexRoundTripPreservesRGB() {
        let cases = ["#FF6B6B", "#4ECDC4", "#000000", "#FFFFFF", "#123456"]
        for hex in cases {
            XCTAssertEqual(Color(hex: hex).toHex(), hex, "Round-trip failed for \(hex)")
        }
    }

    func testColorToHexIgnoresAlpha() {
        let c = Color(red: 1.0, green: 0.5, blue: 0.0, opacity: 0.3)
        XCTAssertEqual(c.toHex(), "#FF8000")
    }

    func testColorToHexClampsToDeviceRGB() {
        // A color that NSColor can't represent in deviceRGB should fall back to black.
        // We can't easily construct one in SwiftUI, but the method should never crash.
        let c = Color(hex: "#4ECDC4")
        XCTAssertFalse(c.toHex().isEmpty)
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
    /// tag names are encrypted at rest (v2 prefix) while a fresh store load
    /// decrypts them back to plaintext.
    func testSaveTagsPersistsEncryptedNamesToUserDefaults() throws {
        // Use a real FileStorageBackend but isolate tag storage to a dedicated key
        // via a fresh FileStorageBackend(storageKey:) — proves the key parameter works.
        // UUID-suffix the key so re-runs (or parallel runs against the same
        // UserDefaults) can't accumulate data; cleanup happens unconditionally.
        let key = "ClipMemoryTagsTest_SaveTags-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let tagBackend = FileStorageBackend(storageKey: key)
        let store = ClipboardStore(backend: MemoryStorageBackend(),
                                   tagBackend: tagBackend)
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.saveTags()

        // The FileStorageBackend dispatches to main async; spin runloop once.
        let exp = expectation(description: "wait for main queue")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let raw = UserDefaults.standard.data(forKey: key)
        XCTAssertNotNil(raw, "saveTags should write to UserDefaults")
        let decoded = try JSONDecoder().decode([Tag].self, from: raw!)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, tag.id)
        XCTAssertTrue(decoded[0].name.hasPrefix("v2:"), "Tag name should be encrypted on disk")
        XCTAssertNotEqual(decoded[0].name, "工作", "Tag name should not be plaintext")
        XCTAssertEqual(decoded[0].colorHex, "#4ECDC4")

        // Fresh store with the same backend decrypts the name back to plaintext.
        let freshStore = ClipboardStore(backend: MemoryStorageBackend(),
                                        tagBackend: FileStorageBackend(storageKey: key))
        XCTAssertEqual(freshStore.tags[tag.id]?.name, "工作")
        // Cleanup runs via `defer` at the top of the test to handle the
        // failed-assertion path (XCTAssertEqual bails out before reaching
        // an explicit cleanup line, so leftover data used to accumulate
        // across runs and break unrelated later tests).
    }

    /// A tag whose name coincidentally starts with the encrypted marker prefix
    /// must survive a save/load round-trip instead of being mistaken for
    /// ciphertext and replaced with the [locked] placeholder.
    func testTagNameStartingWithEncryptionPrefixSurvivesRoundTrip() throws {
        let key = "ClipMemoryTagsTest_V2PrefixRoundTrip"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let tagBackend = FileStorageBackend(storageKey: key)
        let store = ClipboardStore(backend: MemoryStorageBackend(),
                                   tagBackend: tagBackend)
        let tag = Tag(name: "v2:work", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.saveTags()

        let exp = expectation(description: "wait for main queue")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let freshStore = ClipboardStore(backend: MemoryStorageBackend(),
                                        tagBackend: FileStorageBackend(storageKey: key))
        XCTAssertEqual(freshStore.tags[tag.id]?.name, "v2:work",
                       "Names that look encrypted but are plaintext must not become locked")
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

    // MARK: - Item tag attachment persistence

    /// Attaching a tag must schedule an item save so the attachment survives
    /// a simulated restart (new store instance over the same backend).
    func testAddTagToItemPersistsAcrossRestart() {
        let backend = MemoryStorageBackend()
        let store = ClipboardStore(backend: backend)
        let item = ClipboardItem(content: "hello", type: .text)
        store.items.append(item)
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.addTag(to: item.id, tagId: tag.id)
        store.flushPendingSaves()

        let restarted = ClipboardStore(backend: backend)
        XCTAssertTrue(restarted.items.first?.tagIds.contains(tag.id) == true,
                      "Tag attachment must survive restart")
    }

    /// Detaching a tag must also persist item state across restart.
    func testRemoveTagFromItemPersistsAcrossRestart() {
        let backend = MemoryStorageBackend()
        let store = ClipboardStore(backend: backend)
        let item = ClipboardItem(content: "hello", type: .text)
        store.items.append(item)
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.addTag(to: item.id, tagId: tag.id)
        store.flushPendingSaves()

        store.removeTag(from: item.id, tagId: tag.id)
        store.flushPendingSaves()

        let restarted = ClipboardStore(backend: backend)
        XCTAssertFalse(restarted.items.first?.tagIds.contains(tag.id) == true,
                       "Tag detachment must survive restart")
    }

    /// Deleting a tag strips it from items and persists both tag and item state.
    func testDeleteTagPersistsAcrossRestart() {
        let backend = MemoryStorageBackend()
        let store = ClipboardStore(backend: backend)
        let item = ClipboardItem(content: "hello", type: .text)
        store.items.append(item)
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.addTag(to: item.id, tagId: tag.id)
        store.flushPendingSaves()

        store.deleteTag(id: tag.id)
        store.flushPendingSaves()

        let restarted = ClipboardStore(backend: backend)
        XCTAssertNil(restarted.tags[tag.id], "Tag definition should be gone")
        XCTAssertTrue(restarted.items.first?.tagIds.isEmpty == true,
                      "Dangling tag id should be removed from item")
    }

    // MARK: - Dedup preserves tagIds

    /// When addItem hits the dedup path, the existing item's tagIds must be
    /// preserved rather than reset to empty.
    func testDedupPreservesTagIds() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let tag = Tag(name: "工作", colorHex: "#4ECDC4")
        store.addTag(tag)
        store.addItem(ClipboardItem(content: "hello", type: .text))
        let firstItem = store.items[0]
        store.addTag(to: firstItem.id, tagId: tag.id)
        store.flushPendingSaves()

        store.addItem(ClipboardItem(content: "hello", type: .text))
        store.flushPendingSaves()

        XCTAssertEqual(store.items[0].tagIds, [tag.id],
                       "Dedup rebuild must preserve tagIds")
    }
}

// MARK: - TagSuggestion heuristic engine

final class TagSuggestionTests: XCTestCase {

    // MARK: - detect(...) — new facet-based API

    /// Empty content: kind == .plain, language == .other, no names.
    func testDetectEmptyContentReturnsPlainOtherAndNoNames() {
        let f = TagSuggestion.detect(for: .text, content: "")
        XCTAssertEqual(f.kind, .plain)
        XCTAssertEqual(f.language, .other)
        XCTAssertTrue(f.names.isEmpty)
        XCTAssertEqual(f.rawText, "")
    }

    /// Pure whitespace: same — no signals.
    func testDetectWhitespaceOnlyReturnsPlainOther() {
        let f = TagSuggestion.detect(for: .text, content: "   \n\t  ")
        XCTAssertEqual(f.kind, .plain)
        XCTAssertEqual(f.language, .other)
        XCTAssertTrue(f.names.isEmpty)
    }

    /// Code snippet → kind == .code.
    func testDetectCodeSnippetIsKindCode() {
        let f = TagSuggestion.detect(for: .text, content: "func greet() { print(\"hi\") }")
        XCTAssertEqual(f.kind, .code)
    }

    /// Email → kind == .email.
    func testDetectEmailIsKindEmail() {
        let f = TagSuggestion.detect(for: .text, content: "alice@example.com")
        XCTAssertEqual(f.kind, .email)
    }

    /// Email embedded in surrounding text still triggers (priority chain).
    func testDetectEmailWithPrefixIsKindEmail() {
        let f = TagSuggestion.detect(for: .text, content: "at alice@example.com")
        XCTAssertEqual(f.kind, .email)
    }

    /// 16+ char alphanumeric token (API-key shape) without a sensitive keyword
    /// → kind == .credential. The content deliberately omits the word "token"
    /// which would otherwise trigger the sensitive path first.
    func testDetectLongAlphanumericTokenIsKindCredential() {
        let f = TagSuggestion.detect(for: .text, content: "ABCDEFGHIJKLMNOPabcdef1234")
        XCTAssertEqual(f.kind, .credential)
    }

    /// Sensitive keyword wins over credential (priority: sensitive > credential).
    func testDetectSensitiveKeywordWinsOverCredential() {
        let f = TagSuggestion.detect(for: .text, content: "我的密码是 123456")
        XCTAssertEqual(f.kind, .sensitive)
    }

    /// CJK content: language detection via NLTagger or fallback to CJK heuristic.
    /// We don't assert the exact case (NLTagger CJK coverage has historical
    /// gaps on macOS 13) — only that it lands in a CJK-adjacent bucket.
    func testDetectCJKLanguageIsChineseVariant() {
        let f = TagSuggestion.detect(for: .text, content: "你好世界")
        XCTAssertTrue([.simplifiedChinese, .traditionalChinese].contains(f.language),
                      "CJK content should map to a Chinese language facet, got: \(f.language)")
    }

    /// Latin content → language == .english (NLTagger is reliable here).
    func testDetectLatinLanguageIsEnglish() {
        let f = TagSuggestion.detect(for: .text, content: "The quick brown fox")
        XCTAssertEqual(f.language, .english)
    }

    // MARK: - suggest(...) shim — backwards compat + language-tag removal

    /// Shim still maps kind → tag name. Re-verifies the legacy expectations
    /// that *survived* the refactor (kind → tag mappings).
    /// Assertions reference L10n rather than hardcoded zh-Hans strings so the
    /// suite passes regardless of the host's system language (CI runs en-US).
    func testSuggestShimReturnsKindTagForCode() {
        let s = TagSuggestion.suggest(for: .text, content: "func greet() { print(\"hi\") }")
        XCTAssertTrue(s.contains(L10n.tagSuggestionKindCode))
    }

    func testSuggestShimReturnsKindTagForEmail() {
        let s = TagSuggestion.suggest(for: .text, content: "alice@example.com")
        XCTAssertTrue(s.contains(L10n.tagSuggestionKindEmail))
    }

    func testSuggestShimReturnsKindTagForCredential() {
        let s = TagSuggestion.suggest(for: .text, content: "ABCDEFGHIJKLMNOPabcdef1234")
        XCTAssertTrue(s.contains(L10n.tagSuggestionKindCredential))
    }

    func testSuggestShimReturnsKindTagForSensitive() {
        let s = TagSuggestion.suggest(for: .text, content: "我的密码是 123456")
        XCTAssertTrue(s.contains(L10n.tagSuggestionKindSensitive))
    }

    /// Plain content → empty suggestions (no kind-derived tag to attach).
    func testSuggestShimPlainContentReturnsEmpty() {
        let s = TagSuggestion.suggest(for: .text, content: "hello world")
        XCTAssertTrue(s.isEmpty)
    }

    /// Lock the language-tag removal: the shim must NEVER emit "中文" / "English"
    /// / "人名" — those were language labels miscast as topical tags, removed
    /// in the refactor. If any of these reappear, the refactor regressed.
    func testSuggestShimDoesNotEmitLanguageOrPersonTags() {
        let cases = [
            "你好世界",          // CJK
            "The quick brown fox", // Latin
            "明天 3pm 张总",      // mixed + person name
            "func greet() {}",    // code
            "alice@example.com",  // email
            "token=abcdef1234567890ABCDEF", // credential
            "我的密码是 123456"   // sensitive
        ]
        for content in cases {
            let s = TagSuggestion.suggest(for: .text, content: content)
            XCTAssertFalse(s.contains("中文"), "中文 leaked for: \(content) → \(s)")
            XCTAssertFalse(s.contains("English"), "English leaked for: \(content) → \(s)")
            XCTAssertFalse(s.contains("人名"), "人名 leaked for: \(content) → \(s)")
        }
    }
}

// MARK: - ClipboardStore.tags(matchingPrefix:) autocomplete API

final class ClipboardStoreAutocompleteTests: XCTestCase {

    /// Empty prefix → empty result. Autocomplete is opt-in; empty input
    /// shouldn't dump the entire tag dictionary into the UI.
    func testTagsMatchingPrefixEmptyReturnsEmpty() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        store.addTag(Tag(name: "工作", colorHex: "#4ECDC4"))
        XCTAssertTrue(store.tags(matchingPrefix: "").isEmpty)
    }

    /// Case-insensitive: "INS" / "ins" / "Ins" all match "Insurance".
    func testTagsMatchingPrefixIsCaseInsensitive() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        store.addTag(Tag(name: "Insurance", colorHex: "#FF6B6B"))
        XCTAssertEqual(store.tags(matchingPrefix: "INS").count, 1, "uppercase prefix")
        XCTAssertEqual(store.tags(matchingPrefix: "ins").count, 1, "lowercase prefix")
        XCTAssertEqual(store.tags(matchingPrefix: "Ins").count, 1, "mixed-case prefix")
    }

    /// Limit caps result count; ordering is createdAt desc (most recent first).
    func testTagsMatchingPrefixRespectsLimitAndOrder() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let older = Tag(id: UUID(), name: "保险-老", colorHex: "#4ECDC4",
                        createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = Tag(id: UUID(), name: "保险-新", colorHex: "#FF6B6B",
                        createdAt: Date(timeIntervalSince1970: 2_000))
        let other = Tag(id: UUID(), name: "开发", colorHex: "#45B7D1",
                        createdAt: Date(timeIntervalSince1970: 3_000))
        store.addTag(older)
        store.addTag(newer)
        store.addTag(other)
        let hits = store.tags(matchingPrefix: "保险", limit: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.name, "保险-新", "Most recent first")
    }

    /// Non-matching prefix → empty (not nil, not crash).
    func testTagsMatchingPrefixNoMatchReturnsEmpty() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        store.addTag(Tag(name: "工作", colorHex: "#4ECDC4"))
        XCTAssertTrue(store.tags(matchingPrefix: "xyz").isEmpty)
    }

    /// Limit 0 returns empty (defensive — caller might pass 0 by mistake).
    func testTagsMatchingPrefixLimitZeroReturnsEmpty() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        store.addTag(Tag(name: "工作", colorHex: "#4ECDC4"))
        XCTAssertTrue(store.tags(matchingPrefix: "工", limit: 0).isEmpty)
    }
}
