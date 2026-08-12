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

    // MARK: - PR54-M1 (v2.8.4 latent bug batch): locale-independent case folding

    /// Turkish `"I"` (dotted) / `"İ"` (capital dotted) / `"i"` (dotted)
    /// / `"ı"` (dotless) is the canonical example where `.lowercased()`
    /// is locale-dependent. Under `tr_TR` locale, `"I".lowercased() == "ı"`
    /// (dotless), but `"I".lowercased(with: en_US_POSIX) == "i"`.
    /// Pinning both sides to POSIX guarantees search and content agree
    /// regardless of host locale. The Turkish word `"Istanbul"` (capital I,
    /// rest lowercase) lowers to ASCII `"istanbul"` via POSIX — exactly the
    /// form a user in any locale would expect to see and search.
    func testLocaleIndependentTurkishCapitalI() {
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "Istanbul", searchText: "istanbul"),
                      "uppercase I in 'Istanbul' should lowercase to ASCII 'i' via POSIX and match 'istanbul'")
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "istanbul", searchText: "Istanbul"),
                      "POSIX-folded content 'istanbul' must match mixed-case search 'Istanbul'")
    }

    /// German `"ß"` (sharp s) has no ASCII lowercase equivalent in
    /// Latin-1; under `de_DE` locale, `"ß".lowercased()` is still `"ß"`,
    /// while `"SS".lowercased()` is `"ss"`. POSIX folds both byte-
    /// deterministically so neither produces surprising matches.
    /// The matcher's contract is ASCII-case-fold only — the user-facing
    /// expectation is that uppercase SS does NOT match lowercase ß
    /// (and vice versa), which POSIX preserves.
    func testLocaleIndependentGermanEszett() {
        XCTAssertFalse(FuzzySearchMatcher.matches(content: "straße", searchText: "STRASSE"),
                       "ASCII SS search must NOT match ß content under POSIX")
        XCTAssertFalse(FuzzySearchMatcher.matches(content: "STRASSE", searchText: "straße"),
                       "ß search must NOT match ASCII SS content under POSIX")
    }

    /// PR54-M1 cache regression guard: warm the normalized cache with one
    /// call, then issue a second call with a different `searchText` shape.
    /// Both must succeed — the cache key is `content` only, and the cached
    /// value must be the POSIX-folded form (not the host-locale-folded
    /// form that would diverge between two test runs on different CI hosts).
    func testNormalizedCacheHoldsPosixFoldNotHostLocale() {
        // Warm cache with one search shape.
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "Istanbul", searchText: "istanbul"))
        // Hit cache, different search shape — relies on cached normalized
        // form ("istanbul") matching both searchText variants.
        XCTAssertTrue(FuzzySearchMatcher.matches(content: "Istanbul", searchText: "ISTANBUL"),
                      "cached normalized form must be POSIX-folded; if it were host-locale-folded it would diverge")
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

    // MARK: - ID-PERF-0025 (2026-08-11 audit): normalized cache

    /// Determinism: same `content` must yield the same normalized form
    /// on repeated calls. The cache is keyed by content; the
    /// lowercased()+folding() pipeline is deterministic so this is
    /// also the regression guard for "cache stores something other
    /// than the computed value".
    func testCachedNormalizedReturnsSameResultForSameContent() {
        let first = FuzzySearchMatcher.matches(content: "Café Résumé", searchText: "CAFE")
        let second = FuzzySearchMatcher.matches(content: "Café Résumé", searchText: "RESUME")
        XCTAssertTrue(first, "case-insensitive + diacritic-insensitive must work on first call")
        XCTAssertTrue(second, "case-insensitive + diacritic-insensitive must work after first call warmed the cache")
    }

    /// Performance regression: with ID-PERF-0025 cache, 1000 `matches`
    /// calls on the same ~2KB content should complete in single-digit ms.
    /// Without the cache, each call re-runs lowercased()+folding() on
    /// the full content (audit measured 250ms/keystroke for 5000 items;
    /// the per-call cost for a single ~2KB content is ~50µs, so 1000
    /// calls ≈ 50ms without cache). Threshold of 30ms is generous enough
    /// for CI noise while still catching "cache broken" regressions.
    /// This test is the post-landing validation of the 251ms → ~5ms
    /// improvement the user reported pre-audit; if the cache regresses
    /// (e.g. someone removes the cache and inlines the lowercased
    /// again), this test should fail.
    func testCachedNormalizedPerformance() {
        // ~2KB content: mirrors the audit's 5000×2KB measurement shape
        let content = "Hello World " + String(repeating: "the quick brown fox jumps over the lazy dog ", count: 50)
        let search = "hello world quick"
        // Warm both normalized and pinyin caches
        XCTAssertTrue(FuzzySearchMatcher.matches(content: content, searchText: search))
        // Measure cached path
        let start = Date()
        for _ in 0..<1000 {
            _ = FuzzySearchMatcher.matches(content: content, searchText: search)
        }
        let elapsed = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsed, 30,
                          "1000 cached-normalized matches should take <30 ms, took \(elapsed) ms — cache regression?")
    }
}
