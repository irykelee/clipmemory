import XCTest
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-19): behavior tests for `Utils/DateHelpers.swift`.
/// The file exposes two file-scope locked helpers (`cachedAbsoluteDateString`,
/// `cachedRelativeDateString`) and an `enum DateHelpersCache` flush hook. Both
/// helpers wrap an `NSLock` that guards NSCache<NSString, DateFormatter> +
/// NSCache<NSString, RelativeDateTimeFormatter>; the audit found the
/// concurrent-access path was untested. These tests exercise the public
/// surface from multiple threads to pin the locking contract and assert
/// deterministic output for fixed (date, languageCode) inputs.
///
/// Adapted from brief: brief used `someFormatString(Date())` placeholder;
/// the actual API is `cachedAbsoluteDateString(from:languageCode:)` and
/// `cachedRelativeDateString(from:relativeTo:languageCode:)`.
final class DateHelpersBehaviorTests: XCTestCase {

  // MARK: - ID-SYNC-0005: concurrent formatter access

  /// ID-SYNC-0005: 200 concurrent callers (mixed absolute + relative)
  /// must not crash. Without the NSLock the underlying `DateFormatter` is
  /// shared mutable state and concurrent `string(from:)` calls would race
  /// (thread-unsafety in `NSDateFormatter` is documented). ThreadSanitizer
  /// would flag any leak; the test runner's default build is sufficient to
  /// catch a non-crashing deadlock via the 5s timeout.
  func testConcurrentFormatterAccessDoesNotCrash() {
    let now = Date()
    let past = now.addingTimeInterval(-3600)
    let queue = DispatchQueue(label: "test.dateHelpers.concurrent", attributes: .concurrent)
    let group = DispatchGroup()
    let exp = expectation(description: "200 concurrent formatter reads")

    for _ in 0..<100 {
      group.enter()
      queue.async {
        _ = cachedAbsoluteDateString(from: past, languageCode: "en")
        group.leave()
      }
      group.enter()
      queue.async {
        _ = cachedRelativeDateString(from: past, relativeTo: now, languageCode: "en")
        group.leave()
      }
    }
    group.notify(queue: .main) { exp.fulfill() }
    wait(for: [exp], timeout: 5.0)
  }

  /// Mixed-language reads must also not crash — the cache is keyed by
  /// language code so this exercises both the cache miss (first call per
  /// code) and hit (subsequent calls) paths in parallel.
  func testConcurrentMixedLanguageAccessDoesNotCrash() {
    let now = Date()
    let past = now.addingTimeInterval(-60)
    let codes = ["en", "es", "ja", "ko", "pt", "zh-Hans", "zh-Hant"]
    let queue = DispatchQueue(label: "test.dateHelpers.mixed", attributes: .concurrent)
    let group = DispatchGroup()
    let exp = expectation(description: "mixed-language concurrent reads")

    for _ in 0..<50 {
      for code in codes {
        group.enter()
        queue.async {
          _ = cachedAbsoluteDateString(from: past, languageCode: code)
          _ = cachedRelativeDateString(from: past, relativeTo: now, languageCode: code)
          group.leave()
        }
      }
    }
    group.notify(queue: .main) { exp.fulfill() }
    wait(for: [exp], timeout: 5.0)
  }

  // MARK: - Output determinism

  /// Same (date, languageCode) pair must produce the same string on
  /// repeated calls — pins that the cache returns a stable formatter and
  /// that the locale is sticky. Regression: if the locale were
  /// re-evaluated non-deterministically (e.g. depending on which thread
  /// instantiated the formatter first) the UI would render different
  /// formats across renders.
  func testRepeatedCallsProduceIdenticalOutput() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let a = cachedAbsoluteDateString(from: date, languageCode: "en")
    let b = cachedAbsoluteDateString(from: date, languageCode: "en")
    XCTAssertEqual(a, b, "P2-19: same input must produce identical output")

    let now = Date()
    let ra = cachedRelativeDateString(from: date, relativeTo: now, languageCode: "en")
    let rb = cachedRelativeDateString(from: date, relativeTo: now, languageCode: "en")
    XCTAssertEqual(ra, rb, "P2-19: relative same input must produce identical output")
  }

  /// Same date in different language codes must produce non-empty strings
  /// (each language's formatter is independently cached + formatted).
  /// We don't pin the specific format because that's a localization
  /// detail; we pin non-emptiness so a regression that returns "" for a
  /// valid languageCode is caught.
  func testDifferentLanguageCodesProduceNonEmptyOutput() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let now = date.addingTimeInterval(60)
    for code in ["en", "es", "ja", "zh-Hans"] {
      let abs = cachedAbsoluteDateString(from: date, languageCode: code)
      XCTAssertFalse(abs.isEmpty, "P2-19: absolute output must be non-empty for \(code), got: \(abs)")
      let rel = cachedRelativeDateString(from: date, relativeTo: now, languageCode: code)
      XCTAssertFalse(rel.isEmpty, "P2-19: relative output must be non-empty for \(code), got: \(rel)")
    }
  }

  // MARK: - flushMemoryCaches

  /// ID-PERF-0005 (2026-08-16): `DateHelpersCache.flushMemoryCaches()`
  /// is invoked from the macOS memory-warning handler. After flush the
  /// next call must still produce non-empty output (the cache rebuilds
  /// on demand). Regression: if flush dropped the NSCache reference
  /// instead of clearing it, the next call could crash or return "".
  func testFlushMemoryCachesKeepsFormattingFunctional() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let pre = cachedAbsoluteDateString(from: date, languageCode: "en")
    XCTAssertFalse(pre.isEmpty)

    DateHelpersCache.flushMemoryCaches()

    let post = cachedAbsoluteDateString(from: date, languageCode: "en")
    XCTAssertEqual(pre, post, "P2-19: flush must keep formatting output stable")
    XCTAssertFalse(post.isEmpty, "P2-19: post-flush output must be non-empty")
  }

  /// Flush must be idempotent — calling it twice in a row must not crash
  /// and the post-state must still produce output.
  func testFlushMemoryCachesIsIdempotent() {
    DateHelpersCache.flushMemoryCaches()
    DateHelpersCache.flushMemoryCaches()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let s = cachedAbsoluteDateString(from: date, languageCode: "en")
    XCTAssertFalse(s.isEmpty, "P2-19: double-flush must keep formatting functional")
  }
}