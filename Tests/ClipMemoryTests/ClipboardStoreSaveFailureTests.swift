import XCTest
@testable import ClipMemory

/// ID-SILENT-0021 (2026-08-08 audit): `ClipboardStore.flushSave()` previously
/// swallowed `saveItems()` errors via the inner `catch { logger.error(...) }`
/// inside `saveItems()`. When `backend.saveBlob` failed (disk full / permission
/// denied / iCloud sync conflict) and `needsSave` had already been cleared,
/// the timer-driven retry would skip on the next fire, silently losing the
/// user's clipboard capture for the rest of the session.
///
/// The fix makes `saveItems()` rethrow, wraps the call in `flushSave` with
/// `do/catch`, restores `needsSave = true` for the next retry, and posts a
/// `.clipboardSaveFailed` notification so the UI can surface a non-dismissable
/// error banner.
///
/// These tests pin the post-fix contract.
@MainActor
final class ClipboardStoreSaveFailureTests: XCTestCase {

    private var backend: CountingBackend!
    private var tagBackend: MemoryStorageBackend!
    private var trashBackend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // M13 (2026-08-03): per-test injected defaults prevent TrashStore /
        // UpdateService didSet writes from polluting production.
        testDefaults = makeTestDefaults()
        backend = CountingBackend()
        tagBackend = MemoryStorageBackend()
        trashBackend = MemoryStorageBackend()
        store = ClipboardStore(
            backend: backend,
            tagBackend: tagBackend,
            trashBackend: trashBackend,
            defaults: testDefaults
        )
    }

    override func tearDown() {
        store = nil
        backend = nil
        trashBackend = nil
        tagBackend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// ID-SILENT-0021 fix: backend failure must surface via notification, not
    /// silent log + drop.
    func testFlushSavePostsNotificationOnBackendFailure() {
        backend.failNextSave = true
        var postCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .clipboardSaveFailed,
            object: nil,
            queue: .main
        ) { _ in postCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let item = ClipboardItem(content: "captured", type: .text)
        store.addItem(item) // scheduleSave → timer started
        store.flushSave()   // immediate flush, will fail and post

        // Spin the runloop briefly to let the synchronous post be observed.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThanOrEqual(postCount, 1, "notification must post on backend failure")
        XCTAssertGreaterThanOrEqual(backend.saveCallCount, 1, "backend.saveBlob was called")
    }

    /// ID-SILENT-0021 fix: after a failure, `needsSave` must be restored so
    /// the next timer fire retries. Pre-fix, `needsSave` was cleared inside
    /// flushSave before the swallow, so the next timer fired and exited via
    /// `guard needsSave else { return }` — silent loss.
    func testFlushSaveRestoresNeedsSaveAfterFailure() {
        backend.failNextSave = true
        store.addItem(ClipboardItem(content: "captured", type: .text))

        store.flushSave() // attempt 1 — fails, needsSave restored
        XCTAssertGreaterThanOrEqual(backend.saveCallCount, 1)

        backend.failNextSave = false // backend recovers
        store.flushSave() // attempt 2 — must retry because needsSave was restored

        XCTAssertGreaterThanOrEqual(
            backend.saveCallCount,
            2,
            "second flushSave must retry the backend write after the first failure"
        )
    }

    /// ID-SILENT-0021 fix: `saveImmediately()` (the write-through path used by
    /// clipboard capture) must also surface backend failures — not crash and
    /// not silently drop.
    func testSaveImmediatelyPropagatesBackendFailure() {
        backend.failNextSave = true
        var postCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .clipboardSaveFailed,
            object: nil,
            queue: .main
        ) { _ in postCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let item = ClipboardItem(content: "captured", type: .text)
        store.addItem(item)        // scheduleSave
        store.saveImmediately()    // write-through, will fail

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThanOrEqual(postCount, 1, "saveImmediately failure posts notification")
        XCTAssertGreaterThanOrEqual(backend.saveCallCount, 1, "backend was attempted")
        XCTAssertEqual(store.items.count, 1, "in-memory items must not be cleared on disk failure")
    }

    /// Negative test: a successful save must not post the failure notification.
    /// Guards against over-eager fix that fires on every save.
    func testFlushSaveDoesNotPostNotificationOnSuccess() {
        let item = ClipboardItem(content: "captured", type: .text)
        store.addItem(item)

        var postCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .clipboardSaveFailed,
            object: nil,
            queue: .main
        ) { _ in postCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.flushSave()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThanOrEqual(backend.saveCallCount, 1)
        XCTAssertEqual(postCount, 0, "no failure notification on successful save")
    }

    // MARK: - H-1 (2026-08-08 audit): autonomous retry with exponential backoff

    /// H-1 fix: backend failure must increment the retry counter so a
    /// persistent disk error walks the backoff ladder (500ms → 16s).
    /// `addItem` internally calls `saveImmediately()` → `flushSave()`,
    /// so the first failure happens during addItem, not during the
    /// explicit flushSave() call below.
    func testFlushSaveFailure_incrementsRetryCounter() {
        backend.failNextSave = true
        store.addItem(ClipboardItem(content: "captured", type: .text))
        XCTAssertEqual(store.saveRetryState.consecutiveFailures, 1,
                       "first failure (during addItem's write-through) must increment the retry counter")
    }

    /// H-1 fix: a successful save must reset the retry counter so a later
    /// disk error starts the backoff ladder from the bottom, not in the
    /// middle. Without this, a recovered-then-broken-again disk would
    /// hammer the user with 16s-backoff retries.
    func testFlushSaveSuccess_resetsRetryCounter() {
        backend.failNextSave = true
        store.addItem(ClipboardItem(content: "captured", type: .text))
        // addItem's internal saveImmediately triggered the one allowed
        // failure; counter is now 1 and failNextSave auto-reset to false.
        XCTAssertEqual(store.saveRetryState.consecutiveFailures, 1)

        // Now the backend has recovered — the next flushSave (either the
        // auto-retry timer or an explicit call) must reset the counter.
        store.flushSave()
        XCTAssertEqual(store.saveRetryState.consecutiveFailures, 0,
                       "successful save must reset the retry counter")
    }

    /// H-1 fix: the next retry interval must follow the backoff ladder and
    /// cap at 16s. Pinning exact values — a tighter cap (e.g. 4s) would
    /// drop retries during long transient iCloud sync conflicts; a larger
    /// cap (e.g. 60s) would silence persistent disk errors too long.
    func testSaveRetryState_backoffLadder() {
        var state = SaveRetryState()
        XCTAssertEqual(state.nextBackoffSeconds, 0.5, accuracy: 0.001)
        state.recordFailure()
        XCTAssertEqual(state.nextBackoffSeconds, 0.5, accuracy: 0.001)

        state.recordFailure()
        XCTAssertEqual(state.nextBackoffSeconds, 1.0, accuracy: 0.001)

        state.recordFailure()
        XCTAssertEqual(state.nextBackoffSeconds, 2.0, accuracy: 0.001)

        state.recordFailure()
        XCTAssertEqual(state.nextBackoffSeconds, 4.0, accuracy: 0.001)

        state.recordFailure()
        XCTAssertEqual(state.nextBackoffSeconds, 8.0, accuracy: 0.001)

        state.recordFailure()
        XCTAssertEqual(state.nextBackoffSeconds, 16.0, accuracy: 0.001,
                       "backoff must cap at 16s")

        state.recordFailure()
        state.recordFailure()
        state.recordFailure()
        XCTAssertEqual(state.nextBackoffSeconds, 16.0, accuracy: 0.001,
                       "backoff must remain capped after repeated failures")
    }

    /// H-1 fix: a successful save must reset the backoff ladder so the next
    /// failure starts at 500ms, not at whatever the cap value was.
    func testSaveRetryState_successResetsBackoff() {
        var state = SaveRetryState()
        for _ in 0..<10 { state.recordFailure() }
        XCTAssertEqual(state.nextBackoffSeconds, 16.0, accuracy: 0.001)

        state.recordSuccess()
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertEqual(state.nextBackoffSeconds, 0.5, accuracy: 0.001,
                       "after success, next failure must start at the base backoff")
    }

    /// H-1 fix: a failed flushSave must reschedule saveTimer with the
    /// current backoff so the next attempt fires automatically — without
    /// relying on the next user mutation to trigger saveImmediately.
    /// We can't observe DispatchSourceTimer's internal fire deadline
    /// directly, but we can verify the failure schedules a callback by
    /// counting backend.saveCallCount after waiting past the backoff.
    func testFlushSaveFailure_schedulesAutoRetryWithinBackoff() {
        backend.failNextSave = true
        store.addItem(ClipboardItem(content: "captured", type: .text))
        // addItem's saveImmediately already called saveBlob once (failed);
        // the retry timer was scheduled for 500ms in the catch block.
        let initialCalls = backend.saveCallCount

        // Backend has already recovered (failNextSave auto-reset on the
        // first failure). The auto-retry must call saveBlob again within
        // the base backoff window. Allow 1.5s slack for slow CI runners
        // while still catching the bug where the timer wasn't rescheduled
        // at all (which would manifest as no further backend calls ever).
        let deadline = Date().addingTimeInterval(1.5)
        var observedRetry = false
        while Date() < deadline {
            if backend.saveCallCount > initialCalls { observedRetry = true; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(observedRetry,
                      "first auto-retry must fire within the base backoff window — pre-fix the timer wasn't rescheduled")
        XCTAssertEqual(store.saveRetryState.consecutiveFailures, 0,
                       "successful auto-retry resets the retry counter")
    }

    /// H-1 fix: the failure notification must carry a `source` tag so the
    /// AppDelegate throttler can bucket disk-full vs iCloud-sync-conflict
    /// vs permission-revoked independently — without sourceKey, one
    /// transient failure would suppress alerts for unrelated causes.
    func testFlushSaveFailure_postsNotificationWithSaveSource() {
        backend.failNextSave = true
        var capturedSource: String?
        let token = NotificationCenter.default.addObserver(
            forName: .clipboardSaveFailed,
            object: nil,
            queue: .main
        ) { note in capturedSource = note.userInfo?["source"] as? String }
        defer { NotificationCenter.default.removeObserver(token) }

        store.addItem(ClipboardItem(content: "captured", type: .text))
        store.flushSave()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(capturedSource, "saveFlush",
                       "save-failure notifications must tag source='saveFlush' so the throttler can bucket per-cause")
    }
}

// MARK: - Test backend

/// Test-only `StorageBackend` that counts save calls and can be made to fail
/// the next save on demand. Lives in this test file (not StorageBackend.swift)
/// because no production code should depend on it.
private final class CountingBackend: StorageBackend {
    var saveCallCount = 0
    var failNextSave = false

    private let lock = NSLock()
    private var _items: [ClipboardItem] = []
    private var _tags: [Tag] = []

    func load() throws -> [ClipboardItem] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    func save(_ items: [ClipboardItem]) throws {
        lock.lock(); defer { lock.unlock() }
        saveCallCount += 1
        if failNextSave {
            failNextSave = false
            throw NSError(
                domain: "CountingBackend",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Injected disk-full failure (test)"]
            )
        }
        _items = items
    }

    func saveBlob(_ data: Data) throws {
        // ID-SILENT-0021 fix: ClipboardStore now calls saveBlob directly
        // (CLIP-2 path). The default protocol impl decodes JSON then calls
        // `save(_:)`, which is what we want — our failure injection lives
        // in `save(_:)`, so the saveBlob path inherits the same behavior.
        let items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        try save(items)
    }

    func loadTags() throws -> [Tag] {
        lock.lock(); defer { lock.unlock() }
        return _tags
    }

    func saveTags(_ tags: [Tag]) throws {
        lock.lock(); defer { lock.unlock() }
        _tags = tags
    }
}
