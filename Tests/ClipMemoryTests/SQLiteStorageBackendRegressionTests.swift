import XCTest
@testable import ClipMemory

/// ID-REVIEW-1027 (2026-11-12): regression tests for the two latent
/// defects that had to be fixed before the SQLite backend could be wired
/// into production (docs/design/storage-migration.md 5.5 transaction
/// ownership, 5.6 dangling tag blast radius).
///
/// Split out of `SQLiteStorageBackendTests` on 2026-11-12: that file
/// crossed the 800-line SwiftLint threshold when these cases were added
/// to it, and the project's ratchet policy does not accept new
/// violations - so the new cases live here instead.
final class SQLiteStorageBackendRegressionTests: XCTestCase {

    // MARK: - Test fixtures

    private var tempURL: URL!
    private var backend: SQLiteStorageBackend!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteBackendRegressionTests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("store.sqlite3")
        backend = try SQLiteStorageBackend(databaseURL: tempURL)
    }

    override func tearDown() {
        // Release the backend BEFORE deleting its directory
        // (ID-CRASH-0022): unlinking the database file while the
        // connection still has it open makes libsqlite3 report
        // "database integrity compromised by API violation".
        backend = nil
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        tempURL = nil
        super.tearDown()
    }

    /// ID-REVIEW-1027 (2026-11-12): a second thread must not be able to
    /// believe it owns a transaction it did not open.
    ///
    /// The defect (docs/design/storage-migration.md §5.5): the old
    /// transaction trio took the connection lock PER CALL. Between
    /// `beginTransaction()` returning and the first statement, the lock
    /// was free — so another thread could enter, observe
    /// `sqlite3_get_autocommit(db) == 0` (CONNECTION state, not
    /// ownership) and conclude that IT owned the transaction. Its write
    /// was then absorbed into a transaction it did not own, and an error
    /// on the owner's side rolled that write back: the other thread's
    /// write "succeeded" and then vanished.
    ///
    /// The scenario: thread A opens a transaction and holds it; thread B
    /// writes while A's transaction is open.
    ///
    ///   - BEFORE the fix: B's write lands inside A's transaction, and
    ///     A's rollback takes it away even though B's call returned
    ///     successfully.
    ///   - AFTER the fix: the transaction scope holds the lock for its
    ///     whole life, so B cannot enter the backend at all until A has
    ///     committed or rolled back. B's write is committed by B.
    ///
    /// The assertion is made through a SECOND connection: a row that only
    /// the writing connection can see is not committed.
    func testConcurrentWriteIsNotAbsorbedIntoAnotherThreadsTransaction() throws {
        let ownerReady = DispatchSemaphore(value: 0)
        let writerStarted = DispatchSemaphore(value: 0)
        // TWO semaphores for the writer's completion, on purpose.
        //
        // A `DispatchSemaphore` is a COUNTER: one `signal()` satisfies one
        // `wait()`. The transaction owner waits for the writer inside its
        // transaction, and the main thread waits for the writer to be done
        // before it reads the rows back. If both waited on the SAME
        // semaphore, the owner's wait would consume the single permit and
        // the main thread would block FOREVER - the first version of this
        // test hung exactly that way, and the hang looked like a
        // production deadlock.
        let writerFinished = DispatchSemaphore(value: 0)   // the owner's view
        let writerDone = DispatchSemaphore(value: 0)        // the main thread's view
        let ownerFinished = DispatchSemaphore(value: 0)

        // Thread A owns the transaction and rolls it back on purpose;
        // thread B writes while A's transaction is open.
        startOwnerThread(
            ownerReady: ownerReady,
            writerStarted: writerStarted,
            writerFinished: writerFinished,
            ownerFinished: ownerFinished
        )
        startWriterThread(
            ownerReady: ownerReady,
            writerStarted: writerStarted,
            writerFinished: writerFinished,
            writerDone: writerDone
        )

        // BOUNDED waits on the main thread. An unbounded wait here turns
        // any failure into a HANG: the suite stalls, the CI budget burns,
        // and the real assertion never gets a chance to fail. Every wait
        // is bounded, and the bound is asserted - a timeout is a failure
        // with a readable message, not a hang.
        let ownerDone = ownerFinished.wait(timeout: .now() + 30)
        NSLog("[tx-test] main: ownerDone=\(ownerDone)")
        let writerOk = writerDone.wait(timeout: .now() + 30)
        NSLog("[tx-test] main: writerOk=\(writerOk)")
        XCTAssertEqual(ownerDone, .success, "the transaction owner must finish")
        XCTAssertEqual(writerOk, .success, "the concurrent writer must finish")

        // Read it back through a SECOND connection: only a committed row
        // is visible there.
        var reader: SQLiteStorageBackend? = try SQLiteStorageBackend(databaseURL: tempURL)
        let visible = try reader!.load()
        reader = nil

        XCTAssertTrue(
            visible.contains { $0.content == "writer-item" },
            "the other thread's write must be committed, not absorbed into a transaction it did not own"
        )
        XCTAssertFalse(
            visible.contains { $0.content == "owner-item" },
            "the owner's rolled-back row must not be committed"
        )
    }

    /// ID-REVIEW-1027 (2026-11-12): ONE dangling tag reference must not
    /// void the whole save.
    ///
    /// The defect (docs/design/storage-migration.md §5.6): the tag
    /// catalog failed to decode, so it reads as empty; an item that
    /// carries a tag id then hits the `item_tags` FOREIGN KEY; the whole
    /// transaction rolls back; the user's ENTIRE clipboard history fails
    /// to save that round. One unreadable tag directory took the whole
    /// history with it.
    ///
    /// The fix: skip the one association (and log it), keep the rest of
    /// the save. The assertion is the one the design doc demands: with an
    /// empty catalog, the OTHER items still save.
    @MainActor
    func testOneDanglingTagReferenceDoesNotVoidTheWholeSave() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DanglingTag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = try SQLiteStorageBackend(
            databaseURL: dir.appendingPathComponent("store.sqlite3")
        )
        let suite = "DanglingTag-\(UUID().uuidString)"
        let defaults = TestSuiteCleanup.makeSuite(named: suite)
        addTeardownBlock { TestSuiteCleanup.destroy(defaults) }

        let store = ClipboardStore(backend: backend, defaults: defaults)
        // The catalog is EMPTY - the shape a failed tag decode leaves.
        store.tags = [:]
        let orphanTagID = UUID()
        store.items = [
            ClipboardItem(content: "tagged", type: .text, tagIds: [orphanTagID]),
            ClipboardItem(content: "untagged", type: .text)
        ]

        try store.saveItems()

        let saved = try backend.load()
        XCTAssertEqual(saved.count, 2,
                       "a dangling tag link must not void the rest of the save")
        XCTAssertTrue(saved.contains { $0.content == "tagged" },
                      "the item carrying the dangling tag must still be saved")
        XCTAssertTrue(saved.contains { $0.content == "untagged" },
                      "the other items must still be saved")
    }

    // MARK: - Worker threads for the transaction-ownership test

    /// Thread A: opens a transaction, writes a row, lets the writer in,
    /// then rolls the transaction back on purpose.
    ///
    /// The backend is captured into a local BEFORE the async block, so a
    /// worker that outlives the test cannot read the `nil` that
    /// `tearDown` writes into the IUO property.
    private func startOwnerThread(
        ownerReady: DispatchSemaphore,
        writerStarted: DispatchSemaphore,
        writerFinished: DispatchSemaphore,
        ownerFinished: DispatchSemaphore
    ) {
        let backend = self.backend!
        let ownerQueue = DispatchQueue(label: "clipmemory.test.tx.owner", qos: .userInteractive)
        ownerQueue.async {
            defer { ownerFinished.signal() }
            do {
                try backend.withTransaction {
                    try backend.upsertItem(
                        ClipboardItem(content: "owner-item", type: .text)
                    )
                    NSLog("[tx-test] A: wrote owner-item, transaction open")
                    // The transaction is open and holds the lock. Tell the
                    // writer to go now, and wait until it has actually
                    // REACHED the backend.
                    ownerReady.signal()
                    NSLog("[tx-test] A: signaled ownerReady")
                    _ = writerStarted.wait(timeout: .now() + 5)
                    NSLog("[tx-test] A: writerStarted")
                    // Bounded wait for the writer to finish.
                    //
                    // WITH the fix the writer is BLOCKED on the lock this
                    // scope holds, so it cannot finish before the rollback
                    // and this wait times out.
                    //
                    // WITHOUT the fix (no lock) the writer walks straight
                    // into this transaction, its write is absorbed, and it
                    // signals at once - so the rollback then takes that
                    // write away and the assertions in the test go red.
                    //
                    // The handshake above (writerStarted) is what makes
                    // this deterministic: the writer is guaranteed to be
                    // inside the transaction window before the owner
                    // rolls back, so the mutation cannot slip through on
                    // a lucky schedule.
                    _ = writerFinished.wait(timeout: .now() + 1.0)
                    NSLog("[tx-test] A: writerFinished wait returned, rolling back")
                    throw StorageBackendError.storageFailure(
                        sql: "test", code: -1, detail: "the owner rolls back on purpose"
                    )
                }
            } catch {
                // The deliberate failure above is the expected path.
            }
            NSLog("[tx-test] A: done")
        }
    }

    /// Thread B: writes a row while A's transaction is open.
    ///
    /// Signals TWO semaphores on purpose - one for the transaction owner
    /// (which waits inside its transaction) and one for the main thread
    /// (which waits before reading the rows back). A counting semaphore
    /// satisfies ONE waiter per signal, so sharing one would leave the
    /// second waiter waiting forever.
    private func startWriterThread(
        ownerReady: DispatchSemaphore,
        writerStarted: DispatchSemaphore,
        writerFinished: DispatchSemaphore,
        writerDone: DispatchSemaphore
    ) {
        let backend = self.backend!
        let writerQueue = DispatchQueue(label: "clipmemory.test.tx.writer", qos: .userInteractive)
        writerQueue.async {
            _ = ownerReady.wait(timeout: .now() + 5)
            NSLog("[tx-test] B: ownerReady")
            writerStarted.signal()
            NSLog("[tx-test] B: signaled writerStarted")
            try? backend.upsertItem(
                ClipboardItem(content: "writer-item", type: .text)
            )
            NSLog("[tx-test] B: upsert returned")
            writerFinished.signal()
            writerDone.signal()
            NSLog("[tx-test] B: signaled writerFinished + writerDone")
        }
    }

}
