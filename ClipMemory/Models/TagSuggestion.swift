import Foundation

/// Heuristic tag-name suggestions based on content shape.
///
/// Returns tag **names** (not IDs) — actual Tag IDs are created at acceptance
/// time via `ClipboardStore.addTag(_:)`. The user picks which suggestions to
/// keep; unaccepted suggestions incur no cost.
///
/// `for type:` is accepted but currently unused: we never suggest
/// type-equivalent names ("链接"/"文本"/etc.), so type-based filtering at
/// acceptance is moot. Reserved for future type-aware refinements.
enum TagSuggestion {

    static func suggest(for type: ClipboardItemType, content: String) -> Set<String> {
        var out = Set<String>()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return out }

        if containsCodeMarker(trimmed) { out.insert("代码") }
        if containsEmail(trimmed) { out.insert("邮箱") }
        if containsAccountLikeToken(trimmed) { out.insert("账号") }
        if containsSensitiveKeyword(trimmed) { out.insert("敏感") }
        if containsCJK(trimmed) { out.insert("中文") }
        if containsLatinWord(trimmed) { out.insert("English") }

        return out
    }

    // MARK: - Heuristic rules

    /// Code signals: balanced braces or common keywords.
    private static func containsCodeMarker(_ s: String) -> Bool {
        let markers = ["func ", "def ", "class ", "import ", "=>", "{", "}", ";"]
        return markers.contains { s.contains($0) }
    }

    /// RFC-5322 lite: any `[A-Za-z0-9._%+-]+@[domain with .tld>=2letters]` token.
    /// Implemented split-based to dodge NSRegularExpression char-class `-` quirks.
    private static func containsEmail(_ s: String) -> Bool {
        let parts = s.components(separatedBy: "@")
        guard parts.count >= 2 else { return false }
        for i in 0..<(parts.count - 1) {
            let local = parts[i]
            let rest = parts[i+1]
            guard let lastLocal = local.last,
                  localLastCharValid(lastLocal),
                  let dot = rest.firstIndex(of: "."),
                  rest.distance(from: rest.startIndex, to: dot) > 0
            else { continue }
            let tld = rest[rest.index(after: dot)...]
            guard tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { continue }
            return true
        }
        return false
    }

    private static func localLastCharValid(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "." || c == "_" ||
        c == "%" || c == "+" || c == "-"
    }

    /// 16+ char alphanumeric run (API-key / account-token shape).
    private static func containsAccountLikeToken(_ s: String) -> Bool {
        s.range(of: #"\b[A-Za-z0-9]{16,}\b"#,
                options: .regularExpression) != nil
    }

    /// Lightweight keyword check. False positives accepted — user filters at acceptance.
    private static func containsSensitiveKeyword(_ s: String) -> Bool {
        let keywords = ["密码", "密钥", "口令", "private key", "secret", "password", "token"]
        let lower = s.lowercased()
        return keywords.contains { lower.contains($0.lowercased()) }
    }

    /// CJK Unified Ideographs U+4E00..U+9FFF + Extension A U+3400..U+4DBF.
    private static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    /// 3+ consecutive Latin letters (avoids single chars and pure-digit runs).
    private static func containsLatinWord(_ s: String) -> Bool {
        s.range(of: #"[A-Za-z]{3,}"#,
                options: .regularExpression) != nil
    }
}
