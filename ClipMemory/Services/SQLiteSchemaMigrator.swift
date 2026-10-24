//
//  SQLiteSchemaMigrator.swift
//  ClipMemory
//
//  ID-REVIEW-1024 (PR-D N.4, 2026-10-21): the schema migration driver.
//
//  Why a separate file: `SQLiteStorageBackend.swift` stood at 1143
//  lines at the previous commit, and the SwiftLint `file_length`
//  ceiling is 1250 (error) — the versioned migration driver did not
//  fit under it. This repo's answer to hitting the ceiling is to
//  SPLIT — the same answer the schema DDL got (ID-CRASH-0022) —
//  rather than to waive the rule. The backend is 1120 lines after
//  the split.
//
//  Both numbers are checkable, not asserted:
//    git show e07cbd7:ClipMemory/Services/SQLiteStorageBackend.swift | wc -l
//    git show HEAD:ClipMemory/Services/SQLiteStorageBackend.swift | wc -l
//
//  Why a separate TYPE rather than an extension in another file: the
//  driver needs the raw `sqlite3*` handle and its own thin SQL
//  helpers. Reaching the backend's `private` members from another file
//  would mean widening them to `internal`, which exposes the whole
//  data layer's internals to the module. A dedicated type keeps the
//  handle and the helpers to itself.
//
//  Threading: this runs once, from `SQLiteStorageBackend.init`, on
//  the thread that opens the connection — before the backend's lock
//  exists and before any other thread can reach the backend.
//
//  Contract: docs/design/storage-migration.md §2 and §4.4.
//

import Foundation
import os.log
import SQLite3

/// Drives a database from the schema version it carries to the version
/// the build expects.
enum SQLiteSchemaMigrator {

