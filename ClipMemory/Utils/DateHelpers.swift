import Foundation

/// Shared date formatter cache for performance optimization.
/// Creating DateFormatter is expensive; this cache avoids repeated instantiation.
/// ID-PERF-0006 (2026-07-30 audit): defensive countLimit in case a future
/// caller passes high-cardinality keys (currently bounded by 7 languages).
private let absoluteDateFormatterCache: NSCache<NSString, DateFormatter> = {
    let cache = NSCache<NSString, DateFormatter>()
    cache.countLimit = 16
    return cache
}()

/// ID-SYNC-0005 (2026-08-01 audit): the cache hands out SHARED formatter
/// instances, and concurrent `string(from:)` on the same DateFormatter is a
/// data race (current callers are main-thread-only, but nothing enforced
/// that). Serialize cache access AND formatting under one NSLock; the public
/// surface below only exposes locked formatting, never a bare formatter.
/// NSLock (not OSAllocatedUnfairLock) keeps the macOS 13 deployment target
/// simple — the critical section is microseconds.
private let dateFormatterLock = NSLock()

/// Returns a cached DateFormatter for the given language code.
/// Must be called with `dateFormatterLock` held.
private func cachedAbsoluteDateFormatter(for languageCode: String) -> DateFormatter {
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
/// ID-PERF-0006: see absoluteDateFormatterCache above.
private let relativeDateFormatterCache: NSCache<NSString, RelativeDateTimeFormatter> = {
    let cache = NSCache<NSString, RelativeDateTimeFormatter>()
    cache.countLimit = 16
    return cache
}()

/// Returns a cached RelativeDateTimeFormatter for the given language code.
/// Must be called with `dateFormatterLock` held.
private func cachedRelativeDateFormatter(for languageCode: String) -> RelativeDateTimeFormatter {
    let key = languageCode as NSString
    if let cached = relativeDateFormatterCache.object(forKey: key) { return cached }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.locale = Locale(identifier: languageCode)
    relativeDateFormatterCache.setObject(formatter, forKey: key)
    return formatter
}

/// ID-SYNC-0005: locked absolute-date formatting (`dateStyle .medium`,
/// `timeStyle .short`). Thread-safe replacement for the former bare
/// `cachedAbsoluteDateFormatter(for:).string(from:)` pattern.
func cachedAbsoluteDateString(from date: Date, languageCode: String) -> String {
    dateFormatterLock.lock()
    defer { dateFormatterLock.unlock() }
    return cachedAbsoluteDateFormatter(for: languageCode).string(from: date)
}

/// ID-SYNC-0005: locked relative-date formatting (`unitsStyle .abbreviated`).
/// Thread-safe replacement for the former bare
/// `cachedRelativeDateFormatter(for:).localizedString(for:relativeTo:)` pattern.
func cachedRelativeDateString(from date: Date, relativeTo now: Date, languageCode: String) -> String {
    dateFormatterLock.lock()
    defer { dateFormatterLock.unlock() }
    return cachedRelativeDateFormatter(for: languageCode).localizedString(for: date, relativeTo: now)
}
