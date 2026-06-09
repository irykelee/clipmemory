import XCTest
@testable import ClipMemory

/// M.1-M.3: Additional ClipboardMonitor tests complementing existing coverage.
/// - E.1-E.3 (ConcurrencyTests) cover skipNextCapture + excludedBundleIds thread safety
/// - D.1-D.3 (SensitiveDetectorTests) cover all sensitive patterns
/// This file fills the remaining gaps:
/// - recordOwnWrite basic semantics (idempotency under repeated calls)
/// - lazy regex compilation + caching (R10 perf fix regression guard)
///
/// Note: captureRichText is private (managed by Combine pipeline), so it's not
/// directly testable from outside — but it shares the same stateLock as the
/// publicly-tested properties, which validates the lock mechanism.
final class ClipboardMonitorTests: XCTestCase {

    // MARK: - M.1 recordOwnWrite

    func testRecordOwnWriteSetsSkipNextCaptureTrue() {
        // M.1.1: ClipboardStore calls recordOwnWrite() after writing to pasteboard
        // to break the copy loop. Must set skipNextCapture=true.
        let monitor = ClipboardMonitor()
        monitor.skipNextCapture = false
        monitor.recordOwnWrite()
        XCTAssertTrue(monitor.skipNextCapture)
    }

    func testRecordOwnWriteIsIdempotent() {
        // M.1.2: Repeated calls remain safe — skipNextCapture stays true,
        // lastChangeCount gets re-synced each time. No state corruption.
        let monitor = ClipboardMonitor()
        monitor.recordOwnWrite()
        monitor.recordOwnWrite()
        monitor.recordOwnWrite()
        XCTAssertTrue(monitor.skipNextCapture)
    }

    // MARK: - M.2 lazy regex compilation (R10: compile once, cache forever)

    func testSensitiveValueRegexesLazyInit() {
        // M.2.1: First access compiles all 6 sensitive-value patterns.
        // If any pattern is invalid, the lazy initializer would log + skip it,
        // so a non-empty result is the success signal.
        let monitor = ClipboardMonitor()
        let regexes = monitor.sensitiveValueRegexes
        XCTAssertFalse(regexes.isEmpty, "sensitiveValueRegexes should compile on first access")
    }

    func testSensitiveValueRegexesCachedAcrossAccesses() {
        // M.2.2: Lazy var caches the result. Arrays are value types (can't `===` them),
        // but the inner NSRegularExpression objects are reference types — if the lazy var
        // were "simplified" to a computed property, every access would re-compile and
        // produce different NSRegularExpression instances.
        let monitor = ClipboardMonitor()
        let first = monitor.sensitiveValueRegexes
        let second = monitor.sensitiveValueRegexes
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertTrue(a === b, "NSRegularExpression should be the same cached instance (regression: lazy→computed)")
        }
    }

    func testCompiledSensitivePatternsLazyInit() {
        // M.2.3: First access compiles the regex portion of sensitivePatterns.
        let monitor = ClipboardMonitor()
        let compiled = monitor.compiledSensitivePatterns
        XCTAssertFalse(compiled.isEmpty, "compiledSensitivePatterns should compile on first access")
        // Every compiled entry should have a non-empty source keyword (regression: index misalignment)
        for entry in compiled {
            XCTAssertFalse(entry.keyword.isEmpty, "compiled entry should preserve source keyword")
        }
    }

    func testCompiledSensitivePatternsCachedAcrossAccesses() {
        // M.2.4: Same caching guarantee as sensitiveValueRegexes. Verify the inner
        // NSRegularExpression objects keep their identity across accesses.
        let monitor = ClipboardMonitor()
        let first = monitor.compiledSensitivePatterns
        let second = monitor.compiledSensitivePatterns
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertTrue(a.regex === b.regex, "NSRegularExpression should be the same cached instance")
            XCTAssertEqual(a.keyword, b.keyword)
        }
    }
}
