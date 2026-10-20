import XCTest
import SQLite3
@testable import ClipMemory

/// ID-REVIEW-1024 (PR-B, code-review §八 batch 2): tests for the real
/// SQLiteStorageBackend implementation. Replaces PR-A's placeholder
/// that threw `unsupportedFeature` on every method — these tests
/// would have failed (compile error → red) pre-PR-B; with PR-B they
/// run the real SQLite code path.
///
/// **Test isolation** (per user hard rule #4 "测试禁止空转通过"):
/// each test gets a fresh per-test temp SQLite file via `tempURL()`
/// so schema-mutation state doesn't bleed between cases. The
/// `moveToTrash` foreign-key behavior is tested against a real
/// transaction (PR-A's flush-catch made this riskier; PR-B's
/// begin/commit/rollback is real).
///
/// **No concurrent-write test in PR-B** (deferred): the NSLock-
/// protected writer + 10-thread stress test would have validated
/// the "no SQLite 'database is locked' errors" contract, but the
/// test seam (Mirror reflection on a private `db` field) is fragile
/// and risks false negatives. PR-C (where SQLiteStorageBackend
/// becomes the primary backend) owns the real concurrent-stress test
/// — the test seam will be a public `internal(set) var dbForTesting`
/// property added in PR-C once it's needed.
final class SQLiteStorageBackendTests: XCTestCase {

    // MARK: - Test fixtures

