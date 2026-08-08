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
