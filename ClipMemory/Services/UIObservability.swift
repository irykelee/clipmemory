import Foundation
import os.log

/// ABC §B observability: targeted instrumentation for ContentView mutation sites.
/// Mirrors StartupHealth's split — pure `formatXxx(...)` helpers (unit-tested) +
/// thin `logXxx(...)` wrappers that feed them into `os.Logger`. The format
/// helpers take primitives only, so tests cannot accidentally touch
/// `ClipboardStore.shared` or the real `UserDefaults`.
///
/// Convention:
/// - `Logger.debug` for high-frequency (per-keystroke, per-onChange) — visible
///   only with `log show --debug`.
/// - `Logger.info` for diagnostic-rare (cache rebuild, date rollover, empty
///   state render) — visible by default in Console.app / `log show`.
///
/// Format: `key=value` style, grep-friendly. Never log user content — only
/// counts/lengths/enum case names.
enum UIObservability {
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "ContentView")
    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Pure format helpers

    static func formatSearchChange(length: Int) -> String {
        "search.length=\(length)"
    }

    static func formatCacheRebuild(groups: Int, items: Int, durationMs: Double) -> String {
        "cache.rebuild groups=\(groups) items=\(items) duration_ms=\(String(format: "%.2f", durationMs))"
    }

    static func formatDateFilterChange(from: ContentView.DateFilter, to: ContentView.DateFilter) -> String {
        // Use String(describing:) so we get raw enum cases ("all"/"today"/...)
        // instead of L10n-localized strings (which break grep across languages).
        // NOTE: if DateFilter ever gains an associated value, String(describing:)
        // would emit "caseName(value)" and break this format. Add rawValue handling
        // or a custom property then. Today DateFilter is `String, CaseIterable`
        // with no associated values — safe.
        // DateFilter is currently nested inside ContentView; the full path keeps
        // the helper here without forcing a top-level relocation.
        "date_filter=\(String(describing: from))→\(String(describing: to))"
    }

    static func formatTagSelectionChange(count: Int) -> String {
        "tag_selection.count=\(count)"
    }

    static func formatCurrentDateRollover(from: Date, to: Date) -> String {
        "current_date.roll from=\(isoFormatter.string(from: from)) to=\(isoFormatter.string(from: to))"
    }

    static func formatEmptyStateRender(name: String, itemCount: Int) -> String {
        "empty_state.render name=\(name) items=\(itemCount)"
    }

    static func formatRefreshTrigger(source: String) -> String {
        "refresh.trigger source=\(source)"
    }

    // MARK: - Logger wrappers

    /// High-frequency (per-keystroke). Use `.debug` so default `log show`
    /// stays clean; enable with `log show --debug` / Console.app debug filter.
    static func logSearchChange(length: Int) {
        logger.debug("\(formatSearchChange(length: length), privacy: .public)")
    }

    /// Diagnostic-rare. Use `.info` so it shows up by default — this is the
    /// one we want to see when "sidebar OK but main empty" happens.
    static func logCacheRebuild(groups: Int, items: Int, durationMs: Double) {
        logger.info("\(formatCacheRebuild(groups: groups, items: items, durationMs: durationMs), privacy: .public)")
    }

    static func logDateFilterChange(from: ContentView.DateFilter, to: ContentView.DateFilter) {
        logger.info("\(formatDateFilterChange(from: from, to: to), privacy: .public)")
    }

    static func logTagSelectionChange(count: Int) {
        logger.info("\(formatTagSelectionChange(count: count), privacy: .public)")
    }

    static func logCurrentDateRollover(from: Date, to: Date) {
        logger.info("\(formatCurrentDateRollover(from: from, to: to), privacy: .public)")
    }

    static func logEmptyStateRender(name: String, itemCount: Int) {
        logger.info("\(formatEmptyStateRender(name: name, itemCount: itemCount), privacy: .public)")
    }

    /// High-frequency (fires on every state change). Use `.debug` — too noisy
    /// for `.info`; the rebuild itself (T4) gets the `.info`.
    static func logRefreshTrigger(source: String) {
        logger.debug("\(formatRefreshTrigger(source: source), privacy: .public)")
    }
}