    private static let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "SQLiteSchemaMigrator"
    )

    // MARK: - The driver

    /// Migrates `db` to `schema.version`.
    ///
    /// ID-REVIEW-1024 (PR-D N.4, 2026-10-21): the schema version is
    /// AUTHORITATIVE and comes from SQLite's own `PRAGMA user_version`
    /// (the database header), not from a table row nobody read.
    ///
    /// Before this, the version was only RECORDED in `schema_version`
    /// and `migrateSchema` decided by asking whether the `items` table
    /// existed — so an existing database could never be upgraded to a
    /// future schema, and a database written by a NEWER build was
    /// indistinguishable from a current one.
    ///
    /// The rules now:
    /// * `user_version` == the current version → nothing to do.
    /// * `user_version` < the current version → apply the base DDL
    ///   (if the database is below the base) and every upgrade step
    ///   above it, then stamp the version.
    /// * `user_version` > the current version → REFUSE. The database
    ///   was written by a newer build; touching a schema this build
    ///   does not understand is how databases get corrupted.
    ///
    /// The whole migration runs in ONE transaction: the DDL, the
    /// ledger rows and the version stamp commit together or not at
    /// all. `PRAGMA user_version` lives in the database header, and
    /// the header is written like any other page — so the stamp is
    /// transactional too (a ROLLBACK puts the old version back).
    /// That is what makes "the version can never disagree with the
    /// schema" a property of the implementation rather than a hope.
    static func migrate(db: OpaquePointer?, schema: SQLiteSchema.Definition) throws {
        // The migrator owns its own transaction, so it must be the one
        // that starts it: `BEGIN` on a connection that is already in a
        // transaction fails with "cannot start a transaction within a
        // transaction", and that error would look like a schema
        // problem instead of "you called this at the wrong time".
        guard let handle = db, sqlite3_get_autocommit(handle) == 1 else {
            throw StorageBackendError.storageFailure(
                sql: "BEGIN IMMEDIATE TRANSACTION",
                code: SQLITE_MISUSE,
                detail: "the schema migration must run on a connection that is not already in a transaction"
            )
        }

        // Read the version FIRST, without a lock: when the database is
        // already current (the overwhelmingly common case) there is
        // nothing to migrate and the migration must not touch the file
        // at all.
        let current = try readUserVersion(db)
        guard current <= schema.version else {
            logger.error("""
            SQLite schema version \(current) is newer than this build supports \
            (\(schema.version)) — refusing to touch the database
            """)
            throw newerVersionError(current, schema.version)
        }
        guard current < schema.version else { return }

        // IMMEDIATE takes the write lock now rather than at the first
        // write, so a concurrent reader cannot turn the upgrade into a
        // SQLITE_BUSY halfway through. The connection's busy_timeout
        // (set by the backend) bounds the wait.
        try exec(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            // Re-read the version INSIDE the lock. Between the read
            // above and the moment the lock was granted, another
            // process could have changed it — and migrating against
            // that stale reading would re-apply steps that are already
            // done (fine for idempotent steps, fatal for the others).
            let locked = try readUserVersion(db)
            guard locked <= schema.version else {
                throw newerVersionError(locked, schema.version)
            }
            guard locked < schema.version else {
                // Another process got there first. Nothing to do.
                try exec(db, "COMMIT")
                return
            }

            try validateSteps(schema)

            let reached = try applySteps(db, schema, from: locked)

            // Defence in depth: the chain validation above is what
            // actually guarantees the target version is reachable (a
            // contiguous chain always ends on it), so this branch is
            // unreachable today. It stays because it is the last thing
            // standing between a future change to that validation and
            // a version stamp that lies.
            guard reached == schema.version else {
                logger.error("""
                SQLite schema migration stopped at version \(reached) but this build \
                expects \(schema.version) — refusing to stamp a version that was never reached
                """)
                throw StorageBackendError.storageFailure(
                    sql: "PRAGMA user_version",
                    code: SQLITE_ERROR,
                    detail: "schema migration reached version \(reached) but this build expects \(schema.version); the version was not stamped"
                )
            }

            // The version is stamped LAST, and inside the same
            // transaction as the DDL it describes: if anything above
            // fails, the database keeps its old version AND its old
            // schema, and the next open retries from a clean state.
            try writeUserVersion(db, schema.version)
            try exec(db, "COMMIT")
        } catch {
            rollback(db, after: error)
            throw error
        }
    }

    /// Applies the base DDL (when the database is below the base) and
    /// every upgrade step above `current`, and returns the version the
    /// schema actually reached.
    private static func applySteps(
        _ db: OpaquePointer?,
        _ schema: SQLiteSchema.Definition,
        from current: Int
    ) throws -> Int {
        var reached = current

        // The base DDL. Every statement is idempotent, so a database
        // that already carries the tables (created by the old
        // table-existence check) is simply stamped, not rebuilt.
        if reached < schema.baseVersion {
            for stmt in schema.baseStatements {
                try exec(db, stmt)
            }
            try recordVersion(db, schema.baseVersion, notes: schema.baseVersionNotes)
            reached = schema.baseVersion
        }

        // The upgrade steps, oldest first.
        for step in schema.steps.sorted(by: { $0.version < $1.version })
        where step.version > reached {
            for stmt in step.statements {
                try exec(db, stmt)
            }
            try recordVersion(db, step.version, notes: step.notes)
            reached = step.version
        }
        return reached
    }

    /// Rolls the migration back so the database is left exactly as it
    /// was.
    ///
    /// A failed ROLLBACK is logged, not swallowed: it leaves the
    /// connection inside an open transaction, which SQLite rolls back
    /// when the handle closes — but the caller must still hear about
    /// the original failure, which is what `migrate` rethrows.
    private static func rollback(_ db: OpaquePointer?, after cause: Error) {
        do {
            try exec(db, "ROLLBACK")
        } catch {
            logger.error("""
            ROLLBACK after a failed schema migration failed: \
            \(error.localizedDescription) — the connection state is indeterminate \
            (original failure: \(cause.localizedDescription))
            """)
        }
    }

    /// The error for a database written by a NEWER build.
    ///
    /// One place, because the check happens twice — once before the
    /// transaction and once inside it — and the two messages must not
    /// drift apart.
    private static func newerVersionError(_ version: Int, _ supported: Int) -> StorageBackendError {
        StorageBackendError.storageFailure(
            sql: "PRAGMA user_version",
            code: SQLITE_ERROR,
            detail: "database schema version \(version) is newer than this build supports (\(supported))"
        )
    }

    /// Checks that the compiled-in upgrade steps form a contiguous
    /// chain from `baseVersion + 1` to `version`.
    ///
    /// This is a property of the BUILD, not of the database, so a
    /// mistake here (a bumped `version` with a forgotten step) is
    /// caught the first time a database needs migrating — instead of
    /// silently producing a database that is missing a version's
    /// changes.
    ///
    /// A gap is the dangerous case: the chain would still END on the
    /// target version, so the reachability check in `migrate` would
    /// wave it through, and the database would have silently skipped
    /// the missing version's changes. **This validation is the only
    /// thing that catches a gap** — which is why it runs before
    /// anything is written.
    private static func validateSteps(_ schema: SQLiteSchema.Definition) throws {
        try validateVersionRange(schema)
        try validateBaseVersion(schema)
        try validateStepChain(schema)
    }

    /// SQLite stores `PRAGMA user_version` in a 32-bit signed
    /// integer, so a target version outside that range cannot be
    /// stamped at all.
    ///
    /// The check lives HERE — in the validation that runs before
    /// anything is written — and not only in `writeUserVersion`,
    /// because a guard nobody can REACH cannot be tested, and an
    /// untested guard is a comment. `writeUserVersion` keeps its
    /// own check as the last line of defence.
    ///
    /// The UPPER bound is the one that bites in practice: a typo'd
    /// target version (or one past `Int32.max`) is refused before
    /// anything is written. The lower bound only matters if the
    /// database header itself holds a negative version, which needs a
    /// hand-edited file — it is cheap to check, so it is checked.
    private static func validateVersionRange(_ schema: SQLiteSchema.Definition) throws {
        guard schema.version >= 0, schema.version <= Int(Int32.max) else {
            logger.error("""
            SQLite schema version \(schema.version) is outside the range SQLite can \
            store in `PRAGMA user_version` (0...\(Int32.max))
            """)
            throw StorageBackendError.storageFailure(
                sql: "PRAGMA user_version",
                code: SQLITE_ERROR,
                detail: """
                the schema version \(schema.version) is outside the range SQLite can \
                store in `PRAGMA user_version` (0...\(Int32.max))
                """
            )
        }
    }

    /// The base version is the one the base DDL creates. It is
    /// NEVER edited after shipping — that is what the step chain is
    /// for — so a schema whose base is anything else is a mistake
    /// that would leave version 1 unreachable ("I skipped v1").
    private static func validateBaseVersion(_ schema: SQLiteSchema.Definition) throws {
        guard schema.baseVersion == SQLiteSchema.baseVersion else {
            logger.error("""
            SQLite schema base version \(schema.baseVersion) does not match the shipped \
            base \(SQLiteSchema.baseVersion) — a database could never be upgraded from v1
            """)
            throw StorageBackendError.storageFailure(
                sql: "PRAGMA user_version",
                code: SQLITE_ERROR,
                detail: """
                the schema's base version is \(schema.baseVersion) but the shipped base \
                is \(SQLiteSchema.baseVersion); the base DDL is never edited after \
                shipping, so the base version must stay \(SQLiteSchema.baseVersion)
                """
            )
        }
    }

    /// Checks that the upgrade steps cover `baseVersion + 1 … version`
    /// exactly once each.
    ///
    /// `baseVersion + 1 ... version` is an ILLEGAL range when the base
    /// IS the target (the shipped schema: both are 1), and building it
    /// would trap at runtime. There is simply nothing to upgrade in
    /// that case.
    ///
    /// The range is NOT materialised. `Array((baseVersion + 1)...
    /// version)` asks for one element per version, so a typo in the
    /// target version (999_999_999) would allocate gigabytes before
    /// anything noticed. The chain is checked by COUNT plus BOUNDS
    /// instead, which allocates nothing:
    /// `expectedCount` distinct versions, all inside
    /// `(baseVersion, version]`, can only BE the whole range.
    ///
    /// The two agree for `baseVersion < version`. They differ in two
    /// places, both towards safety: this check REJECTS a duplicated
    /// version (a set comparison would collapse it), and it ACCEPTS
    /// `baseVersion >= version` (the old range would trap at runtime —
    /// and the shipped schema, `baseVersion == version == 1`, sits
    /// exactly in that case).
    private static func validateStepChain(_ schema: SQLiteSchema.Definition) throws {
        let expectedCount = max(0, schema.version - schema.baseVersion)
        let provided = schema.steps.map(\.version)
        // Named explicitly: nesting the `$0`/`$1` shorthand makes the
        // inner `$1` refer to the inner closure, which has one
        // argument — a compile error that reads like a typo.
        var occurrences: [Int: Int] = [:]
        for version in provided {
            occurrences[version, default: 0] += 1
        }
        let duplicated = Set(occurrences.filter { $0.value > 1 }.keys)
        let providedSet = Set(provided)
        let outOfRange = provided.filter { $0 <= schema.baseVersion || $0 > schema.version }

        // The missing versions are SAMPLED, not enumerated. Only
        // `providedSet.count` versions are present, so the first gap is
        // within `baseVersion + 1 ... baseVersion + providedSet.count
        // + 1` — a window that stays small no matter how large the
        // target version is.
        var missing: [Int] = []
        let missingCount = max(0, expectedCount - providedSet.count)
        if missingCount > 0 {
            var candidate = schema.baseVersion + 1
            let limit = min(schema.version, schema.baseVersion + providedSet.count + 1)
            while candidate <= limit {
                if !providedSet.contains(candidate) { missing.append(candidate) }
                candidate += 1
            }
        }

        guard duplicated.isEmpty, missingCount == 0, outOfRange.isEmpty else {
            logger.error("""
            SQLite schema migration steps are broken: missing=\(missing) \
            (\(missingCount) in total) duplicated=\(duplicated.sorted()) \
            outOfRange=\(outOfRange.sorted())
            """)
            throw StorageBackendError.storageFailure(
                sql: "PRAGMA user_version",
                code: SQLITE_ERROR,
                detail: """
                the compiled-in schema migration steps do not form a chain from \
                version \(schema.baseVersion + 1) to \(schema.version) \
                (missing: \(missing) — \(missingCount) in total, \
                duplicated: \(duplicated.sorted()), \
                out of range: \(outOfRange.sorted()))
                """
            )
        }
    }

    // MARK: - The version

    /// Records an applied version in the human-readable ledger.
    private static func recordVersion(_ db: OpaquePointer?, _ version: Int, notes: String) throws {
        let record = SQLiteSchema.versionRecord(for: version, notes: notes)
        try exec(db, record.sql, record.bindings)
    }

    /// Reads SQLite's own schema version from the database header.
    ///
    /// `PRAGMA user_version` lives in the file header, so it cannot get
    /// out of sync with the database it describes the way a row in a
    /// table can.
    ///
    /// One caveat, measured rather than assumed: in WAL mode the
    /// header change lands in the `-wal` side file first and reaches
    /// the main file at the next checkpoint. Another connection still
    /// reads the right value (it reads the WAL too) — but copying the
    /// `.sqlite3` file WITHOUT its `-wal` companion yields a database
    /// that never received the migration.
    private static func readUserVersion(_ db: OpaquePointer?) throws -> Int {
        let sql = "PRAGMA user_version"
        guard let db else {
            throw StorageBackendError.storageFailure(
                sql: sql, code: SQLITE_MISUSE, detail: "connection is nil"
            )
        }
        var stmt: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            logger.error("sqlite3_prepare_v2 failed for sql: \(sql)")
            throw StorageBackendError.storageFailure(
                sql: sql,
                code: prepareRC,
                detail: "could not read the schema version: \(msg)"
            )
        }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            logger.error("sqlite3_step failed (rc=\(stepRC)): \(msg) — sql=\(sql)")
            throw StorageBackendError.storageFailure(
                sql: sql,
                code: stepRC,
                detail: "could not read the schema version: \(msg)"
            )
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Stamps the schema version into the database header.
    ///
    /// `PRAGMA user_version` does not accept bound parameters, so the
    /// value is interpolated. It is an `Int` this build controls — never
    /// anything that came from a file or the user's input — and the
    /// guard below keeps it that way even if a future caller passes
    /// something else. SQLite stores the version in a 32-bit signed
    /// integer, so the upper bound matters too.
    private static func writeUserVersion(_ db: OpaquePointer?, _ version: Int) throws {
        guard version >= 0, version <= Int(Int32.max) else {
            throw StorageBackendError.storageFailure(
                sql: "PRAGMA user_version",
                code: SQLITE_MISUSE,
                detail: "refusing to stamp a schema version outside 0...Int32.max (\(version))"
            )
        }
        try exec(db, "PRAGMA user_version = \(version)")
    }

    // MARK: - SQL helpers

    /// Runs a statement that returns no rows.
    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard let db else {
            throw StorageBackendError.storageFailure(
                sql: sql, code: SQLITE_MISUSE, detail: "connection is nil"
            )
        }
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "(no error message)"
            logger.error("sqlite3_exec failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
            sqlite3_free(err)
            throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
        }
    }

    /// Runs a statement with bound parameters.
    private static func exec(
        _ db: OpaquePointer?,
        _ sql: String,
        _ params: [(Int32, SQLiteValue)]
    ) throws {
        guard let db else {
            throw StorageBackendError.storageFailure(
                sql: sql, code: SQLITE_MISUSE, detail: "connection is nil"
            )
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let prepareRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            logger.error("sqlite3_prepare_v2 failed for sql: \(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: prepareRC, detail: msg)
        }
        for (index, value) in params {
            // ID-REVIEW-1024 (2026-10-24): a rejected bind (SQLITE_RANGE /
            // SQLITE_NOMEM) must abort the migration step, not step the
            // statement with NULL / unbound parameters.
            let rc = SQLiteBinder.bind(stmt: stmt, index: index, value: value)
            guard rc == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                logger.error("sqlite3_bind failed (rc=\(rc)): \(msg) — sql=\(sql.prefix(120))")
                throw StorageBackendError.storageFailure(sql: sql, code: rc, detail: msg)
            }
        }
        let stepRC = sqlite3_step(stmt)
        if stepRC != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            logger.error("sqlite3_step failed for sql: \(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: stepRC, detail: msg)
        }
    }
}