    private var tempURL: URL!
    private var backend: SQLiteStorageBackend!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteBackendTests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("store.sqlite3")
        backend = try SQLiteStorageBackend(databaseURL: tempURL)
    }

    override func tearDown() {
        // ID-CRASH-0022 (2026-10-20): release the backend BEFORE deleting
        // its directory. The other order unlinks the database file while
        // the connection still has it open, which libsqlite3 reports as
        // "database integrity compromised by API violation: vnode
        // unlinked while in use" (plus the same for -wal / -shm) and
        // whose deinit then closes a handle for an already-unlinked
        // file.
        backend = nil
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        tempURL = nil
        super.tearDown()
    }

    // MARK: - Schema migration

    /// On first init the schema must be present. PR-A's placeholder
    /// didn't have a file at all — PR-B must produce a working file
    /// from init alone.
    func testOpenCreatesSchemaAndAllTables() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path),
                      "the SQLite file must exist after init")
        let names = try queryStringColumn(
            stmt: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        // Required tables per docs/design/storage-migration.md §2:
        XCTAssertTrue(names.contains("items"),         "items table must exist")
        XCTAssertTrue(names.contains("tags"),          "tags table must exist")
        XCTAssertTrue(names.contains("item_tags"),     "item_tags junction must exist")
        XCTAssertTrue(names.contains("trash_items"),   "trash_items must exist")
        XCTAssertTrue(names.contains("app_meta"),       "app_meta must exist")
        XCTAssertTrue(names.contains("schema_version"),"schema_version must exist")
    }

    /// Second init must be idempotent (don't re-create tables, don't
    /// crash). Tests that the migrate-on-open path doesn't break
    /// existing data on subsequent launches.
    func testReopenIsIdempotent() throws {
        // Drop + reinit
        backend = nil
        try? FileManager.default.removeItem(at: tempURL)
        backend = try SQLiteStorageBackend(databaseURL: tempURL)
        // Re-drop + reinit again — exercises the "table exists, skip
        // migration" branch.
        backend = nil
        try? FileManager.default.removeItem(at: tempURL)
        backend = try SQLiteStorageBackend(databaseURL: tempURL)

        // After 3 inits we should still have the schema, not 3x
        // tables.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let names = try queryStringColumn(
            stmt: "SELECT name FROM sqlite_master WHERE type='table'"
        )
        XCTAssertEqual(names.count, 6,
                       "exactly 6 tables expected (items, tags, item_tags, trash_items, app_meta, schema_version); idempotent reopen must NOT re-create them")
    }

    // MARK: - Granular CRUD

    func testUpsertItemThenLoadRoundTrip() throws {
        let item = ClipboardItem(
            content: "ciphertext-base64-string",
            type: .text,
            isPinned: true,
            isSensitive: false,
            contentHash: "abc123"
        )
        try backend.upsertItem(item)
        let loaded = try backend.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, item.id)
        XCTAssertEqual(loaded.first?.content, "ciphertext-base64-string")
        XCTAssertEqual(loaded.first?.isPinned, true)
        XCTAssertEqual(loaded.first?.contentHash, "abc123")
    }

    /// upsertItem ON CONFLICT DO UPDATE: calling twice with the same
    /// id replaces (not appends). The saveBlob path's atomic-update
    /// behavior must match this.
    func testUpsertItemSecondCallReplacesByID() throws {
        let id = UUID()
        let v1 = ClipboardItem(id: id, content: "v1", type: .text)
        let v2 = ClipboardItem(id: id, content: "v2", type: .text)
        try backend.upsertItem(v1)
        try backend.upsertItem(v2)
        let loaded = try backend.load()
        XCTAssertEqual(loaded.count, 1, "upsertItem twice with same id must replace, not append")
        XCTAssertEqual(loaded.first?.content, "v2")
    }

    func testUpsertTagThenLoadTagsRoundTrip() throws {
        let tag = Tag(id: UUID(), name: "work", colorHex: "#FF0000", isAutoSuggested: true)
        try backend.upsertTag(tag)
        let loaded = try backend.loadTags()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "work")
        XCTAssertEqual(loaded.first?.colorHex, "#FF0000")
        XCTAssertEqual(loaded.first?.isAutoSuggested, true)
    }

    func testAttachDetachTagOnItem() throws {
        let itemID = UUID()
        let tagID = UUID()
        try backend.upsertItem(ClipboardItem(id: itemID, content: "x", type: .text))
        try backend.upsertTag(Tag(id: tagID, name: "t", colorHex: "#000"))
        try backend.attachTag(itemID: itemID, tagID: tagID)
        // Read back via a raw query (no API for "list all item_tags
        // for an item" — PR-B exposes this if a future test needs it).
        let count = try queryCount(
            stmt: "SELECT COUNT(*) FROM item_tags WHERE item_id = '\(itemID.uuidString)' AND tag_id = '\(tagID.uuidString)'"
        )
        XCTAssertEqual(count, 1, "attachTag must insert a row in item_tags")

        try backend.detachTag(itemID: itemID, tagID: tagID)
        let afterDetach = try queryCount(
            stmt: "SELECT COUNT(*) FROM item_tags WHERE item_id = '\(itemID.uuidString)' AND tag_id = '\(tagID.uuidString)'"
        )
        XCTAssertEqual(afterDetach, 0, "detachTag must remove the item_tags row")
    }

    /// PR-B design critical: attachTag must FAIL when the tag row
    /// doesn't exist (FK with ON CONFLICT DO NOTHING). PR-A's
    /// placeholder threw unsupportedFeature on every call — this test
    /// verifies the real SQLite backend's FK semantics.
    func testAttachTagForeignKeyConstraintRejectsMissingTag() throws {
        let itemID = UUID()
        try backend.upsertItem(ClipboardItem(id: itemID, content: "x", type: .text))
        let nonexistentTagID = UUID()
        XCTAssertThrowsError(
            try backend.attachTag(itemID: itemID, tagID: nonexistentTagID),
            "attachTag must fail when the tag row doesn't exist (FK constraint)"
        )
    }

    /// `attachTag` must be IDEMPOTENT: attaching the same (item, tag)
    /// pair twice leaves exactly ONE row in item_tags.
    ///
    /// Discriminating power: the `ON CONFLICT(item_id, tag_id) DO
    /// NOTHING` clause is what makes it idempotent — remove it and the
    /// second attach raises a PRIMARY KEY violation, so the test goes
    /// red on the thrown error (and on the row count).
    func testAttachTagIsIdempotent() throws {
        let itemID = UUID()
        let tagID = UUID()
        try backend.upsertItem(ClipboardItem(id: itemID, content: "x", type: .text))
        try backend.upsertTag(Tag(id: tagID, name: "t", colorHex: "#000"))

        try backend.attachTag(itemID: itemID, tagID: tagID)
        XCTAssertNoThrow(
            try backend.attachTag(itemID: itemID, tagID: tagID),
            "attaching the same tag twice must be a no-op, not a PK violation"
        )
        XCTAssertEqual(
            try queryCount(
                stmt: "SELECT COUNT(*) FROM item_tags WHERE item_id = '\(itemID.uuidString)' AND tag_id = '\(tagID.uuidString)'"
            ),
            1,
            "exactly one membership row must exist after two attaches"
        )
    }

    /// `load()` must backfill `tagIds` from the item_tags junction
    /// table, and a load → save round trip must not destroy the
    /// membership.
    ///
    /// ID-CRASH-0022 (2026-10-20): the read path decoded items without
    /// their tag ids, so every item came back with an EMPTY `tagIds`
    /// set. `upsertItemInternal` mirrors `item.tagIds` into item_tags
    /// (DELETE the item's rows, then INSERT the current set) — so the
    /// array-level `save(_:)`, which rewrites every item, turned that
    /// empty set into "this item has no tags". The first load → save
    /// round trip therefore wiped every tag association in the store,
    /// irreversibly.
    ///
    /// Discriminating power: without the backfill the loaded item's
    /// `tagIds` is empty AND the round trip leaves zero membership
    /// rows — both assertions turn red.
    func testLoadBackfillsTagIdsAndRoundTripPreservesMembership() throws {
        let itemID = UUID()
        let tagID = UUID()
        try backend.upsertItem(ClipboardItem(id: itemID, content: "x", type: .text))
        try backend.upsertTag(Tag(id: tagID, name: "t", colorHex: "#000"))
        try backend.attachTag(itemID: itemID, tagID: tagID)

        let loaded = try backend.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.tagIds ?? [], [tagID],
                       "load() must backfill the item's tag ids from item_tags")

        // The round trip that used to destroy the association.
        try backend.save(loaded)

        XCTAssertEqual(
            try queryCount(stmt: "SELECT COUNT(*) FROM item_tags WHERE item_id = '\(itemID.uuidString)'"),
            1,
            "a load → save round trip must not wipe the item's tag membership"
        )
        XCTAssertEqual(try backend.load().first?.tagIds ?? [], [tagID],
                       "the membership must survive the round trip")
    }

    func testMoveToTrashRemovesFromItemsAddsToTrash() throws {
        let itemID = UUID()
        let original = ClipboardItem(
            id: itemID,
            content: "ciphertext",
            type: .text,
            contentHash: "h1"
        )
        try backend.upsertItem(original)
        XCTAssertEqual(try backend.load().count, 1)

        try backend.moveToTrash(itemID: itemID, trashSnapshot: original)
        XCTAssertEqual(try backend.load().count, 0, "moveToTrash must remove the item from items")
        XCTAssertEqual(
            try queryCount(stmt: "SELECT COUNT(*) FROM trash_items WHERE item_id = '\(itemID.uuidString)'"),
            1, "moveToTrash must add the item to trash_items"
        )
    }

    func testRestoreFromTrashReturnsItem() throws {
        let itemID = UUID()
        let original = ClipboardItem(id: itemID, content: "cipher", type: .text)
        try backend.upsertItem(original)
        try backend.moveToTrash(itemID: itemID, trashSnapshot: original)
        XCTAssertEqual(try backend.load().count, 0)

        try backend.restoreFromTrash(itemID: itemID)
        let loaded = try backend.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.content, "cipher")
        XCTAssertEqual(
            try queryCount(stmt: "SELECT COUNT(*) FROM trash_items WHERE item_id = '\(itemID.uuidString)'"),
            0, "restoreFromTrash must empty trash_items"
        )
    }

    func testHardDeleteItemRemovesRow() throws {
        let id = UUID()
        try backend.upsertItem(ClipboardItem(id: id, content: "x", type: .text))
        XCTAssertEqual(try backend.load().count, 1)

        try backend.hardDeleteItem(id: id)
        XCTAssertEqual(try backend.load().count, 0)
    }

    func testLoadAllIDsReturnsSet() throws {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        try backend.upsertItem(ClipboardItem(id: id1, content: "a", type: .text))
        try backend.upsertItem(ClipboardItem(id: id2, content: "b", type: .text))
        try backend.upsertItem(ClipboardItem(id: id3, content: "c", type: .text))
        let ids = try backend.loadAllIDs()
        XCTAssertEqual(ids, Set([id1, id2, id3]))
    }

    func testSetMetaMetaRoundTrip() throws {
        let key = "lastPruneDate"
        try backend.setMeta(key: key, value: Data([0xDE, 0xAD]), type: "blob")
        let readBack = try backend.meta(key: key)
        XCTAssertEqual(readBack, Data([0xDE, 0xAD]))
    }

    func testMetaReturnsNilForMissing() throws {
        let missing = try backend.meta(key: "never.set.before")
        XCTAssertNil(missing)
    }

    // MARK: - Transaction integrity

    /// PR-A's flush-catch concern: PR-B uses real `beginTransaction` /
    /// `commitTransaction` / `rollbackTransaction` (real sqlite3_exec
    /// calls, not placeholder throws). This test exercises the round
    /// trip end-to-end.
    func testBeginCommitRoundTrip() throws {
        try backend.beginTransaction()
        try backend.upsertItem(ClipboardItem(id: UUID(), content: "a", type: .text))
        try backend.commitTransaction()
        XCTAssertEqual(try backend.load().count, 1)
    }

    /// `rollbackTransaction` must actually roll back (not a no-op).
    /// Without a real rollback, a failed transaction would leave
    /// partial writes — the very thing docs §1.1 promises WAL
    /// prevents.
    func testRollbackActuallyUndoesWrites() throws {
        try backend.beginTransaction()
        try backend.upsertItem(ClipboardItem(id: UUID(), content: "tx-a", type: .text))
        try backend.upsertItem(ClipboardItem(id: UUID(), content: "tx-b", type: .text))
        try backend.rollbackTransaction()
        // Both inserts must be undone.
        XCTAssertEqual(try backend.load().count, 0,
                       "rollbackTransaction must undo all writes inside the transaction")
    }

    /// `saveBlob` is a programmer error per docs §3.2 — callers must
    /// use `upsertItem`. The placeholder threw; the real backend must
    /// also reject (the rejection is the contract, not an
    /// implementation detail).
    func testSaveBlobRejects() {
        XCTAssertThrowsError(try backend.saveBlob(Data("x".utf8))) { error in
            guard case StorageBackendError.unsupportedFeature = error else {
                return XCTFail("expected StorageBackendError.unsupportedFeature, got \(error)")
            }
        }
    }

    // MARK: - Error surfacing (ID-CRASH-0022)

    /// `init` must surface an open failure. It used to log the failure
    /// and hand back a backend with `db == nil` — the caller could not
    /// tell "no database yet" from "the database is broken", and the
    /// real cause was lost behind a later "connection is nil" error.
    ///
    /// Injection point: the database path is a DIRECTORY, which sqlite3
    /// cannot open (SQLITE_CANTOPEN).
    func testInitThrowsWhenDatabaseCannotBeOpened() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteOpenFail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: dir)) { error in
            guard let backendError = error as? StorageBackendError,
                  case .storageFailure(let sql, let code, _) = backendError else {
                return XCTFail("expected StorageBackendError.storageFailure, got \(error)")
            }
            // ID-CRASH-0022 (2026-10-20): asserting only "it throws" was
            // too weak — swallowing the open failure still produced a
            // throw (from the first PRAGMA, with SQLITE_MISUSE and a
            // "connection is nil" detail), so the mutation survived.
            // Pin the CAUSE: a directory cannot be opened as a database.
            XCTAssertEqual(code, SQLITE_CANTOPEN,
                           "the error must report the real cause (SQLITE_CANTOPEN), got sql=\(sql.prefix(60))")
        }
    }

    /// Transaction ownership belongs to the CALLER. An inner write that
    /// fails must NOT roll the caller's transaction back — the caller
    /// decides. (docs §4.1 step 5, and `granularSave`'s shape.)
    ///
    /// The failing inner call MUST be one that goes through the
    /// backend's own transaction helper (`upsertItem`), otherwise the
    /// test proves nothing about transaction ownership: `attachTag` and
    /// friends only run a single statement under the lock and never
    /// touch the transaction at all.
    ///
    /// Discriminating power: if the inner call wrongly rolled the
    /// caller's transaction back, the outer `commitTransaction()`
    /// below would fail with "cannot commit - no transaction is
    /// active"; if it wrongly opened a nested BEGIN, the inner
    /// `upsertItem` would fail with "cannot start a transaction within
    /// a transaction". Both regressions turn this test red.
    func testInnerFailureDoesNotRollBackCallerTransaction() throws {
        let itemID = UUID()
        try backend.beginTransaction()
        try backend.upsertItem(ClipboardItem(id: itemID, content: "before-failure", type: .text))

        // Fails on the item_tags FK: the tag row does not exist.
        // `upsertItem` goes through the backend's transaction helper,
        // so this is the call whose transaction handling is under test.
        XCTAssertThrowsError(
            try backend.upsertItem(
                ClipboardItem(content: "boom", type: .text, tagIds: [UUID()])
            ),
            "upsertItem must fail when it references a tag row that does not exist"
        )

        // The caller's transaction must still be open and usable.
        try backend.upsertItem(ClipboardItem(content: "after-failure", type: .text))
        try backend.commitTransaction()

        let loaded = try backend.load()
        XCTAssertTrue(loaded.contains { $0.content == "before-failure" },
                      "the caller's pre-failure write must survive")
        XCTAssertTrue(loaded.contains { $0.content == "after-failure" },
                      "the caller's post-failure write must survive")
        XCTAssertFalse(loaded.contains { $0.content == "boom" },
                       "the failed inner write must not be committed")
    }

    /// A failed ROLLBACK must not leave the connection in a state where
    /// later writes silently vanish.
    ///
    /// The failure mode this pins down: `inTransaction` used to do
    /// `try? rollbackTransaction()`. When the ROLLBACK itself fails,
    /// the connection keeps an open transaction — and
    /// `isInsideTransaction` (which reads `sqlite3_get_autocommit`)
    /// then reports "the caller owns a transaction" for every later
    /// call. The next writer takes the savepoint branch, so its write
    /// is absorbed into a transaction nobody ever commits: the write
    /// vanishes.
    ///
    /// The same connection still READS that row back (it sees its own
    /// uncommitted rows), so a single-connection assertion proves
    /// nothing. Only a SECOND connection can tell whether the write was
    /// actually committed — that is why the check below reads through
    /// a fresh backend on the same file.
    ///
    /// Injection point: `rollbackFailureForTest` makes the next
    /// ROLLBACK fail, so the recovery path runs deterministically.
    func testFailedRollbackDoesNotSwallowLaterWrites() throws {
        backend.rollbackFailureForTest = StorageBackendError.storageFailure(
            sql: "ROLLBACK", code: -1, detail: "injected rollback failure"
        )

        // The transaction body fails on the item_tags FK: the tag row
        // does not exist.
        XCTAssertThrowsError(
            try backend.upsertItem(
                ClipboardItem(content: "boom", type: .text, tagIds: [UUID()])
            ),
            "the original transaction-body failure must propagate"
        ) { error in
            // The rollback failure must not REPLACE the original error.
            if case .storageFailure(let sql, _, _) = error as? StorageBackendError,
               sql == "ROLLBACK" {
                XCTFail("the rollback error must not replace the original failure")
            }
        }

        // A later write must be persisted, not absorbed into a
        // dangling transaction.
        try backend.upsertItem(ClipboardItem(content: "after-rollback-failure", type: .text))

        // Read it back through a SECOND connection: only a committed
        // row is visible there.
        var reader: SQLiteStorageBackend? = try SQLiteStorageBackend(databaseURL: tempURL)
        let visible = try reader!.load()
        reader = nil

        XCTAssertTrue(
            visible.contains { $0.content == "after-rollback-failure" },
            "the write after a failed rollback must be committed, not absorbed into a dangling transaction"
        )
        XCTAssertFalse(visible.contains { $0.content == "boom" },
                       "the failed write must not be committed")
    }

    /// A corrupt database file must make `init` throw — NOT come back
    /// as an empty store. The old behaviour (swallow the failure,
    /// hand back a backend with `db == nil`) made "the file is garbage"
    /// indistinguishable from "the user has no clipboard history", and
    /// the next save would then overwrite the real database with an
    /// empty array.
    ///
    /// Injection point: the file exists but holds bytes that are not a
    /// SQLite database.
    func testInitThrowsOnCorruptDatabaseFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteCorrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite3")
        try Data("this is definitely not a sqlite database".utf8).write(to: url)

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: url)) { error in
            guard let backendError = error as? StorageBackendError,
                  case .storageFailure = backendError else {
                return XCTFail("expected StorageBackendError.storageFailure, got \(error)")
            }
        }
    }

    /// The whole backend rests on ONE connection guarded by ONE lock:
    /// `sqlite3_get_autocommit` is read to decide who owns the
    /// transaction, and the savepoint name is fixed. Those are only
    /// safe if the calls really do serialise.
    ///
    /// This test pins that: concurrent upserts must not corrupt the
    /// store or lose rows. It is also the only test in this file that
    /// would trip the TSan race gate — which is the point: the
    /// locking model is an assumption that nothing else verifies.
    func testConcurrentUpsertsDoNotCorruptOrLoseRows() throws {
        let threadCount = 4
        let perThread = 25
        let store: SQLiteStorageBackend = backend!
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "cm.concurrent.upsert", attributes: .concurrent)

        for t in 0..<threadCount {
            queue.async(group: group) {
                for i in 0..<perThread {
                    // Each write uses its own item id, so a lost or
                    // interleaved write shows up as a missing row.
                    let id = UUID()
                    do {
                        try store.upsertItem(
                            ClipboardItem(id: id, content: "t\(t)-\(i)", type: .text)
                        )
                    } catch {
                        XCTFail("concurrent upsert failed: \(error)")
                        return
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success,
                       "concurrent upserts must finish")
        XCTAssertEqual(try backend.load().count, threadCount * perThread,
                       "every concurrent write must survive")
    }

    // MARK: - Helpers

    private func queryStringColumn(stmt sql: String) throws -> [String] {
        let db = try openDb()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt else { return [] }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                out.append(String(cString: cstr))
            }
        }
        return out
    }

    private func queryCount(stmt sql: String) throws -> Int {
        let db = try openDb()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) else {
            return 0
        }
        return Int(String(cString: cstr)) ?? 0
    }

    /// Opens the underlying DB file the backend points at. Used for
    /// raw query assertions (no API exposes "list item_tags for item"
    /// — the test seam itself). Independent handle that closes after
    /// the test, so it doesn't interfere with the backend's NSLock.
    private func openDb() throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(tempURL.path, &handle,
                                   SQLITE_OPEN_READONLY, nil)
        // sqlite3_open_v2 can allocate `handle` even on a non-OK return (it
        // defers some errors to the first statement), so close it on every
        // failure path before throwing — otherwise the handle leaks.
        // sqlite3_close_v2(NULL) is a documented no-op, so no nil check here.
        guard rc == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw StorageBackendError.unsupportedFeature(
                "openDb failed in test: rc=\(rc)"
            )
        }
        return handle
    }
}
