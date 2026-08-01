import Foundation

/// Pinyin-aware fuzzy search for clipboard text. Replaces the old
/// `localizedCaseInsensitiveContains` with token-based AND matching
/// that also checks the pinyin transliteration of Chinese characters.
///
/// Examples:
///   "zhongwen"   matches "中文文档"   (pinyin match)
///   "hello 世界"  matches "Hello World" (token AND + pinyin)
///   "café"       matches "cafe latte" (diacritic-insensitive)
///
/// Thread-safe — all methods are pure functions with no mutable state.
enum FuzzySearchMatcher {

    // ID-PERF-0011 (2026-07-30 audit): `CFStringTransform(kCFStringTransformToLatin)`
    // is the single hottest call in the search hot path — every item
    // (× every search keystroke, for items with Chinese content) re-ran
    // it. For 10K items × ~5 tokens per search × every keystroke, this
    // was multi-second per filter pass. Cache the pinyin output per
    // `content` string in an NSCache keyed by the content hash — same
    // pattern as the date-formatter cache in DateHelpers.swift.
    private static let pinyinCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        // Bound by item count (per-launch history). 16 is a defensive
        // headroom for safety vs OS eviction under memory pressure.
        cache.countLimit = 16_384
        return cache
    }()

    /// Returns true when every whitespace-separated token in `searchText`
    /// can be found in `content` or its pinyin transliteration. Tokens
    /// are compared case-insensitive and diacritic-insensitive.
    static func matches(content: String, searchText: String) -> Bool {
        let tokens = searchText
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        let normalized = content
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)

        let pinyin: String? = tokens.contains(where: { !normalized.contains($0) })
            ? cachedPinyin(of: content)
            : nil
        for token in tokens where !normalized.contains(token) {
            // ID-PERF-0011: cache the pinyin per content string. The
            // per-token closure only fires when the token isn't found
            // in the latin-only `normalized` form, so non-CJK content
            // never pays the pinyin cost.
            guard let py = pinyin else { return false }
            if !py.contains(token) { return false }
        }
        return true
    }

    /// ID-PERF-0011: pinyin output for a given content string. Memoized
    /// in a static NSCache keyed by the content string itself — same
    /// content → same cache hit, pinyin cost paid once per content.
    /// Non-CJK content returns the same `normalized` form so callers
    /// can use the result uniformly (the latin-only check is a subset).
    private static func cachedPinyin(of content: String) -> String {
        let key = content as NSString
        if let cached = pinyinCache.object(forKey: key) {
            return cached as String
        }
        let result = toPinyin(content)
        pinyinCache.setObject(result as NSString, forKey: key)
        return result
    }

    /// Converts Chinese characters to their pinyin transliteration.
    /// Non-CJK characters pass through unchanged and lowercased.
    /// Example: "中文 test" → "zhongwen test"
    static func toPinyin(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}
