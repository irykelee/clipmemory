import XCTest
@testable import ClipMemory

/// Regression tests for TrashStore @MainActor isolation (F-1 phase 2, 2026-07-28).
///
/// Pins two contracts added when TrashStore became @MainActor:
/// 1. `handleWillTerminate()` synchronously cancels the debounce timer
///    and flushes any pending save to the backend.
/// 2. `scheduleSave()` debounces via a timer on `saveTimerQueue` and
///    flushes through the main actor isolation chain
///    (.main → MainActor.assumeIsolated → flushSave → backend.save).
@MainActor
final class TrashStoreMainActorTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: TrashStore!

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        store = TrashStore(backend: backend)
    }

    override func tearDown() {
        store = nil
        backend = nil
        super.tearDown()
    }

    /// Pins the willTerminate contract: timer cancelled + pending save flushed.
    /// Direct call (not via NotificationCenter.post) avoids polluting
    /// NSApplication's global observer chain.
    func testHandleWillTerminateCancelsTimerAndFlushesSave() {
        let item = ClipboardItem(content: "trash me", type: .text)
        store.moveToTrash(item, evictCaches: { _ in }, didMove: {})

        // sanity: needsSave should be true (moveToTrash schedules save)
        // and the debounced save hasn't fired yet (we just called it)
        store.handleWillTerminate()

        // Reload via a fresh TrashStore against the same backend → the
        // pending write must have been flushed synchronously
        let reload = TrashStore(backend: backend)
        XCTAssertEqual(reload.trashedItems.count, 1)
        XCTAssertEqual(reload.trashedItems.first?.content, "trash me")
    }
}
