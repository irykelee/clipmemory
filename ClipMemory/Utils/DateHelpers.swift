import Foundation

/// Shared date formatter cache for performance optimization.
/// Creating DateFormatter is expensive; this cache avoids repeated instantiation.
private let absoluteDateFormatterCache = NSCache<NSString, DateFormatter>()

/// Returns a cached DateFormatter for the given language code.
func cachedAbsoluteDateFormatter(for languageCode: String) -> DateFormatter {
    let key = languageCode as NSString
    if let cached = absoluteDateFormatterCache.object(forKey: key) { return cached }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.locale = Locale(identifier: languageCode)
    absoluteDateFormatterCache.setObject(formatter, forKey: key)
    return formatter
}

/// Shared relative date formatter cache.
private let relativeDateFormatterCache = NSCache<NSString, RelativeDateTimeFormatter>()

/// Returns a cached RelativeDateTimeFormatter for the given language code.
func cachedRelativeDateFormatter(for languageCode: String) -> RelativeDateTimeFormatter {
    let key = languageCode as NSString
    if let cached = relativeDateFormatterCache.object(forKey: key) { return cached }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.locale = Locale(identifier: languageCode)
    relativeDateFormatterCache.setObject(formatter, forKey: key)
    return formatter
}
