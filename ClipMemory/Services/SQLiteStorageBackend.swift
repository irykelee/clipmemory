//
//  SQLiteStorageBackend.swift
//  ClipMemory
//
//  ID-REVIEW-1024 PR-B (code-review-2026-10-01 §八 batch 2):
//  real implementation of the granular StorageBackend protocol
//  methods that PR-A (commit fbc619f) declared as `unsupportedFeature`
//  placeholders. This is the "real event" of the storage migration
//  batch — PR-C/D/E all hang off this commit.
//
//  Design references: docs/design/storage-migration.md §2 (schema),
//  §3 (protocol), §3.2 (per-backend saveBlob), §5 (concurrency model
//  — single connection + NSLock), §11 (open questions resolved).
//  NB: §5 of that doc still says "NSLock"; the implementation deviates
//  deliberately — see "Why recursive" below.
//
//  Concurrency model: ONE sqlite3* connection per backend instance,
//  protected by an NSRecursiveLock (serializing all calls). SQLite's
//  per-connection mutex is implicit in libsqlite3; the Swift lock is
//  defense in depth against accidental Swift-level multi-threading and
//  makes the locking model consistent with `MemoryStorageBackend` (same
//  pattern, see `StorageBackend.swift:183`). Per §5.4, exclusive
//  locking is over-cautious for reads (sqlite3 supports concurrent
//  reads on one connection); PR-C may switch to pthread_rwlock_t if
//  contention shows up. For now: exclusive on every method.
//
//  Why recursive (ID-CRASH-0022, 2026-10-15): the transaction trio
//  (beginTransaction / commitTransaction / rollbackTransaction) is a
//  CLASS-EXTERNAL entry point, not an internal helper —
//  `ClipboardStore+Persistence.granularSave` (via a
//  `backend as? SQLiteStorageBackend` downcast) and `StoreMigration`
//  both call it, and neither holds this lock. At the same time, five
//  methods here (save / saveTags / upsertItem / moveToTrash /
//  restoreFromTrash) already hold the lock when they call the trio.
//  With a plain NSLock that is a guaranteed self-deadlock — every one
//  of those five hangs, which took the whole test suite down (the
//  first such test blocked and the remaining 1083 never ran).
//
//  Recursion here is same-thread only and therefore cannot weaken
//  cross-thread serialization: granularSave and StoreMigration each
//  take the lock themselves, so two threads still cannot interleave on
//  the shared connection.
//
//  Storage location: `~/Library/Application Support/ClipMemory/
//  store.sqlite3`. The directory is created lazily (sqlite3_open with
//  SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX).
//
//  Ciphertext note: ClipboardItem.content is `String?` (base64-
//  encoded AES-GCM ciphertext per the schema fix in commit
//  `7793038 docs(design): ... content_blob BLOB→TEXT`). SQLiteStorageBackend
//  treats `content` as opaque — write the String directly, read it back
//  as a String. The CryptoService layer above the storage layer is
//  responsible for encrypting content before write; this backend
//  never sees plaintext.
//
//  Lifecycle: init opens + migrates schema (idempotent — the
//  migration is skipped when the `items` table already exists).
//  deinit closes the connection.
//  Callers (ClipboardStore) construct exactly one instance per
//  process and inject it into the backend protocol.
//
//  Transaction model: granular writes always run inside an
//  implicit transaction at the SQLite level (PRAGMA journal_mode = WAL
//  auto-begins transactions per write). Explicit BEGIN/COMMIT is used
//  by `ClipboardStore.saveItems` (the granular path) when multiple
//  upserts must be atomic — see `beginTransaction` / `commitTransaction`
//  / `rollbackTransaction` below. The default-isolation is the
//  SQLite-level WAL; we don't need explicit isolation in single-statement
//  writes.

import Foundation
import os.log
import SQLite3

/// ID-REVIEW-1024 (PR-B): real SQLite-backed implementation of the
/// granular `StorageBackend` protocol. Replaces the PR-A placeholder
/// (`StorageBackend.swift:503`) whose every method threw
/// `unsupportedFeature`.
///
/// Connection ownership: this class owns the `sqlite3` connection for
/// its lifetime. Init opens it; `deinit` closes it. The
/// recursive-lock-protected writes serialize Swift-level concurrent
/// callers (libsqlite3 itself is thread-safe per connection under
/// `SQLITE_THREADSAFE=1`, the macOS default). See the header comment
/// for why the lock is recursive.
final class SQLiteStorageBackend: StorageBackend {
    /// ID-CRASH-0022 (2026-10-20): `init` throws. Opening the database
    /// and running the schema migration can fail for reasons the caller
    /// must see (disk full, permission denied, a corrupt file). Both
    /// used to be logged and swallowed — the backend came back "alive"
    /// with `db == nil`, hiding the cause behind a later "connection is
    /// nil" error.
    init(databaseURL: URL, defaults: UserDefaults = .standard) throws {
        self.databaseURL = databaseURL
        self.defaults = defaults
        try openAndMigrate()
    }

    deinit {
        // Close the connection. Per SQLite docs, close on the same
        // thread that opened it (init runs synchronously here, so deinit
        // runs on the same thread in practice).
        //
        // We don't reset `db = nil` here — Swift deinit forbids
        // property reassignment of stored properties; the handle is
        // invalid after sqlite3_close, and the property won't be read
        // again (the class is being destroyed).
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - State

    private let databaseURL: URL
    private let defaults: UserDefaults
    // ID-CRASH-0022 (2026-10-15): recursive — the transaction trio is a
    // class-external entry point (granularSave, StoreMigration call it
    // without holding this lock) while the five bulk methods above call
    // it from inside `withLock`. NSLock self-deadlocks on that shape.
    private let lock = NSRecursiveLock()  // explicit, locked; not optional
    private var db: OpaquePointer?  // sqlite3 *
    /// ID-CRASH-0022 (2026-10-20): test seam — see `rollbackTransaction`.
    /// Never set in production code.
    var rollbackFailureForTest: StorageBackendError?
    private static let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "SQLiteStorageBackend"
    )

