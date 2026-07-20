import XCTest
@testable import ClipMemory

// Logger wrappers (logXxx) are intentionally not unit-tested: `os.Logger` is
// a concrete type with no protocol seam, and the wrapper bodies are 1-line
// `logger.X("\(formatXxx(...), privacy: .public)")` interpolations. The pure
// format helpers below are what carries the meaningful behavior; if a wrapper
// regressed (typo, wrong verbosity) the bug would surface immediately in a
// manual Console.app smoke test (T5). StartupHealth shipped the same tradeoff.

/// ABC §B UI observability: pure format helpers for Logger.info / Logger.debug
/// payloads. Mirrors StartupHealthTests — format helpers take primitives only so
/// tests cannot accidentally touch ClipboardStore.shared or the real UserDefaults
/// (per C1 test-never-touch-prod-data).
final class UIObservabilityTests: XCTestCase {

    // MARK: - Search

    func testFormatSearchChange() {
        let s = UIObservability.formatSearchChange(length: 5)
        XCTAssertEqual(s, "search.length=5")
    }

    func testFormatSearchChangeZero() {
        let s = UIObservability.formatSearchChange(length: 0)
        XCTAssertEqual(s, "search.length=0")
    }

    // MARK: - Cache rebuild

    func testFormatCacheRebuild() {
        let s = UIObservability.formatCacheRebuild(groups: 3, items: 42, durationMs: 12.34)
        XCTAssertEqual(s, "cache.rebuild groups=3 items=42 duration_ms=12.34")
    }

    func testFormatCacheRebuildZeroGroups() {
        let s = UIObservability.formatCacheRebuild(groups: 0, items: 0, durationMs: 0.5)
        XCTAssertEqual(s, "cache.rebuild groups=0 items=0 duration_ms=0.50")
    }

    // MARK: - DateFilter

    func testFormatDateFilterChangeAllToToday() {
        let s = UIObservability.formatDateFilterChange(from: ContentView.DateFilter.all, to: ContentView.DateFilter.today)
        XCTAssertEqual(s, "date_filter=all→today")
    }

    func testFormatDateFilterChangeTodayToYesterday() {
        let s = UIObservability.formatDateFilterChange(from: ContentView.DateFilter.today, to: ContentView.DateFilter.yesterday)
        XCTAssertEqual(s, "date_filter=today→yesterday")
    }

    // MARK: - Tag selection

    func testFormatTagSelectionChangeEmpty() {
        let s = UIObservability.formatTagSelectionChange(count: 0)
        XCTAssertEqual(s, "tag_selection.count=0")
    }

    func testFormatTagSelectionChangeMany() {
        let s = UIObservability.formatTagSelectionChange(count: 7)
        XCTAssertEqual(s, "tag_selection.count=7")
    }

    // MARK: - CurrentDate rollover

    func testFormatCurrentDateRollover() {
        let from = Date(timeIntervalSince1970: 1_723_000_000)
        let to = Date(timeIntervalSince1970: 1_723_086_400) // +1 day
        let s = UIObservability.formatCurrentDateRollover(from: from, to: to)
        XCTAssertTrue(s.hasPrefix("current_date.roll from="), s)
        XCTAssertTrue(s.contains("to="), s)
    }

    // MARK: - Empty state

    func testFormatEmptyStateRender() {
        let s = UIObservability.formatEmptyStateRender(name: "no_items", itemCount: 0)
        XCTAssertEqual(s, "empty_state.render name=no_items items=0")
    }

    // MARK: - Refresh trigger

    func testFormatRefreshTrigger() {
        let s = UIObservability.formatRefreshTrigger(source: "dateFilter")
        XCTAssertEqual(s, "refresh.trigger source=dateFilter")
    }
}
