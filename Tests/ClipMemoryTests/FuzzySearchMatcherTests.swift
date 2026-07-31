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

    // MARK: - ID-PERF-0011 (2026-07-30 audit): pinyin cache behavior

    /// Cache hit: same `content` returns the same pinyin string on
    /// repeated calls without re-running CFStringTransform. The
    /// (pinyin result equality) is the externally observable signal —
    /// if caching is broken, the first vs second call could differ if
    /// the underlying transform is non-deterministic (it isn't, but the
    /// contract is "same key → same value").
    func testCachedPinyinReturnsSameResultForSameContent() {
        let first = FuzzySearchMatcher.toPinyin("你好世界测试")
        let second = FuzzySearchMatcher.toPinyin("你好世界测试")
        XCTAssertEqual(first, second, "toPinyin must be deterministic for same input")
    }

    /// Performance regression test: 1000 `matches` calls on the same
    /// Chinese content should not be 1000× slower than a single call.
    /// With ID-PERF-0011 cache in place, the first call computes pinyin
    /// and subsequent calls are O(1) NSCache hits. Without the cache,
    /// 1000 calls × ~1 ms each = 1 s budget breach.
    /// Threshold: <200 ms for 1000 calls (loose, to avoid CI flakiness
    /// while still catching "cache broken" regressions).
    func testCachedPinyinPerformance() {
        let content = "你好世界" + String(repeating: "中文测试 ", count: 50)
        let search = "nihao shijie zhongwen"  // all non-Chinese tokens that require pinyin
        // Warm cache
        XCTAssertTrue(FuzzySearchMatcher.matches(content: content, searchText: search))
        // Measure
        let start = Date()
        for _ in 0..<1000 {
            _ = FuzzySearchMatcher.matches(content: content, searchText: search)
        }
        let elapsed = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsed, 200, "1000 cached pinyin matches should take <200 ms, took \(elapsed) ms")
    }
}
