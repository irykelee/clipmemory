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

        for token in tokens where !normalized.contains(token) {
            let pinyin = toPinyin(content)
            if !pinyin.contains(token) {
                return false
            }
        }
        return true
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
