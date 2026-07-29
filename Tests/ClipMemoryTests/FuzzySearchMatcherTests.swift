import XCTest
@testable import ClipMemory

final class FuzzySearchMatcherTests: XCTestCase {

    // MARK: - Token matching

    func testSingleTokenSubstringMatch() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "hello world", searchText: "hello"))
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "hello world", searchText: "world"))
        XCTAssertFalse(FuzzySearchMatcher.matches(content: "hello world", searchText: "xyz"))
    }

    func testMultiTokenAndMatch() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "hello beautiful world", searchText: "hello world"))
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "hello world", searchText: "hello world"))
        XCTAssertFalse(FuzzySearchMatcher.matches(content: "hello world", searchText: "hello xyz"))
    }

    func testTokenOrderIndependent() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "hello world", searchText: "world hello"))
    }

    // MARK: - Pinyin

    func testPinyinMatchesChinese() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "你好世界", searchText: "nihao"))
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "你好世界", searchText: "shijie"))
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "你好世界", searchText: "nihaoshijie"))
    }

    func testPinyinMultiTokenChinese() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "你好世界", searchText: "ni hao"))
    }

    func testPinyinDoesNotMatchEnglish() {
        XCTAssertFalse(FuzzySearchMatcher.matches(content: "hello", searchText: "nihao"))
    }

    func testChineseDirectMatch() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "你好世界", searchText: "你好"))
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "你好世界", searchText: "世界"))
    }

    // MARK: - Mixed content

    func testEnglishAndChinesePinyin() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "hello 世界", searchText: "hello shijie"))
    }

    func testPinyinSearchTermMatchesChineseContent() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "中文文档.txt", searchText: "zhongwen"))
    }

    // MARK: - Diacritic insensitive

    func testDiacriticInsensitive() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "café résumé", searchText: "cafe"))
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "café résumé", searchText: "resume"))
    }

    // MARK: - Case insensitive

    func testCaseInsensitive() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "Hello World", searchText: "hello"))
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "hello world", searchText: "HELLO"))
    }

    // MARK: - Edge cases

    func testEmptySearchTextReturnsTrue() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "anything", searchText: ""))
    }

    func testEmptyContentReturnsFalse() {
        XCTAssertFalse(FuzzySearchMatcher.matches(content: "", searchText: "hello"))
    }

    func testExactMatch() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "exact", searchText: "exact"))
    }

    // MARK: - toPinyin

    func testToPinyinChinese() {
        let pinyin = FuzzySearchMatcher.toPinyin("你好")
        XCTAssertTrue(pinyin.contains("ni"), "pinyin of 你 should contain 'ni'")
        XCTAssertTrue(pinyin.contains("hao"), "pinyin of 好 should contain 'hao'")
    }

    func testToPinyinEnglishPassesThrough() {
        let result = FuzzySearchMatcher.toPinyin("hello")
        XCTAssertEqual(result, "hello")
    }
}