    // MARK: - Connection setup

    /// Open the database, set PRAGMAs, and run the schema migration
    /// (idempotent). Called from `init`; safe to call multiple times
    /// in tests (the migration uses `CREATE TABLE IF NOT EXISTS`).
    private func openAndMigrate() throws {
        try openConnection()
        try migrateSchema()
    }

    /// Open the sqlite3 handle and apply the connection PRAGMAs.
    ///
    /// Split out of `openAndMigrate` so `resetConnection` can
    /// re-establish a known state without re-running the schema
    /// migration (the schema is idempotent, but a reset must not be
    /// the thing that decides whether the tables exist).
    private func openConnection() throws {
        do {
            // Ensure the parent directory exists (~/Library/Application
            // Support/ClipMemory/). macOS sandbox may not have created
            // it yet on first launch.
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create database parent directory: \(error.localizedDescription)")
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        if rc != SQLITE_OK {
            // sqlite3_open_v2 can allocate a handle even on a non-OK
            // return (it defers some errors to the first statement), so
            // close it before throwing — otherwise the handle leaks.
            // sqlite3_close_v2(NULL) is a documented no-op.
            let detail = handle.flatMap { String(cString: sqlite3_errmsg($0)) }
                ?? "(no error message)"
            sqlite3_close_v2(handle)
            Self.logger.error("sqlite3_open failed: rc=\(rc)")
            throw StorageBackendError.storageFailure(
                sql: "sqlite3_open_v2(\(databaseURL.path))",
                code: rc,
                detail: detail
            )
        }
        db = handle

        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA temp_store = MEMORY")
        // ID-CRASH-0022 (2026-10-20): SQLite's default busy timeout is
        // 0 — a second connection hitting a locked database gets
        // SQLITE_BUSY immediately instead of waiting. This backend is
        // single-connection today, but the migration opens the file
        // while the app may already hold it, and a future second
        // instance (a helper tool, a second process) would fail hard
        // instead of retrying.
        try exec("PRAGMA busy_timeout = 5000")
    }

    /// Recover from a failed ROLLBACK by resetting the connection.
    ///
    /// ID-CRASH-0022 (2026-10-20): after a failed ROLLBACK the
    /// transaction state is indeterminate, and `isInsideTransaction`
    /// (which reads `sqlite3_get_autocommit`) would then mis-detect
    /// ownership on every later call — the next writer would believe
    /// the CALLER owns a transaction and silently absorb its writes
    /// into a dangling transaction that nobody ever commits. That is
    /// silent data loss, and it is exactly what the swallowed
    /// `try? rollbackTransaction()` used to cause.
    ///
    /// Closing the handle rolls the dangling transaction back (SQLite
    /// rolls back on close) and reopening gives a connection with a
    /// known, empty transaction state. Already-committed data
    /// survives: WAL keeps it on disk.
    ///
    /// Throws only when the connection could not be reopened: the
    /// rollback itself has already been achieved by the close, but the
    /// backend is then dead and the caller must know.
    private func resetConnection(afterRollbackFailure cause: Error) throws {
        Self.logger.error(
            "ROLLBACK failed: \(cause.localizedDescription) — resetting the connection so later writes are not absorbed into a dangling transaction"
        )
        if let handle = db {
            sqlite3_close_v2(handle)
            db = nil
        }
        try openConnection()
    }

    /// Run the schema migration. Uses `sqlite3_master` to check if the
    /// tables already exist (idempotent across launches). Per docs
    /// §4.3.1, schema migration runs once per install — the
    /// `schema_version` row in the meta table marks completion.
    private func migrateSchema() throws {
        // If the items table exists, the migration has already run.
        if try tableExists("items") {
            return
        }

        // ID-CRASH-0022 (2026-10-20): the DDL lives in SQLiteSchema.swift
        // — it is ~100 lines of text and pushed this file to within four
        // lines of the SwiftLint `file_length` error ceiling.
        for stmt in SQLiteSchema.statements {
            try exec(stmt)
        }
    }

    // MARK: - Helpers

    /// Whether a table exists in the current schema.
    ///
    /// ID-CRASH-0022 (2026-10-20): a failed prepare used to answer
    /// "no" — indistinguishable from "the table does not exist",
    /// which made `migrateSchema` believe a fresh database was needed
    /// and then fail on the CREATE statements with a much less obvious
    /// error. It now throws, so the cause is the cause.
    private func tableExists(_ name: String) throws -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, Self.sqlLiteTransientDestructor)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return false }
        guard rc == SQLITE_ROW else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "(no error message)"
            Self.logger.error("sqlite3_step failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
        }
        return true
    }

    /// ID-CRASH-0022 (2026-10-20): this used to be non-throwing — it logged
    /// the failure and returned normally, which made every `throws` in this
    /// backend a fiction (a FK violation was ignored; a failed ROLLBACK left
    /// writes committed). It now propagates as `StorageBackendError`.
    private func exec(_ sql: String) throws {
        guard let db = db else {
            throw StorageBackendError.storageFailure(
                sql: sql, code: SQLITE_MISUSE, detail: "connection is nil"
            )
        }
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "(no error message)"
            Self.logger.error("sqlite3_exec failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
            sqlite3_free(err)
            throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
        }
    }

    /// ID-CRASH-0022 (2026-10-15): now throwing — see the note on the
    /// non-parameterized overload above. The `sqlite3_step` result is
    /// captured so a constraint violation (e.g. `attachTag` referencing a
    /// tag row that does not exist) reaches the caller instead of being
    /// logged and swallowed.
    private func exec(_ sql: String, _ params: [(Int32, Any)]) throws {
        guard let db = db else {
            throw StorageBackendError.storageFailure(
                sql: sql, code: SQLITE_MISUSE, detail: "connection is nil"
            )
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let prepareRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Self.logger.error("sqlite3_prepare_v2 failed for sql: \(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: prepareRC, detail: msg)
        }
        for (index, value) in params {
            bind(stmt: stmt, index: index, value: value)
        }
        let stepRC = sqlite3_step(stmt)
        if stepRC != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            Self.logger.error("sqlite3_step failed for sql: \(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: stepRC, detail: msg)
        }
    }

    /// Prepare a SELECT, throwing when it cannot be prepared.
    ///
    /// ID-CRASH-0022 (2026-10-20): the read paths used to answer a
    /// failed prepare with "no rows" — which turns a corrupt file or
    /// schema mismatch into "the user has no clipboard history", and
    /// the next save then overwrites the database with an empty array.
    /// A failed read must surface as an error, not as empty data.
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db = db else {
            throw StorageBackendError.storageFailure(
                sql: sql, code: SQLITE_MISUSE, detail: "connection is nil"
            )
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Self.logger.error("sqlite3_prepare_v2 failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
        }
        return stmt
    }

    /// Walk every row of a prepared SELECT.
    ///
    /// ID-CRASH-0022 (2026-10-20): the old `while sqlite3_step(stmt)
    /// == SQLITE_ROW` loops ended on ANY non-ROW result, including a
    /// real error — the caller got a truncated result set and no error,
    /// i.e. a partially read history that looked complete. A step
    /// error now propagates.
    private func forEachRow(
        _ stmt: OpaquePointer,
        sql: String,
        _ body: (OpaquePointer) throws -> Void
    ) throws {
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try body(stmt)
                continue
            }
            if rc == SQLITE_DONE { return }
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "(no error message)"
            Self.logger.error("sqlite3_step failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
        }
    }

    /// Bind a value to a prepared statement. Covers String, Int, Int64,
    /// Data, Bool and NSNull (explicit NULL); anything else is bound as
    /// NULL with a warning.
    ///
    /// ID-CRASH-0022 (2026-10-20): `NSNull` used to fall into the
    /// "unsupported value type" branch, which logged a MISLEADING
    /// warning ("unsupported value type") for a perfectly deliberate
    /// NULL — and `upsertItemInternal` binds three NSNulls per item
    /// (`expiresAt` / `contentHash` / `ocrText`), so every write
    /// produced three bogus warnings. NSNull is now recognised as the
    /// explicit-null marker it is.
    private func bind(stmt: OpaquePointer, index: Int32, value: Any) {
        let sqlLiteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let s = value as? String {
            sqlite3_bind_text(stmt, index, s, -1, sqlLiteTransientDestructor)
        } else if let i = value as? Int {
            sqlite3_bind_int64(stmt, index, Int64(i))
        } else if let i = value as? Int64 {
            sqlite3_bind_int64(stmt, index, i)
        } else if let d = value as? Data {
            d.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(d.count), sqlLiteTransientDestructor)
            }
        } else if let b = value as? Bool {
            sqlite3_bind_int(stmt, index, b ? 1 : 0)
        } else if value is NSNull {
            sqlite3_bind_null(stmt, index)
        } else {
            Self.logger.warning("bind: unsupported value type for index \(index) — binding NULL")
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Run `body` inside an exclusive lock on the connection.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// True when the connection currently sits inside an explicit
    /// transaction — i.e. the caller owns it. `sqlite3_get_autocommit`
    /// returns non-zero when the connection is in autocommit mode
    /// (no open transaction).
    private var isInsideTransaction: Bool {
        guard let db = db else { return false }
        return sqlite3_get_autocommit(db) == 0
    }

    /// Run `body` inside an explicit transaction.
    ///
    /// ID-CRASH-0022 (2026-10-20): transaction ownership follows the
    /// CALLER. `granularSave` (docs §3.2.1) and `StoreMigration.runOnce`
    /// (docs §4.1 step 5) each wrap a batch in BEGIN…COMMIT, and a
    /// nested BEGIN is a hard SQLite error. So when the caller already
    /// owns a transaction we neither open a second one nor commit/roll
    /// back the caller's — the error propagates and the owner rolls
    /// back.
    ///
    /// But "the caller owns it" is not enough on its own: the inner
    /// body is MULTIPLE statements (`upsertItemInternal` = INSERT items
    /// + DELETE item_tags + INSERT item_tags). If the last one fails,
    /// the inner call has already written the items row — and leaving
    /// that behind in the caller's transaction means the caller's
    /// COMMIT persists a half-written item. So the inner call isolates
    /// itself with a SAVEPOINT: on failure it rolls back to its own
    /// savepoint (undoing exactly its own writes, leaving the caller's
    /// other statements intact) and then rethrows.
    ///
    /// When nobody owns a transaction, this method owns it: the body
    /// then runs in BEGIN/COMMIT, which keeps multi-statement writes
    /// atomic (e.g. `upsertItemInternal` = INSERT items + DELETE
    /// item_tags + INSERT item_tags — in autocommit a mid-way failure
    /// would half-write).
    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        let ownsTransaction = !isInsideTransaction
        if ownsTransaction {
            try beginTransaction()
            do {
                let result = try body()
                try commitTransaction()
                return result
            } catch {
                // ID-CRASH-0022 (2026-10-20): a failed ROLLBACK must
                // not be swallowed. Two things go wrong if it is:
                //   1. the connection keeps an open transaction, so
                //      `isInsideTransaction` mis-detects ownership on
                //      every later call and the next writer silently
                //      absorbs its writes into a transaction nobody
                //      commits (silent data loss);
                //   2. nothing in the log explains why the next
                //      write vanished.
                // `rollbackTransaction` recovers by resetting the
                // connection when the ROLLBACK itself fails, so the
                // transaction state is known again either way. It
                // throws only when the connection could not be
                // recovered at all — and even then the ORIGINAL error
                // is the one the caller needs.
                do {
                    try rollbackTransaction()
                } catch {
                    Self.logger.error(
                        "connection could not be recovered after a failed rollback: \(error.localizedDescription)"
                    )
                }
                throw error
            }
        }
        // Caller owns the transaction: isolate our own writes with a
        // savepoint so a mid-body failure undoes exactly what this
        // call wrote — and nothing else. SQLite nests savepoints, and
        // ROLLBACK TO / RELEASE both act on the most recent savepoint
        // of that name, so a fixed name is safe here.
        try exec("SAVEPOINT \(Self.savepointName)")
        do {
            let result = try body()
            try exec("RELEASE SAVEPOINT \(Self.savepointName)")
            return result
        } catch {
            // The ROLLBACK TO is the operation that guarantees the
            // caller's transaction is NOT left holding a half-written
            // row. If it fails, the safety property this savepoint
            // exists for is broken — and swallowing that failure would
            // let the caller's COMMIT persist exactly the partial write
            // we are undoing. So it is logged and escalated, never
            // silently dropped.
            do {
                try exec("ROLLBACK TO SAVEPOINT \(Self.savepointName)")
                try exec("RELEASE SAVEPOINT \(Self.savepointName)")
            } catch {
                Self.logger.error(
                    "ROLLBACK TO SAVEPOINT \(Self.savepointName) failed: \(error.localizedDescription)"
                )
                throw StorageBackendError.storageFailure(
                    sql: "ROLLBACK TO SAVEPOINT \(Self.savepointName)",
                    code: -1,
                    detail: """
                    inner-write rollback failed; the caller-owned transaction may \
                    contain partial writes (\(error.localizedDescription))
                    """
                )
            }
            throw error
        }
    }

    /// Fixed savepoint name used to isolate an inner call's writes
    /// when the caller owns the transaction. See `inTransaction`.
    private static let savepointName = "clipmemory_sp"

    // MARK: - Array-level methods (protocol conformance)

    /// Used by `ClipboardStore.saveItems` fallback when granular
    /// methods throw `unsupportedFeature` (FileStorageBackend /
    /// MemoryStorageBackend). PR-A's behavior preserved: read all,
    /// replace all. This is the SAME array-level behavior as
    /// `FileStorageBackend.save(_:)` and `MemoryStorageBackend.save(_:)` —
    /// PR-B's implementation just happens to use SQLite's table instead
    /// of UserDefaults or RAM.
    func load() throws -> [ClipboardItem] {
        return try withLock {
            try loadItemsFromDB()
        }
    }

    func save(_ items: [ClipboardItem]) throws {
        try withLock {
            // "Save the whole array" in SQLite terms means "replace
            // every row in items with the new array's rows". This is
            // the same semantic as FileStorageBackend.save (replaces the
            // blob) and MemoryStorageBackend.save (replaces the array).
            // Per docs §3.2.1, callers passing a whole array will
            // become the granular path (item-by-item upsert in a
            // transaction) when `SQLiteStorageBackend` becomes the
            // primary backend; this array-level path remains for the
            // fallback / legacy callers.
            // ID-CRASH-0022 (2026-10-20): goes through `inTransaction`
            // rather than the raw trio, so this method does not open a
            // nested BEGIN when the caller already owns a transaction,
            // and a mid-way failure cannot leave a half-written array
            // behind in the caller's transaction.
            try inTransaction {
                try exec("DELETE FROM item_tags")
                try exec("DELETE FROM items")
                for item in items {
                    try upsertItemInternal(item)
                }
            }
        }
    }

    func loadTags() throws -> [Tag] {
        return try withLock {
            try loadTagsFromDB()
        }
    }

    func saveTags(_ tags: [Tag]) throws {
        try withLock {
            // ID-CRASH-0022 (2026-10-20): same as `save(_:)` above.
            try inTransaction {
                try exec("DELETE FROM tags")
                for tag in tags {
                    try upsertTagInternal(tag)
                }
            }
        }
    }

    /// Per docs §3.2 — `saveBlob` is a programmer error on SQLite
    /// (callers should use `upsertItem`). Throwing `unsupportedFeature`
    /// surfaces the misuse immediately rather than silently round-
    /// tripping through JSON.
    func saveBlob(_ data: Data) throws {
        throw StorageBackendError.unsupportedFeature(
            "SQLiteStorageBackend: saveBlob not supported; use upsertItem instead"
        )
    }

    // MARK: - Granular methods (real PR-B implementations)

    func upsertItem(_ item: ClipboardItem) throws {
        try withLock {
            try inTransaction {
                try upsertItemInternal(item)
            }
        }
    }

    func hardDeleteItem(id: UUID) throws {
        try withLock {
            let sql = "DELETE FROM items WHERE id = ?"
            try exec(sql, [(1, id.uuidString)])
        }
    }

    func upsertTag(_ tag: Tag) throws {
        try withLock {
            try upsertTagInternal(tag)
        }
    }

    /// Insert a placeholder tag row for every id in `tagIDs` that has
    /// no row yet. Existing tags are left untouched (no name/color
    /// overwrite).
    ///
    /// ID-CRASH-0022 (2026-10-20): used by the v1 → v2 migration. The
    /// legacy layout stored tag MEMBERSHIP in `ClipboardItem.tagIds`
    /// and the tag CATALOG in a separate blob, so an item can
    /// reference a tag id the catalog no longer carries. item_tags has
    /// a FOREIGN KEY on tags(id), so such a reference would fail the
    /// whole migration batch with SQLITE_CONSTRAINT_FOREIGNKEY and the
    /// migration would never complete. The placeholder keeps the
    /// membership; the cost is one tag row with an empty name/color.
    /// Deliberately NOT on the normal write path — a regular write
    /// referencing an unknown tag must fail loudly, not invent a tag.
    func ensureTagPlaceholders(_ tagIDs: Set<UUID>) throws {
        guard !tagIDs.isEmpty else { return }
        try withLock {
            let now = Int(Date().timeIntervalSince1970)
            for tagID in tagIDs {
                try exec(
                    """
                    INSERT INTO tags (id, name, color_hex, is_auto, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    [
                        (1, tagID.uuidString),
                        (2, ""),
                        (3, ""),
                        (4, Int(0)),
                        (5, now)
                    ]
                )
            }
        }
    }

    func attachTag(itemID: UUID, tagID: UUID) throws {
        try withLock {
            // Per docs §2, item_tags has FK to tags(id) with ON DELETE
            // CASCADE. The caller (ClipboardStore.saveItems' granular
            // path) is responsible for upserting the tag first; this
            // method trusts that the tag row exists. The FK + PRAGMA
            // foreign_keys=ON guarantees the integrity check at write
            // time — if the tag row is missing, this INSERT throws
            // SQLITE_CONSTRAINT_FOREIGNKEY, which propagates through the
            // caller's catch and (per the narrow-catch fix in 051be13)
            // surfaces as a real error rather than masking it as
            // "unsupportedFeature".
            //
            // ID-CRASH-0022 (2026-10-20): ON CONFLICT DO NOTHING, per
            // docs §3.2. Required, not cosmetic: `upsertItemInternal`
            // already mirrors `item.tagIds` into item_tags, so a caller
            // that upserts an item and then attaches its tags (the
            // `granularSave` shape) inserts the same pair twice — and
            // without DO NOTHING the second insert dies with a PRIMARY
            // KEY violation the caller sees as a spurious save failure.
            // An FK violation is still NOT swallowed: DO NOTHING only
            // covers the primary-key uniqueness conflict.
            let sql = """
                INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)
                ON CONFLICT(item_id, tag_id) DO NOTHING
                """
            try exec(sql, [(1, itemID.uuidString), (2, tagID.uuidString)])
        }
    }

    func detachTag(itemID: UUID, tagID: UUID) throws {
        try withLock {
            let sql = "DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?"
            try exec(sql, [(1, itemID.uuidString), (2, tagID.uuidString)])
        }
    }

    func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws {
        try withLock {
            try inTransaction {
                // Order matters and is fixed by docs §3.3: the trash
                // snapshot is written first, then the source row is
                // removed. Both happen in ONE transaction so a failure
                // leaves neither half applied.
                try upsertTrashItemInternal(itemID: itemID, snapshot: trashSnapshot)
                try exec("DELETE FROM items WHERE id = ?", [(1, itemID.uuidString)])
            }
        }
    }

    func restoreFromTrash(itemID: UUID) throws {
        try withLock {
            try inTransaction {
                guard let snapshot = try loadTrashItem(itemID: itemID) else {
                    // ID-CRASH-0022 (2026-10-20): "the row is absent" and
                    // "the row is present but corrupt" are different
                    // situations with different operator responses (retry
                    // vs. restore-from-quarantine), and one message for
                    // both sent the reader to the wrong cause.
                    if try trashRowExists(itemID: itemID) {
                        throw StorageBackendError.storageFailure(
                            sql: "SELECT ... FROM trash_items WHERE item_id = ?",
                            code: -1,
                            detail: """
                            the trash row for item \(itemID.uuidString) exists but could not be \
                            decoded; the store is corrupt, not missing — use the quarantine / \
                            restore path, a retry will not help
                            """
                        )
                    }
                    throw StorageBackendError.unsupportedFeature(
                        "restoreFromTrash: no trash row for item \(itemID.uuidString)"
                    )
                }
                try upsertItemInternal(snapshot)
                try exec("DELETE FROM trash_items WHERE item_id = ?", [(1, itemID.uuidString)])
            }
        }
    }

    func loadAllIDs() throws -> Set<UUID> {
        return try withLock {
            let sql = "SELECT id FROM items"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            var ids: Set<UUID> = []
            try forEachRow(stmt, sql: sql) { row in
                guard let cstr = sqlite3_column_text(row, 0) else {
                    Self.logger.error("skipping items row with a NULL id in loadAllIDs")
                    return
                }
                guard let id = UUID(uuidString: String(cString: cstr)) else {
                    // ID-CRASH-0022 (2026-10-20): a row we cannot decode
                    // is skipped — but not silently. `loadAllIDs` feeds
                    // the delete-propagation diff, so a dropped id is
                    // an id the caller believes is absent.
                    Self.logger.error("skipping items row with a non-UUID id in loadAllIDs")
                    return
                }
                ids.insert(id)
            }
            return ids
        }
    }

    func setMeta(key: String, value: Data, type: String) throws {
        try withLock {
            let sql = """
                INSERT INTO app_meta (key, value_type, value, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_type = excluded.value_type,
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """
            try exec(sql, [
                (1, key),
                (2, type),
                (3, value),
                (4, Int(Date().timeIntervalSince1970))
            ])
        }
    }

    func meta(key: String) throws -> Data? {
        return try withLock { () -> Data? in
            let sql = "SELECT value, value_type FROM app_meta WHERE key = ?"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, Self.sqlLiteTransientDestructor)
            // ID-CRASH-0022 (2026-10-20): distinguish "no such key"
            // (SQLITE_DONE → nil) from a real read failure (throw).
            // The old code collapsed both into nil, so a broken
            // app_meta table looked exactly like "flag not set yet".
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "(no error message)"
                Self.logger.error("sqlite3_step failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
                throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
            }
            guard let cstr = sqlite3_column_blob(stmt, 0) else { return nil }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            return Data(bytes: cstr, count: len)
        }
    }

    // MARK: - SQLite-specific transaction helpers

    /// Caller (ClipboardStore.saveItems' granular path) wraps multiple
    /// upserts in a single transaction so partial failure rolls back.
    /// WAL + NORMAL synchronous = fsync per checkpoint (per docs §1.1).
    func beginTransaction() throws {
        try withLock {
            try exec("BEGIN IMMEDIATE TRANSACTION")
        }
    }

    func commitTransaction() throws {
        try withLock {
            try exec("COMMIT")
        }
    }

    /// Rolls back the current transaction.
    ///
    /// ID-CRASH-0022 (2026-10-20): this THROWS when the ROLLBACK
    /// itself fails. It used to be treated as best-effort — the
    /// caller-side catch in `ClipboardStore+Persistence.swift` now
    /// logs a failed rollback instead of letting it replace the
    /// original error, and `inTransaction` resets the connection when
    /// it cannot roll back.
    func rollbackTransaction() throws {
        try withLock {
            // ID-CRASH-0022 (2026-10-20): test seam. When set, the NEXT
            // rollback fails — lets the suite exercise the reset path
            // deterministically instead of leaving it unverified.
            // One-shot: cleared when it fires.
            if let injected = rollbackFailureForTest {
                rollbackFailureForTest = nil
                try resetConnection(afterRollbackFailure: injected)
                return
            }
            do {
                try exec("ROLLBACK")
            } catch {
                // The ROLLBACK failed, but the recovery still achieves
                // the requested effect: closing the handle rolls the
                // open transaction back. So this does NOT throw on the
                // ROLLBACK failure — only when the connection itself
                // could not be recovered.
                try resetConnection(afterRollbackFailure: error)
            }
        }
    }

    // MARK: - Internal helpers (single-row CRUD, called within withLock)

    private func upsertItemInternal(_ item: ClipboardItem) throws {
        let sql = """
            INSERT INTO items (id, type, is_pinned, is_encrypted, is_sensitive,
                                decryption_failed, expires_at, created_at, updated_at,
                                content_hash, content_blob, ocr_text, ocr_attempted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                type = excluded.type,
                is_pinned = excluded.is_pinned,
                is_encrypted = excluded.is_encrypted,
                is_sensitive = excluded.is_sensitive,
                decryption_failed = excluded.decryption_failed,
                expires_at = excluded.expires_at,
                updated_at = excluded.updated_at,
                content_hash = excluded.content_hash,
                content_blob = excluded.content_blob,
                ocr_text = excluded.ocr_text,
                ocr_attempted = excluded.ocr_attempted
            """
        try exec(sql, [
            (1, item.id.uuidString),
            (2, item.type.rawValue),
            (3, Int(item.isPinned ? 1 : 0)),
            (4, Int(item.isEncrypted ? 1 : 0)),
            (5, Int(item.isSensitive ? 1 : 0)),
            (6, Int(item.decryptionFailed ? 1 : 0)),
            (7, item.expiresAt.map { Int($0.timeIntervalSince1970) } ?? NSNull()),
            (8, Int(item.createdAt.timeIntervalSince1970)),
            (9, Int(Date().timeIntervalSince1970)),
            (10, item.contentHash ?? NSNull()),
            (11, item.content),
            (12, item.ocrText ?? NSNull()),
            (13, Int(item.ocrAttempted ? 1 : 0))
        ])

        // Sync item.tagIds to item_tags junction table.
        // Per docs §3.2, item_tags is the SINGLE source of truth for
        // item ↔ tag membership; we DELETE existing rows then INSERT the
        // current Set<UUID>.
        //
        // ID-CRASH-0022 (2026-10-20): the old comment here claimed
        // "DO NOTHING is implicit on INSERT" — it is NOT; a plain
        // INSERT raises a PRIMARY KEY violation on a duplicate pair.
        // The DELETE-then-INSERT below is what makes it safe today;
        // the explicit ON CONFLICT keeps it safe if that DELETE is
        // ever refactored away, and mirrors `attachTag`.
        try exec("DELETE FROM item_tags WHERE item_id = ?", [(1, item.id.uuidString)])
        for tagID in item.tagIds {
            try exec(
                """
                INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)
                ON CONFLICT(item_id, tag_id) DO NOTHING
                """,
                [(1, item.id.uuidString), (2, tagID.uuidString)]
            )
        }
    }

    private func upsertTagInternal(_ tag: Tag) throws {
        let sql = """
            INSERT INTO tags (id, name, color_hex, is_auto, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                color_hex = excluded.color_hex,
                is_auto = excluded.is_auto
            """
        try exec(sql, [
            (1, tag.id.uuidString),
            (2, tag.name),
            (3, tag.colorHex),
            (4, Int(tag.isAutoSuggested ? 1 : 0)),
            (5, Int(tag.createdAt.timeIntervalSince1970))
        ])
    }

    private func upsertTrashItemInternal(itemID: UUID, snapshot: ClipboardItem) throws {
        let sql = """
            INSERT INTO trash_items (item_id, trashed_at, expires_at,
                                      content_blob, content_hash, is_encrypted,
                                      type, is_pinned, is_sensitive, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
                trashed_at = excluded.trashed_at,
                expires_at = excluded.expires_at,
                content_blob = excluded.content_blob,
                content_hash = excluded.content_hash,
                is_encrypted = excluded.is_encrypted,
                type = excluded.type,
                is_pinned = excluded.is_pinned,
                is_sensitive = excluded.is_sensitive,
                created_at = excluded.created_at
            """
        let trashedAt = Date()
        let expiresAt = Calendar.current.date(
            byAdding: .day, value: 30, to: trashedAt
        ) ?? trashedAt
        try exec(sql, [
            (1, itemID.uuidString),
            (2, Int(trashedAt.timeIntervalSince1970)),
            (3, Int(expiresAt.timeIntervalSince1970)),
            (4, snapshot.content),
            (5, snapshot.contentHash ?? NSNull()),
            (6, Int(snapshot.isEncrypted ? 1 : 0)),
            (7, snapshot.type.rawValue),
            (8, Int(snapshot.isPinned ? 1 : 0)),
            (9, Int(snapshot.isSensitive ? 1 : 0)),
            (10, Int(snapshot.createdAt.timeIntervalSince1970))
        ])
    }

    private func loadTrashItemInternal(itemID: UUID) throws -> ClipboardItem? {
        let sql = """
            SELECT item_id, type, is_pinned, is_encrypted, is_sensitive,
                   content_hash, content_blob, created_at
            FROM trash_items WHERE item_id = ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, Self.sqlLiteTransientDestructor)
        // ID-CRASH-0022 (2026-10-20): "no such trash row" (DONE → nil)
        // is a normal answer; a step failure is not — it must throw,
        // otherwise `restoreFromTrash` reports "no trash row for item
        // X", which points the caller at the wrong cause.
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "(no error message)"
            Self.logger.error("sqlite3_step failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
        }
        return decodeTrashRow(stmt: stmt)
    }

    private func loadTrashItem(itemID: UUID) throws -> ClipboardItem? {
        return try loadTrashItemInternal(itemID: itemID)
    }

    /// Whether a trash row exists for `itemID`, regardless of whether it
    /// can be decoded.
    ///
    /// ID-CRASH-0022 (2026-10-20): `restoreFromTrash` needs to tell
    /// "the row is absent" from "the row is present but corrupt" — two
    /// different operator responses (retry vs. restore-from-quarantine)
    /// that used to share one message.
    private func trashRowExists(itemID: UUID) throws -> Bool {
        let sql = "SELECT 1 FROM trash_items WHERE item_id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, Self.sqlLiteTransientDestructor)
        var found = false
        try forEachRow(stmt, sql: sql) { _ in
            found = true
        }
        return found
    }

    private func decodeTrashRow(stmt: OpaquePointer) -> ClipboardItem? {
        func text(_ index: Int32) -> String? {
            guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cstr)
        }
        func int(_ index: Int32) -> Int {
            return Int(sqlite3_column_int64(stmt, index))
        }
        guard let idStr = text(0), let id = UUID(uuidString: idStr),
              let typeStr = text(1), let type = ClipboardItemType(rawValue: typeStr) else {
            // ID-CRASH-0022 (2026-10-20): a row we cannot decode is
            // skipped, but it must not vanish silently — log it, so a
            // growing pile of unreadable rows is at least visible.
            Self.logger.error(
                "skipping undecodable trash row (id=\(text(0) ?? "<null>"), type=\(text(1) ?? "<null>"))"
            )
            return nil
        }
        // Column order comes from the SELECT above:
        //   0 item_id | 1 type | 2 is_pinned | 3 is_encrypted |
        //   4 is_sensitive | 5 content_hash | 6 content_blob | 7 created_at
        // ID-CRASH-0022 (2026-10-20): these two were swapped — content
        // was read from the content_hash column and contentHash from
        // content_blob, so every restored item came back with an empty
        // content string (and the ciphertext in the hash slot).
        let content = text(6) ?? ""
        let contentHash = text(5)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(int(7)))
        let isPinned = int(2) != 0
        let isEncrypted = int(3) != 0
        let isSensitive = int(4) != 0
        return ClipboardItem(
            id: id,
            content: content,
            type: type,
            createdAt: createdAt,
            isPinned: isPinned,
            isSensitive: isSensitive,
            isEncrypted: isEncrypted,
            contentHash: contentHash
        )
    }

    private func loadItemsFromDB() throws -> [ClipboardItem] {
        let sql = """
            SELECT id, type, is_pinned, is_encrypted, is_sensitive,
                   decryption_failed, expires_at, created_at, updated_at,
                   content_hash, content_blob, ocr_text, ocr_attempted
            FROM items
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var items: [ClipboardItem] = []
        try forEachRow(stmt, sql: sql) { row in
            if let item = decodeItemRow(stmt: row) {
                items.append(item)
            }
        }
        guard !items.isEmpty else { return items }
        // ID-CRASH-0022 (2026-10-20): backfill `tagIds` from the
        // item_tags junction table.
        //
        // Without this, a load → save round trip DESTROYS every tag
        // association: `upsertItemInternal` mirrors `item.tagIds` into
        // item_tags (DELETE the item's rows, then INSERT the current
        // set), so an item read back with an empty tagIds set wipes its
        // own membership rows. The array-level `save(_:)` does exactly
        // that for every item it rewrites — i.e. the first full save
        // after a load empties the whole tag catalog's usage. Per docs
        // §3.2 item_tags is the single source of truth for membership,
        // so the read path has to populate it.
        let tagMap = try loadItemTagMap()
        for index in items.indices {
            items[index].tagIds = tagMap[items[index].id] ?? []
        }
        return items
    }

    /// item_id → the tag ids attached to it, read from the item_tags
    /// junction table (docs §3.2 — the single source of truth for
    /// item ↔ tag membership).
    private func loadItemTagMap() throws -> [UUID: Set<UUID>] {
        let sql = "SELECT item_id, tag_id FROM item_tags"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var map: [UUID: Set<UUID>] = [:]
        try forEachRow(stmt, sql: sql) { row in
            guard let itemC = sqlite3_column_text(row, 0),
                  let tagC = sqlite3_column_text(row, 1) else {
                Self.logger.error("skipping item_tags row with a NULL id")
                return
            }
            guard let itemID = UUID(uuidString: String(cString: itemC)) else {
                Self.logger.error("skipping item_tags row with a non-UUID item_id")
                return
            }
            guard let tagID = UUID(uuidString: String(cString: tagC)) else {
                Self.logger.error("skipping item_tags row with a non-UUID tag_id")
                return
            }
            map[itemID, default: []].insert(tagID)
        }
        return map
    }

    private func loadTagsFromDB() throws -> [Tag] {
        let sql = "SELECT id, name, color_hex, is_auto, created_at FROM tags"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var tags: [Tag] = []
        try forEachRow(stmt, sql: sql) { row in
            if let tag = decodeTagRow(stmt: row) {
                tags.append(tag)
            }
        }
        return tags
    }

    private func decodeItemRow(stmt: OpaquePointer) -> ClipboardItem? {
        func text(_ index: Int32) -> String? {
            guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: cstr)
        }
        guard let idStr = text(0), let id = UUID(uuidString: idStr),
              let typeStr = text(1), let type = ClipboardItemType(rawValue: typeStr) else {
            // ID-CRASH-0022 (2026-10-20): same as decodeTrashRow — a
            // row we cannot decode is skipped, but not silently.
            Self.logger.error(
                "skipping undecodable items row (id=\(text(0) ?? "<null>"), type=\(text(1) ?? "<null>"))"
            )
            return nil
        }
        let content = text(10) ?? ""
        let contentHash = text(9)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
        let expiresAt: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
        let isPinned = sqlite3_column_int(stmt, 2) != 0
        let isEncrypted = sqlite3_column_int(stmt, 3) != 0
        let isSensitive = sqlite3_column_int(stmt, 4) != 0
        let decryptionFailed = sqlite3_column_int(stmt, 5) != 0
        let ocrText = text(11)
        let ocrAttempted = sqlite3_column_int(stmt, 12) != 0
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 8)))
        let item = ClipboardItem(
            id: id,
            content: content,
            type: type,
            createdAt: createdAt,
            isPinned: isPinned,
            isSensitive: isSensitive,
            expiresAt: expiresAt,
            isEncrypted: isEncrypted,
            contentHash: contentHash,
            decryptionFailed: decryptionFailed,
            ocrText: ocrText,
            ocrAttempted: ocrAttempted
        )
        // updatedAt is not a public field on ClipboardItem, but we
        // record the value in case future audit fields need it.
        _ = updatedAt
        return item
    }

    private func decodeTagRow(stmt: OpaquePointer) -> Tag? {
        // ID-CRASH-0022 (2026-10-20): same as decodeItemRow /
        // decodeTrashRow — a row we cannot decode is skipped, but not
        // silently.
        guard let idC = sqlite3_column_text(stmt, 0),
              let nameC = sqlite3_column_text(stmt, 1) else {
            Self.logger.error("skipping undecodable tags row")
            return nil
        }
        guard let id = UUID(uuidString: String(cString: idC)) else {
            Self.logger.error("skipping tags row with a non-UUID id")
            return nil
        }
        let name = String(cString: nameC)
        let colorHex = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let isAuto = sqlite3_column_int(stmt, 3) != 0
        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
        return Tag(
            id: id,
            name: name,
            colorHex: colorHex,
            isAutoSuggested: isAuto,
            createdAt: createdAt
        )
    }

    private static let sqlLiteTransientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    // MARK: - Test seams (internal; used only by StoreMigrationTests)

    /// Load every trash row as a flat array (per-item-id-keyed). Used
    /// by `StoreMigrationTests` to verify "all trashed items
    /// survived migration" — production callers use
    /// `restoreFromTrash(itemID:)` for one-at-a-time reads.
    func loadAllTrashInternalForTest() throws -> [ClipboardItem] {
        return try loadItemsFromDB(query: "SELECT item_id, type, is_pinned, is_encrypted, is_sensitive, content_hash, content_blob, created_at FROM trash_items ORDER BY trashed_at")
    }

    /// Count rows in `item_tags` for (itemID, tagID). Used by
    /// `StoreMigrationTests` to verify the migration emitted the
    /// junction row.
    func countItemTagInternalForTest(itemID: UUID, tagID: UUID) throws -> Int {
        // ID-CRASH-0022 (2026-10-20): this used to answer every
        // failure with "0 rows" — the same "error looks like empty
        // data" pattern the production read paths were fixed for. It
        // now goes through `prepare` / `forEachRow`, so a broken query
        // throws instead of masquerading as "the junction row is
        // missing".
        let sql = "SELECT COUNT(*) FROM item_tags WHERE item_id = ? AND tag_id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, Self.sqlLiteTransientDestructor)
        sqlite3_bind_text(stmt, 2, tagID.uuidString, -1, Self.sqlLiteTransientDestructor)
        var count = 0
        try forEachRow(stmt, sql: sql) { row in
            if let cstr = sqlite3_column_text(row, 0) {
                count = Int(String(cString: cstr)) ?? 0
            }
        }
        return count
    }

    private func loadItemsFromDB(query sql: String) throws -> [ClipboardItem] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var items: [ClipboardItem] = []
        try forEachRow(stmt, sql: sql) { row in
            // Reuse decodeTrashRow (same column layout for shared
            // columns; tag_ids not stored in trash, so it's OK to
            // return ClipboardItem with an empty tagIds set).
            if let item = decodeTrashRow(stmt: row) {
                items.append(item)
            }
        }
        return items
    }
}
