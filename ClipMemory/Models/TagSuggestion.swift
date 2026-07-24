import Foundation
import NaturalLanguage

// MARK: - Facet types

/// Dominant language of the snippet. Detected via NLTagger; never surfaced
/// as a user-visible tag (language ≠ topical meaning). Drivers of the
/// previously-shown "中文" / "English" chips have been removed.
enum LanguageFacet: String, Equatable, CaseIterable {
    case simplifiedChinese
    case traditionalChinese
    case english
    case japanese
    case korean
    case other

    /// Map from NLTagger's `NLLanguage.rawValue` (ISO 639-1 with optional
    /// script suffix). See https://developer.apple.com/documentation/naturallanguage/nllanguage
    static func from(rawCode: String) -> LanguageFacet {
        switch rawCode {
        case "zh-Hans", "zh-CN", "zh": return .simplifiedChinese
        case "zh-Hant", "zh-TW", "zh-HK": return .traditionalChinese
        case "en": return .english
        case "ja": return .japanese
        case "ko": return .korean
        default: return .other
        }
    }
}

/// Content shape detected from the snippet. Priority order in `detectKind`:
/// sensitive > credential > email > code > plain. Each non-plain value maps
/// to a single tag-name via the `suggest(_:content:)` shim.
enum KindFacet: String, Equatable, CaseIterable {
    case code         // 代码
    case email        // 邮箱
    case credential   // 账号
    case sensitive    // 敏感
    case plain        // nothing suggested
}

/// Explainable detection result. Replaces the previous opaque `Set<String>`
/// of hardcoded Chinese tag names. Callers can render the parts they care
/// about (kind → suggestion chip; language → debug; names → optional section).
struct DetectedFacets: Equatable {
    let language: LanguageFacet
    let kind: KindFacet
    let names: [String]   // person/org/place tokens; empty when name detection is disabled or NLTagger found nothing
    let rawText: String   // original content, kept for debugging
}

// MARK: - Public API

/// Heuristic facet detection based on content shape + NLTagger.
///
/// `detect(for:content:)` is the canonical entry point and returns explainable
/// facets. `suggest(for:content:)` is kept as a thin shim for backwards
/// compatibility with existing call-sites that want a `Set<String>` of tag
/// names to create / attach.
enum TagSuggestion {

    /// Maximum number of name tokens returned from NLTagger. Caps noise on
    /// long mixed-script snippets (e.g. long emails or reports).
    static let maxNames = 5

    /// Primary entry point. Returns a `DetectedFacets` describing the snippet.
    /// `type:` is accepted but currently unused — type-based filtering at
    /// acceptance is moot (we never suggest type-equivalent names).
    static func detect(for type: ClipboardItemType, content: String) -> DetectedFacets {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return DetectedFacets(
            language: detectLanguage(trimmed),
            kind: detectKind(trimmed),
            names: detectNames(trimmed),
            rawText: trimmed
        )
    }

    /// Backwards-compatible shim. Maps `DetectedFacets` to user-visible tag
    /// names. Drops the legacy "中文" / "English" / "人名" suggestions — those
    /// were language labels miscast as topical tags.
    /// - Returns: a `Set<String>` of tag names derived from `kind`. Empty when
    ///   `kind == .plain`.
    static func suggest(for type: ClipboardItemType, content: String) -> Set<String> {
        let f = detect(for: type, content: content)
        var out = Set<String>()
        switch f.kind {
        case .code:        out.insert(L10n.tagSuggestionKindCode)
        case .email:       out.insert(L10n.tagSuggestionKindEmail)
        case .credential:  out.insert(L10n.tagSuggestionKindCredential)
        case .sensitive:   out.insert(L10n.tagSuggestionKindSensitive)
        case .plain:       break
        }
        return out
    }

    // MARK: - Language detection

    /// M-19 (2026-07-24 audit): NLTagger loads the language model on first
    /// construction (~10–30 ms). Reuse a static instance per scheme instead
    /// of rebuilding on every detect. The `string` property is `var`; we
    /// rely on callers (TagPickerSheet.loadSuggestions, called on the
    /// SwiftUI main thread) running serially to avoid a data race on the
    /// assignment. If a future caller crosses threads, switch to a pool
    /// or a synchronized wrapper.
    private static let languageTagger: NLTagger = {
        NLTagger(tagSchemes: [.language])
    }()
    private static let namesTagger: NLTagger = {
        NLTagger(tagSchemes: [.nameType])
    }()

