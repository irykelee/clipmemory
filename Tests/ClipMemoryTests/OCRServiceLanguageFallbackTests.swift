import XCTest
@testable import ClipMemory

/// L26 Path H (2026-08-15): exercise the language fallback path in
/// `VisionOCRService.supportedRecognitionLanguages(from:)`.
///
/// Hypothesis (per `feedback/l26-live-drill-beats-static-audit`): static
/// review found the fallback chain (M-23 / CLIP-5 / ID-OCR-0002):
///   - filter requested by supported
///   - if filtered is empty → log + post `.ocrLanguageFallback` notification
///   - return ["en"] if en is in supported, else `Array(supported.prefix(1))`
/// What is NOT directly tested: the return value when ALL requested languages
/// are unsupported AND en is also unsupported (the `Array(supported.prefix(1))`
/// branch), the notification userInfo keys, and the empty-supported edge
/// case (query returns [], not throws).
///
/// All tests use the `recognitionLanguagesQuery` injection point (sealed at
/// ID-SILENT-0016) and the `resetSupportedLanguagesCacheForTesting()` helper
/// to keep tests isolated. The L26 setup-tearDown rule (double-reset of any
/// static injection in both hooks) is honored by paired `original` capture
/// and `defer` restoration in each test.
final class OCRServiceLanguageFallbackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // L26 cross-test ordering trap: the OCRService posts via
        // `DispatchQueue.main.async`. If a previous test fired the
        // notification and the main queue hadn't drained yet (because the
        // test thread didn't yield), the queued post can fire DURING a
        // later test's setUp or runloop drain — and pollute a fresh
        // observer's `fired` flag. Drain the main queue before every
        // test to start from a clean slate.
        let drainExp = expectation(description: "main queue drain (setUp)")
        DispatchQueue.main.async { drainExp.fulfill() }
        wait(for: [drainExp], timeout: 1.0)
        VisionOCRService.resetSupportedLanguagesCacheForTesting()
    }

    override func tearDown() {
        // Same drain on tearDown: pending posts from this test must fire
        // BEFORE the next test's setUp, otherwise they'd race with the
        // next test's observer.
        let drainExp = expectation(description: "main queue drain (tearDown)")
        DispatchQueue.main.async { drainExp.fulfill() }
        wait(for: [drainExp], timeout: 1.0)
        VisionOCRService.resetSupportedLanguagesCacheForTesting()
        super.tearDown()
    }

    /// Capture-then-restore pattern for the static injection. Each test
    /// saves `recognitionLanguagesQuery`, reassigns, and `defer`s back.
    private func withStubbedQuery(_ stub: @escaping (Int) throws -> [String],
                                  body: () throws -> Void) rethrows {
        let original = VisionOCRService.recognitionLanguagesQuery
        VisionOCRService.recognitionLanguagesQuery = stub
        defer { VisionOCRService.recognitionLanguagesQuery = original }
        try body()
    }

    // MARK: - All requested unsupported (the documented fallback path)

    /// Happy fallback: requested = CJK, supported = en + fr. The filter
    /// drops everything; the fallback returns `["en"]`. Verifies the
    /// ID-OCR-0002 / M-23 "en is the canonical fallback" contract.
    func testFallbackReturnsEnWhenEnIsSupported() throws {
        try withStubbedQuery({ _ in ["en", "fr", "de"] }) {
            let result = VisionOCRService.supportedRecognitionLanguages(
                from: ["zh-Hans", "zh-Hant", "ja", "ko"]
            )
            XCTAssertEqual(result, ["en"],
                "all CJK dropped; en is supported; fallback returns en only")
        }
    }

    /// Edge case: requested = CJK, supported = fr + de (NO en). The
    /// fallback's documented contract (CLIP-5) is "first supported" when
    /// en is missing. Captures the current behavior so any future change
    /// is a conscious decision.
    func testFallbackReturnsFirstSupportedWhenEnIsMissing() throws {
        try withStubbedQuery({ _ in ["fr", "de"] }) {
            let result = VisionOCRService.supportedRecognitionLanguages(
                from: ["zh-Hans"]
            )
            XCTAssertEqual(result, ["fr"],
                "en missing → CLIP-5: Array(supported.prefix(1)) returns first supported")
        }
    }

    /// Edge case: requested = CJK, supported = [] (empty, NOT thrown).
    /// Per line 401-404 comment, "supported can even be empty when the
    /// query throws" — but `supported` here is the cached/returned value
    /// of the query. If the query succeeds and returns [], `supported` is
    /// [] and the fallback `Array(supported.prefix(1))` returns `[]`.
    /// Setting `recognitionLanguages = []` on the request makes
    /// `handler.perform` either crash or fall back to Vision's default —
    /// either way this is an edge case worth capturing. **Documented
    /// behavior**: returns []. If a future macOS makes this crash, this
    /// test catches it.
    func testFallbackReturnsEmptyWhenSupportedIsEmpty() throws {
        try withStubbedQuery({ _ in [] }) {
            let result = VisionOCRService.supportedRecognitionLanguages(
                from: ["zh-Hans"]
            )
            XCTAssertEqual(result, [],
                "supported is empty → first-supported prefix returns []; documented fragile edge case")
        }
    }

    // MARK: - Notification contract (ID-OCR-0002)

    /// ID-OCR-0002: when the fallback fires, post `.ocrLanguageFallback`
    /// with `requested`/`supported`/`dropped`/`userLocale` keys. Verifies
    /// the notification is async on main (DispatchQueue.main.async) and
    /// carries the full userInfo payload that a future settings banner
    /// observer would consume.
    ///
    /// Note on async: OCRService posts via `DispatchQueue.main.async`, so
    /// the test must drain the main runloop. `XCTestExpectation` +
    /// `wait(for:)` does this correctly; a `Thread.sleep` would NOT.
    func testFallbackPostsNotificationWithFullUserInfo() throws {
        try withStubbedQuery({ _ in ["en"] }) {
            let exp = expectation(description: ".ocrLanguageFallback posted")
            var captured: [AnyHashable: Any]?
            let token = NotificationCenter.default.addObserver(
                forName: .ocrLanguageFallback,
                object: nil,
                queue: nil
            ) { note in
                captured = note.userInfo
                exp.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            _ = VisionOCRService.supportedRecognitionLanguages(from: ["zh-Hans", "ja"])

            wait(for: [exp], timeout: 2.0)
            XCTAssertNotNil(captured, ".ocrLanguageFallback notification must be posted when fallback fires")
            guard let info = captured else { return }
            XCTAssertNotNil(info["requested"] as? [String],
                "userInfo[requested] missing or wrong type")
            XCTAssertNotNil(info["supported"] as? [String],
                "userInfo[supported] missing or wrong type")
            XCTAssertNotNil(info["dropped"] as? [String],
                "userInfo[dropped] missing or wrong type")
            XCTAssertNotNil(info["userLocale"] as? String,
                "userInfo[userLocale] missing or wrong type")
            // The dropped list contains exactly what was requested but
            // not supported.
            let dropped = info["dropped"] as? [String] ?? []
            XCTAssertTrue(dropped.contains("zh-Hans"),
                "zh-Hans must appear in dropped (not in supported=[en])")
            XCTAssertTrue(dropped.contains("ja"),
                "ja must appear in dropped (not in supported=[en])")
        }
    }

    /// Negative test: when the requested list IS fully supported, the
    /// fallback does NOT fire and the notification must NOT be posted.
    /// Guards against accidental always-on notifications.
    ///
    /// Note on "no notification expected": `XCTestExpectation` is NOT used
    /// here because we want to assert "no notification" — there's no
    /// expectation to wait for. Instead, register a flag observer; if the
    /// notification arrives within a short main-runloop drain, fail.
    func testNoNotificationWhenAllRequestedSupported() throws {
        try withStubbedQuery({ _ in ["zh-Hans", "ja", "en", "ko"] }) {
            var fired = false
            let token = NotificationCenter.default.addObserver(
                forName: .ocrLanguageFallback,
                object: nil,
                queue: nil
            ) { _ in fired = true }
            defer { NotificationCenter.default.removeObserver(token) }

            let result = VisionOCRService.supportedRecognitionLanguages(
                from: ["zh-Hans", "ja"]
            )
            XCTAssertEqual(result, ["zh-Hans", "ja"],
                "all supported → filter passes through unchanged")
            // Drain the main runloop briefly so an async-posted notification
            // would have a chance to fire if it were going to.
            let exp = expectation(description: "main runloop drain")
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 0.5)
            XCTAssertFalse(fired,
                "no fallback fired → no notification posted")
        }
    }

    // MARK: - Query failure (ID-SILENT-0016)

    /// When the Vision `supportedRecognitionLanguages` query throws, the
    /// function returns [] and does NOT cache (per ID-SILENT-0016). The
    /// returned [] flows into the fallback path → `Array([].prefix(1))`
    /// = []. Setting request.recognitionLanguages = [] at the caller is
    /// the same edge case as testFallbackReturnsEmptyWhenSupportedIsEmpty.
    /// Document the interaction between query-throws and the fallback.
    func testQueryThrowPropagatesAsEmptyAndDoesNotCache() throws {
        // First call: throws → returns [], not cached.
        try withStubbedQuery({ _ in
            throw NSError(domain: "Vision", code: -1)
        }) {
            let first = VisionOCRService.supportedRecognitionLanguages(for: 3)
            XCTAssertEqual(first, [],
                "thrown query returns [] for this call only; not cached")
        }
        // Second call: stubbed to succeed → real Vision's supported list.
        // (Returning ["en"] is a reasonable supported stub.)
        try withStubbedQuery({ _ in ["en"] }) {
            let second = VisionOCRService.supportedRecognitionLanguages(for: 3)
            XCTAssertEqual(second, ["en"],
                "throw did not cache → next call queries fresh and succeeds")
        }
    }
}

/// XCTest case-local NotificationCenter observer that captures the next
/// matching notification. Used by OCR fallback tests that need to inspect
/// `userInfo` synchronously after a stub-driven code path.
final class NotificationObserver {
    private let name: Notification.Name
    private var token: NSObjectProtocol?
    private(set) var captured: [AnyHashable: Any]?
    private let lock = NSLock()
    private var semaphore = DispatchSemaphore(value: 0)

    init(notificationName: Notification.Name) {
        self.name = notificationName
        token = NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.lock.lock()
            self?.captured = note.userInfo
            self?.lock.unlock()
            self?.semaphore.signal()
        }
    }

    /// Block up to `timeout` seconds for the notification to arrive.
    /// Returns `userInfo` (nil if timeout).
    func wait(timeout: TimeInterval) -> [AnyHashable: Any]? {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stop() {
        if let token = token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    deinit { stop() }
}