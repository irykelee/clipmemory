//
//  SQLiteSchemaMigrator.swift
//  ClipMemory
//
//  ID-REVIEW-1024 (PR-D N.4, 2026-10-21): the schema migration driver.
//
//  Why a separate file: `SQLiteStorageBackend.swift` was already within
//  four lines of the SwiftLint `file_length` error ceiling (1250) when
//  the schema DDL was moved out into `SQLiteSchema.swift`
//  (ID-CRASH-0022). The versioned migration driver pushed it over that
//  ceiling (1293 lines). This repo's answer to hitting the ceiling is
//  to SPLIT — the same answer the DDL got — rather than to waive the
//  rule. So the driver moves here.
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
//  Contract: docs/design/storage-migration.md §2.
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

    private static let sqlLiteTransientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
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
    /// The version is stamped LAST, and only if the migration chain
    /// actually REACHED the target version. Stamping a version whose
    /// migration never ran is the worst possible outcome: every later
    /// open would believe the upgrade happened and skip it forever.
    static func migrate(db: OpaquePointer?, schema: SQLiteSchema.Definition) throws {
        let current = try readUserVersion(db)
        guard current <= schema.version else {
            logger.error("""
            SQLite schema version \(current) is newer than this build supports \
            (\(schema.version)) — refusing to touch the database
            """)
            throw StorageBackendError.storageFailure(
                sql: "PRAGMA user_version",
                code: SQLITE_ERROR,
                detail: "database schema version \(current) is newer than this build supports (\(schema.version))"
            )
        }
        guard current < schema.version else { return }

        // The steps must form a contiguous chain from baseVersion + 1
        // up to the target version. A gap means the database would
        // JUMP a version — the missing version's changes would never
        // be applied, and the reachability check below would not catch
        // it (the chain would still end on the target version).
        try validateSteps(schema)

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

        // The chain must have landed exactly on the target version.
        guard reached == schema.version else {
            logger.error("""
            SQLite schema migration stopped at version \(reached) but this build \
            expects \(schema.version) — refusing to stamp a version that was never reached
            """)
            throw StorageBackendError.storageFailure(
                sql: "PRAGMA user_version",
                code: SQLITE_ERROR,
                detail: """
                schema migration reached version \(reached) but this build expects \
                \(schema.version); the version was not stamped
                """
            )
        }

        // The version is stamped LAST: if anything above fails, the
        // database keeps its old version and the next open retries.
        try writeUserVersion(db, schema.version)
    }

    /// Checks that the compiled-in upgrade steps form a contiguous
    /// chain from `baseVersion + 1` to `version`.
    ///
    /// This is a property of the BUILD, not of the database, so a
    /// mistake here (a bumped `version` with a forgotten step) is
    /// caught the first time a database needs migrating — instead of
    /// silently producing a database that is missing a version's
    /// changes.
    private static func validateSteps(_ schema: SQLiteSchema.Definition) throws {
        // `baseVersion + 1 ... version` is an ILLEGAL range when the
        // base IS the target (the shipped schema: both are 1), and
        // building it would trap at runtime. There is simply nothing
        // to upgrade in that case.
        let expected = schema.baseVersion < schema.version
            ? Array((schema.baseVersion + 1)...schema.version)
            : []
        let provided = schema.steps.map(\.version)
        // Named explicitly: nesting the `$0`/`$1` shorthand makes the
        // inner `$1` refer to the inner closure, which has one
        // argument — a compile error that reads like a typo.
        let duplicated = Set(provided.filter { value in
            provided.filter { $0 == value }.count > 1
        })
        let missing = expected.filter { !provided.contains($0) }
        let outOfRange = provided.filter { !expected.contains($0) }

        guard duplicated.isEmpty, missing.isEmpty, outOfRange.isEmpty else {
            logger.error("""
            SQLite schema migration steps are broken: missing=\(missing) \
            duplicated=\(duplicated.sorted()) outOfRange=\(outOfRange.sorted())
            """)
            throw StorageBackendError.storageFailure(
                sql: "PRAGMA user_version",
                code: SQLITE_ERROR,
                detail: """
                the compiled-in schema migration steps do not form a chain from \
                version \(schema.baseVersion + 1) to \(schema.version) \
                (missing: \(missing), duplicated: \(duplicated.sorted()), \
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
    /// anything that came from a file or the user's input.
    private static func writeUserVersion(_ db: OpaquePointer?, _ version: Int) throws {
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
        _ params: [(Int32, Any)]
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
            bind(stmt: stmt, index: index, value: value)
        }
        let stepRC = sqlite3_step(stmt)
        if stepRC != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            logger.error("sqlite3_step failed for sql: \(sql.prefix(120))")
            throw StorageBackendError.storageFailure(sql: sql, code: stepRC, detail: msg)
        }
    }

    /// Binds a value to a prepared statement.
    private static func bind(stmt: OpaquePointer, index: Int32, value: Any) {
        if let s = value as? String {
            sqlite3_bind_text(stmt, index, s, -1, sqlLiteTransientDestructor)
        } else if let i = value as? Int {
            sqlite3_bind_int64(stmt, index, Int64(i))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
