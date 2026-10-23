import SQLite3
import XCTest
@testable import ClipMemory

/// ID-REVIEW-1024 (PR-C, 2026-10-23): the trash DIMENSION of the
/// storage protocol, and the v2 shape of the `trash_items` table.
///
/// docs/design/storage-migration.md §11 open question 5 is the gate:
/// the recycle bin has to be a dimension of the store (its own
/// `loadTrashAll` / `saveTrash` / `purgeTrash`) and the trash rows
/// have to carry the fields a faithful bin needs — `deleted_at`,
/// `tag_ids`, `ocr_text`, `ocr_attempted`, `decryption_failed` — or
/// the bin is a black hole: nothing ever expires, and a restore
/// silently drops the item's tags and its OCR cache.
///
/// Every assertion below is written so that it CAN fail. The v1 code
/// had each of these wrong, and the mutation checks (documented in
/// the change report) turn the implementation back into the old shape
/// to prove the test notices.
final class SQLiteTrashDimensionTests: XCTestCase {

    // MARK: - Fixtures

    private var dir: URL!
    private var dbURL: URL!
    private var backend: SQLiteStorageBackend!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteTrashDimension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("store.sqlite3")
        backend = try SQLiteStorageBackend(databaseURL: dbURL)
    }

    override func tearDown() {
        // Release the backend BEFORE deleting the directory: unlinking
        // the database file while the connection still has it open
        // makes libsqlite3 complain about an unlinked file in use.
        backend = nil
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
        dir = nil
        dbURL = nil
        super.tearDown()
    }

    /// An isolated UserDefaults suite, so a test never touches the
    /// production domain.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "SQLiteTrashDimension-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    // MARK: - Raw file helpers

    /// Runs `sql` on a bare connection to the database file.
    private func execOnFile(_ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, sql, nil, nil, nil),
            SQLITE_OK,
            "the statement must succeed: \(sql.prefix(120))"
        )
    }

    /// `PRAGMA user_version` read straight from the file.
    private func readUserVersion(at url: URL) throws -> Int {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// The raw value of one INTEGER column, read straight from the file.
    ///
    /// `nil` means SQL NULL — which is a DIFFERENT thing from a zero,
    /// and for `expires_at` it is the whole point of the v1 → v2
    /// mapping: the v2 column means "when this entry itself expires",
    /// and the v1 retention deadline must not be carried into it.
    private func rawInteger(_ column: String, in table: String) throws -> Int64? {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT \(column) FROM \(table) LIMIT 1", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(
            sqlite3_step(stmt),
            SQLITE_ROW,
            "the table '\(table)' must hold a row to read '\(column)' from"
        )
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Whether `table` has a column called `column`.
    private func tableHasColumn(_ table: String, _ column: String) throws -> Bool {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: cstr) == column { return true }
        }
        return false
    }

    // MARK: - 1. The round trip is faithful

    /// Every field of a trashed item survives the trip through the
    /// trash dimension.
    ///
    /// This is the test the v1 code could not pass: the v1 decoder
    /// read eight columns and dropped `deletedAt`, `tagIds`,
    /// `ocrText` / `ocrAttempted`, `decryptionFailed` and `expiresAt`,
    /// so a restored item came back stripped.
    func testTrashRoundTripPreservesEveryField() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiresAt = Date(timeIntervalSince1970: 1_700_086_400)
        let createdAt = Date(timeIntervalSince1970: 1_699_000_000)
        let tagIDs: Set<UUID> = [UUID(), UUID()]
        let original = ClipboardItem(
            content: "cipher-text",
            type: .image,
            createdAt: createdAt,
            isPinned: true,
            isSensitive: true,
            expiresAt: expiresAt,
            isEncrypted: true,
            contentHash: "hash-1",
            decryptionFailed: true,
            tagIds: tagIDs,
            deletedAt: deletedAt,
            ocrText: "ocr-text",
            ocrAttempted: true
        )

        try backend.saveTrash([original])

        let loaded = try backend.loadTrashAll()
        XCTAssertEqual(loaded.count, 1, "the trash must hold exactly the item that was written")
        let item = try XCTUnwrap(loaded.first)
        XCTAssertEqual(item.id, original.id)
        XCTAssertEqual(item.content, original.content)
        XCTAssertEqual(item.type, original.type)
        XCTAssertEqual(item.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(item.isPinned, original.isPinned)
        XCTAssertEqual(item.isSensitive, original.isSensitive)
        XCTAssertEqual(item.isEncrypted, original.isEncrypted)
        XCTAssertEqual(item.contentHash, original.contentHash)
        XCTAssertEqual(item.decryptionFailed, original.decryptionFailed)
        XCTAssertEqual(item.tagIds, tagIDs, "the tag associations must survive the round trip")
        XCTAssertEqual(item.ocrText, original.ocrText, "the OCR cache must survive the round trip")
        XCTAssertEqual(item.ocrAttempted, original.ocrAttempted)
        XCTAssertEqual(
            item.deletedAt?.timeIntervalSince1970 ?? 0,
            deletedAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the deletion moment must survive the round trip"
        )
        XCTAssertEqual(
            item.expiresAt?.timeIntervalSince1970 ?? 0,
            expiresAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the item's own expiry must survive the round trip"
        )
    }

    /// The trash row carries the SNAPSHOT's deletion moment, not the
    /// moment of the write.
    ///
    /// The v1 code wrote `trashed_at = Date()` and never read it back,
    /// so every trashed row looked brand new — and
    /// `purgeExpiredTrash`'s `deletedAt != nil` filter never matched
    /// anything. The retention policy was dead.
    func testMoveToTrashStoresTheSnapshotDeletionMoment() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_500_000_000)
        let snapshot = ClipboardItem(
            content: "cipher",
            type: .text,
            deletedAt: deletedAt
        )

        try backend.moveToTrash(itemID: snapshot.id, trashSnapshot: snapshot)

        let trash = try backend.loadTrashAll()
        XCTAssertEqual(trash.count, 1)
        XCTAssertEqual(
            trash.first?.deletedAt?.timeIntervalSince1970 ?? 0,
            deletedAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the trash row must carry the snapshot's deletion moment, not the write moment"
        )
    }

    /// A restore brings the whole snapshot back.
    func testRestoreFromTrashBringsBackTheWholeSnapshot() throws {
        let tagID = UUID()
        let original = ClipboardItem(
            content: "cipher",
            type: .text,
            contentHash: "hash-2",
            tagIds: [tagID],
            deletedAt: Date(timeIntervalSince1970: 1_500_000_000),
            ocrText: "ocr-text",
            ocrAttempted: true
        )
        try backend.upsertTag(Tag(id: tagID, name: "work", colorHex: "#000000"))

        try backend.moveToTrash(itemID: original.id, trashSnapshot: original)
        try backend.restoreFromTrash(itemID: original.id)

        let restored = try XCTUnwrap(try backend.load().first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.content, original.content)
        XCTAssertEqual(restored.contentHash, original.contentHash)
        XCTAssertEqual(restored.tagIds, [tagID], "a restore must not drop the tag associations")
        XCTAssertEqual(restored.ocrText, original.ocrText, "a restore must not drop the OCR cache")
        XCTAssertEqual(restored.ocrAttempted, original.ocrAttempted)
        XCTAssertNil(restored.deletedAt, "a restored item is no longer in the bin")
    }

    // MARK: - 2. The retention criterion

    /// The retention window is judged by the DELETION MOMENT.
    ///
    /// The criterion itself is `TrashStore.expiredTrashEntries()` — it
    /// is called here, not re-implemented: a criterion re-implemented
    /// in the test would keep passing after the production one
    /// changes, which is exactly the kind of guard that cannot fail.
    @MainActor
    func testRetentionCriterionFollowsTheDeletionMoment() throws {
        let store = TrashStore(backend: MemoryStorageBackend(), defaults: makeIsolatedDefaults())
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        let old = ClipboardItem(content: "old", type: .text, deletedAt: tenDaysAgo)
        let fresh = ClipboardItem(content: "fresh", type: .text, deletedAt: Date())
        let undated = ClipboardItem(content: "undated", type: .text)
        store.trashedItems = [old, fresh, undated]

        store.trashRetentionDays = 7
        XCTAssertEqual(
            store.expiredTrashEntries().map(\.id),
            [old.id],
            "an entry deleted 10 days ago is past a 7-day window; the others are not"
        )

        store.trashRetentionDays = 30
        XCTAssertTrue(
            store.expiredTrashEntries().isEmpty,
            "the same entry is NOT past a 30-day window — the window is the user's setting"
        )
    }

    /// The SQLite trash rows carry a `deleted_at` the criterion can be
    /// applied to — the retention policy reads the DELETION MOMENT, not
    /// a stored "expiry deadline".
    ///
    /// The v1 table stored `expires_at = now + 30 days` and no
    /// deletion moment at all, so the window could not be applied to
    /// the rows: the stored deadline contradicted the user's setting
    /// (3 / 7 / 14 / 30 days) and the deletion moment was lost.
    func testTrashRowsCarryTheDeletionMomentTheCriterionNeeds() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_500_000_000)
        let item = ClipboardItem(content: "cipher", type: .text, deletedAt: deletedAt)
        try backend.saveTrash([item])

        let columnNames = try columnNames(of: "trash_items")
        XCTAssertTrue(columnNames.contains("deleted_at"), "the trash must carry the deletion moment")
        XCTAssertFalse(
            columnNames.contains("trashed_at"),
            "the v1 column is replaced by deleted_at — two columns for one fact is one too many"
        )
        XCTAssertTrue(columnNames.contains("tag_ids"))
        XCTAssertTrue(columnNames.contains("ocr_text"))
        XCTAssertTrue(columnNames.contains("ocr_attempted"))
        XCTAssertTrue(columnNames.contains("decryption_failed"))

        let loaded = try backend.loadTrashAll()
        XCTAssertEqual(
            loaded.first?.deletedAt?.timeIntervalSince1970 ?? 0,
            deletedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: - 3. The dimension is isolated from the main items

    /// The trash and the history are two different things.
    ///
    /// The v1 protocol had no trash dimension, so `TrashStore` drove
    /// the bin through the array-level `load()` / `save(_:)` — in
    /// SQLite terms that means "read the MAIN ITEMS as if they were
    /// the bin" and "write the bin by deleting every row in `items`".
    func testTheTrashDimensionNeverTouchesTheMainItems() throws {
        let mainItem = ClipboardItem(content: "in-history", type: .text)
        let trashedItem = ClipboardItem(content: "in-bin", type: .text, deletedAt: Date())
        try backend.upsertItem(mainItem)
        try backend.saveTrash([trashedItem])

        let trash = try backend.loadTrashAll()
        XCTAssertEqual(
            trash.map(\.id),
            [trashedItem.id],
            "loadTrashAll must return the trash rows only"
        )
        XCTAssertFalse(
            trash.contains { $0.id == mainItem.id },
            "an item that is still in the history must never appear in the trash"
        )

        let history = try backend.load()
        XCTAssertEqual(
            history.map(\.id),
            [mainItem.id],
            "writing the trash must not touch the main items table"
        )
    }

    /// The array-level trash backend keeps the bin in its OWN key —
    /// the items backend must not be able to answer "give me the bin"
    /// with the user's history, nor to write the bin.
    ///
    /// ID-REVIEW-1024 review (2026-10-23): the items backend has NO
    /// trash dimension at all. Before the scope existed, every
    /// `FileStorageBackend` had one and it always addressed the bin's
    /// key — so `FileStorageBackend(storageKey: "ClipboardItems")` could
    /// overwrite the user's recycle bin. That is the 2026-10-20 incident
    /// class (the bin replaced by an array it was never asked to hold),
    /// and it is closed here: the write is refused, loudly.
    func testTheFileBackendKeepsTheTrashInItsOwnKey() throws {
        let suiteName = "SQLiteTrashDimension-File-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let itemsBackend = FileStorageBackend(
            storageKey: "items-\(suiteName)",
            scope: .items,
            defaults: defaults
        )
        let history = ClipboardItem(content: "in-history", type: .text)
        try itemsBackend.save([history])

        XCTAssertThrowsError(
            try itemsBackend.loadTrashAll(),
            "the items backend must not answer the trash with the main history"
        ) { error in
            guard case StorageBackendError.unsupportedFeature = error else {
                return XCTFail("expected unsupportedFeature, got \(error)")
            }
        }

        // …and it must not be able to WRITE the bin either. The write is
        // refused loudly (not with `unsupportedFeature`, which the caller
        // falls back from): falling back would save the bin through the
        // history key.
        let binKey = "trash-\(suiteName)"
        let trashBackend = FileStorageBackend(
            storageKey: binKey,
            scope: .trash,
            defaults: defaults
        )
        let trashed = ClipboardItem(content: "in-bin", type: .text, deletedAt: Date())
        try trashBackend.saveTrash([trashed])

        XCTAssertThrowsError(
            try itemsBackend.saveTrash([trashed]),
            "the items backend must not be able to overwrite the user's recycle bin"
        ) { error in
            guard case StorageBackendError.scopeMismatch = error else {
                return XCTFail("expected scopeMismatch, got \(error)")
            }
        }
        XCTAssertEqual(
            try trashBackend.loadTrashAll().map(\.id),
            [trashed.id],
            "the refused write must not have touched the bin"
        )

        XCTAssertEqual(try trashBackend.loadTrashAll().map(\.id), [trashed.id])

        try trashBackend.purgeTrash(deleting: [trashed.id])
        XCTAssertTrue(
            try trashBackend.loadTrashAll().isEmpty,
            "purgeTrash must delete exactly the ids it was given"
        )
    }

    // MARK: - 4. The v1 → v2 upgrade really runs

    /// A REAL v1 database is upgraded to the v2 trash shape.
    ///
    /// This is not a "new database" test: the file is created with the
    /// v1 DDL (the shipped base DDL — the base version is never
    /// edited after shipping, so it still describes the v1 shape) and
    /// stamped with the v1 version, and only then is it opened with
    /// the current build.
    ///
    /// Only editing the DDL without a migration step would leave such
    /// a database behind — the v1 `trash_items` table would keep its
    /// old columns while the file claims to be current. That is the
    /// bug ID-REVIEW-1024 N.4 was about.
    func testAV1DatabaseIsUpgradedToTheV2TrashShape() throws {
        backend = nil
        // The setUp already created a v2 database — this test needs a
        // file that really carries the v1 shape, so the file goes away
        // first (together with its WAL side files).
        removeDatabaseFile()
        try createV1Database()
        let oldID = UUID()
        // The v1 row carries THREE different values that must not be
        // confused with each other by the upgrade:
        // * `trashed_at` — WHEN the entry was trashed (the only deletion
        //   moment the v1 table had) → becomes `deleted_at`.
        // * `created_at` — WHEN the entry was created → stays as it is.
        // * `expires_at` — the bin's retention DEADLINE (now + 30 days),
        //   a product policy → dropped, because the v2 column means the
        //   entry's OWN expiry.
        //
        // The two moments are deliberately DIFFERENT values: with the
        // same value in both columns, a migration that took
        // `deleted_at` from `created_at` would look correct, and the
        // mapping would be unpinned.
        let v1TrashedAt: Int64 = 1_600_000_000
        let v1CreatedAt: Int64 = 1_500_000_000
        try insertV1TrashRow(id: oldID, trashedAt: v1TrashedAt, createdAt: v1CreatedAt)

        // The fixture really does hold the three values above — a
        // fixture that quietly wrote NULLs would make the assertions
        // below vacuous.
        XCTAssertEqual(try rawInteger("trashed_at", in: "trash_items"), v1TrashedAt)
        XCTAssertEqual(try rawInteger("created_at", in: "trash_items"), v1CreatedAt)
        XCTAssertEqual(
            try rawInteger("expires_at", in: "trash_items"),
            v1TrashedAt + 30 * 86_400,
            "the v1 row must carry the bin's retention deadline before the upgrade"
        )

        // Preconditions: the file really is a v1 database.
        XCTAssertEqual(try readUserVersion(at: dbURL), 1)
        XCTAssertTrue(try tableHasColumn("trash_items", "trashed_at"))
        XCTAssertFalse(try tableHasColumn("trash_items", "deleted_at"))

        // Open it with the current build → the v1 → v2 step runs.
        let upgraded = try SQLiteStorageBackend(databaseURL: dbURL)
        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            2,
            "the upgraded database must carry the new schema version"
        )
        XCTAssertTrue(try tableHasColumn("trash_items", "deleted_at"))
        XCTAssertTrue(try tableHasColumn("trash_items", "tag_ids"))
        XCTAssertTrue(try tableHasColumn("trash_items", "ocr_text"))
        XCTAssertTrue(try tableHasColumn("trash_items", "ocr_attempted"))
        XCTAssertTrue(try tableHasColumn("trash_items", "decryption_failed"))
        XCTAssertFalse(
            try tableHasColumn("trash_items", "trashed_at"),
            "deleted_at replaces trashed_at"
        )

        // The old row survived, and it kept the only deletion moment
        // the v1 table had.
        let trash = try upgraded.loadTrashAll()
        XCTAssertEqual(trash.count, 1, "the old trash row must survive the upgrade")
        XCTAssertEqual(trash.first?.id, oldID)
        XCTAssertEqual(trash.first?.content, "v1-content")
        XCTAssertEqual(
            trash.first?.deletedAt?.timeIntervalSince1970 ?? 0,
            Double(v1TrashedAt),
            accuracy: 0.001,
            "the v1 trashed_at is the only deletion moment the old row had"
        )

        // THE MAPPING, pinned on the raw columns and on the decoded
        // item. Two claims are made about the v1 → v2 step, and each of
        // them is checked on the bytes the step actually wrote.
        try assertV2TrashMapping(
            upgraded: upgraded,
            oldID: oldID,
            v1TrashedAt: v1TrashedAt,
            v1CreatedAt: v1CreatedAt
        )
    }

    /// Asserts the two claims the v1 → v2 step makes about the trash
    /// row, on the raw columns AND on the decoded item.
    ///
    /// * `deleted_at` comes from the v1 `trashed_at` — NOT from
    ///   `created_at`. The two columns carry different values in the
    ///   fixture, so swapping them cannot pass.
    /// * `expires_at` is NULL — the v1 retention deadline is NOT
    ///   carried over. The v2 column means the entry's own expiry, and
    ///   carrying the deadline over would make a restored entry look
    ///   expired at a time the user never asked for.
    private func assertV2TrashMapping(
        upgraded: SQLiteStorageBackend,
        oldID: UUID,
        v1TrashedAt: Int64,
        v1CreatedAt: Int64
    ) throws {
        XCTAssertEqual(
            try rawInteger("deleted_at", in: "trash_items"),
            v1TrashedAt,
            "deleted_at must be the v1 trashed_at — the creation moment is a different fact"
        )
        XCTAssertEqual(
            try rawInteger("created_at", in: "trash_items"),
            v1CreatedAt,
            "created_at must survive the upgrade as the creation moment"
        )
        XCTAssertNil(
            try rawInteger("expires_at", in: "trash_items"),
            "the v1 retention deadline must not be carried into expires_at — "
            + "the v2 column means the entry's own expiry, and the retention "
            + "policy is computed in TrashStore"
        )

        // And the same three facts as the caller sees them.
        let trash = try upgraded.loadTrashAll()
        XCTAssertEqual(trash.first?.id, oldID)
        XCTAssertEqual(
            trash.first?.createdAt.timeIntervalSince1970 ?? 0,
            Double(v1CreatedAt),
            accuracy: 0.001,
            "the decoded item must report the creation moment, not the deletion moment"
        )
        XCTAssertNil(
            trash.first?.expiresAt,
            "a migrated entry must not inherit an expiry — it has none of its own"
        )
    }

    /// Builds a v1 database: the shipped base DDL (the v1 shape) plus
    /// the v1 version stamp.
    private func createV1Database() throws {
        for statement in SQLiteSchema.statements {
            try execOnFile(statement)
        }
        try execOnFile("PRAGMA user_version = 1")
    }

    /// Removes the database file and its WAL side files.
    private func removeDatabaseFile() {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: dbURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Inserts a row in the v1 `trash_items` shape.
    ///
    /// `trashedAt` and `createdAt` are separate parameters on purpose:
    /// the v1 table had BOTH moments, and a fixture that gave them the
    /// same value would let a migration that swapped the two columns
    /// pass unnoticed.
    private func insertV1TrashRow(id: UUID, trashedAt: Int64, createdAt: Int64) throws {
        let sql = """
            INSERT INTO trash_items (item_id, trashed_at, expires_at, content_blob,
                                      content_hash, is_encrypted, type, is_pinned,
                                      is_sensitive, created_at)
            VALUES ('\(id.uuidString)', \(trashedAt), \(trashedAt + 30 * 86_400), 'v1-content',
                    'v1-hash', 1, 'text', 0, 0, \(createdAt))
            """
        try execOnFile(sql)
    }

    // MARK: - 5. The purge deletes what it is told to

    /// `purgeTrash` deletes exactly the ids it is given.
    ///
    /// The retention window and the "ask the user before a large
    /// purge" gate (ID-CRASH-0035) live in `TrashStore` — a backend
    /// that decided what is expired itself would give the policy two
    /// sources of truth.
    func testPurgeTrashDeletesOnlyTheGivenIds() throws {
        let keep = ClipboardItem(content: "keep", type: .text, deletedAt: Date())
        let drop = ClipboardItem(content: "drop", type: .text, deletedAt: Date())
        let alsoKeep = ClipboardItem(content: "also-keep", type: .text, deletedAt: Date())
        try backend.saveTrash([keep, drop, alsoKeep])

        try backend.purgeTrash(deleting: [drop.id])

        let trash = try backend.loadTrashAll()
        XCTAssertEqual(
            Set(trash.map(\.id)),
            [keep.id, alsoKeep.id],
            "only the named id may be deleted; the rest of the bin must stay"
        )
    }

    /// An empty purge is a no-op, not an error.
    func testPurgingNothingDeletesNothing() throws {
        let item = ClipboardItem(content: "keep", type: .text, deletedAt: Date())
        try backend.saveTrash([item])

        try backend.purgeTrash(deleting: [])

        XCTAssertEqual(try backend.loadTrashAll().map(\.id), [item.id])
    }

    // MARK: - Helpers

    /// The column names of a table, read straight from the file.
    private func columnNames(of table: String) throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 1) else { continue }
            names.append(String(cString: cstr))
        }
        return names
    }
}