    /// Detect the dominant language of `s`. Uses NLTagger when it returns a
    /// usable language code; falls back to the legacy `containsCJK` /
    /// `containsLatinWord` heuristics when NLTagger returns nil (which has
    /// historically been observed for short CJK snippets on macOS 13).
    private static func detectLanguage(_ s: String) -> LanguageFacet {
        guard !s.isEmpty else { return .other }
        languageTagger.string = s
        if let lang = languageTagger.dominantLanguage {
            return LanguageFacet.from(rawCode: lang.rawValue)
        }
        // Fallback: detect any CJK ideograph (covers simplified + traditional
        // when NLTagger declines to label). Default to .other for English-only
        // or mixed-script content where NLTagger itself couldn't decide.
        if containsCJK(s) { return .simplifiedChinese }
        return .other
    }

    // MARK: - Kind detection

    /// Detect the content shape. Priority: sensitive > credential > email >
    /// code > plain. The first match wins — a snippet like `passphrase=abc...`
    /// is .sensitive (not .credential), matching the legacy behavior.
    private static func detectKind(_ s: String) -> KindFacet {
        guard !s.isEmpty else { return .plain }
        if containsSensitiveKeyword(s) { return .sensitive }
        if containsAccountLikeToken(s) { return .credential }
        if containsEmail(s) { return .email }
        if containsCodeMarker(s) { return .code }
        return .plain
    }

    // MARK: - Name detection

    /// Extract person/org/place name tokens via NLTagger. Returns up to
    /// `maxNames` unique tokens, in document order. Names are not surfaced
    /// as auto-tags — the caller (e.g. `TagPickerSheet`) decides whether to
    /// present them as a "Suggested names" section behind an opt-in toggle.
    private static func detectNames(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        namesTagger.string = s
        var seen = Set<String>()
        var ordered: [String] = []
        let range = s.startIndex..<s.endIndex
        namesTagger.enumerateTags(in: range, unit: .word, scheme: .nameType) { tag, tokenRange in
            guard tag != nil, !tokenRange.isEmpty else { return true }
            // Skip single-character "names" — they're usually false positives
            // (initials, lone Latin letters) from the NER model on short snippets.
            let length = s.distance(from: tokenRange.lowerBound, to: tokenRange.upperBound)
            guard length >= 2 else { return true }
            let token = String(s[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return true }
            if seen.insert(token).inserted {
                ordered.append(token)
            }
            return ordered.count < maxNames
        }
        return ordered
    }

    // MARK: - Heuristic rules (reused by detectKind; preserved verbatim)

    /// Code signals: balanced braces or common keywords.
    private static func containsCodeMarker(_ s: String) -> Bool {
        // BUG-047 (2026-07-21): the prior marker set included ";" — every
        // natural-language sentence with a semicolon ("note: important;
        // please read") was misclassified as code. Drop the semicolon.
        // Remaining markers (func / def / class / import / => / { / })
        // all imply an actual code construct; lone ";" does not.
        let markers = ["func ", "def ", "class ", "import ", "=>", "{", "}"]
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
        // BUG-046 (2026-07-21): ICU regex treats CJK characters as \w,
        // so \b doesn't fire at the CJK/Latin boundary. A 16+ char
        // token embedded in Chinese text (e.g. 密钥abc123def456ghi789)
        // goes undetected. Use lookarounds instead of \b — match a run
        // of [A-Za-z0-9] not preceded or followed by another alnum.
        s.range(of: #"(?<![A-Za-z0-9])[A-Za-z0-9]{16,}(?![A-Za-z0-9])"#,
                options: .regularExpression) != nil
    }

    /// Lightweight keyword check. False positives accepted — user filters at acceptance.
    private static func containsSensitiveKeyword(_ s: String) -> Bool {
        let keywords = ["密码", "密钥", "口令", "private key", "secret", "password", "token"]
        let lower = s.lowercased()
        return keywords.contains { lower.contains($0.lowercased()) }
    }

    /// CJK Unified Ideographs U+4E00..U+9FFF + Extension A U+3400..U+4DBF.
    /// Used as fallback for language detection when NLTagger declines to label.
    private static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }
}
