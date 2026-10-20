import SQLite3
import XCTest
@testable import ClipMemory

/// ID-REVIEW-1024 (PR-D N.4, 2026-10-21) — the schema version is
/// AUTHORITATIVE.
///
/// Before this, `SQLiteSchema.version` was recorded in the
/// `schema_version` table and NOTHING read it: `migrateSchema` decided
/// whether to run by asking whether the `items` table existed. An
/// existing database could therefore never be upgraded to a future
/// schema, and a database written by a NEWER build was
/// indistinguishable from a current one.
///
/// The version now lives in SQLite's own `PRAGMA user_version` (the
/// database header) and decides what runs.
///
/// The tests below deliberately drive the backend with SYNTHETIC
/// schemas (a base plus upgrade steps). The shipped schema has exactly
/// one version and no steps, so a driver that ignored the version
/// entirely would pass every test written against it — a guard that
/// cannot fail is not a guard.
final class SQLiteSchemaVersionTests: XCTestCase {

    private var dir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaVersionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("store.sqlite3")
    }

    override func tearDownWithError() throws {
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Synthetic schemas

    /// A schema that is the shipped base plus the given upgrade steps.
    ///
    /// The base statements are the REAL ones, so the synthetic schemas
    /// are exercised against the schema production actually ships.
    private func schema(
        version: Int,
        steps: [SQLiteSchema.MigrationStep] = [],
        baseStatements: [String]? = nil
    ) -> SQLiteSchema.Definition {
        SQLiteSchema.Definition(
            baseVersion: SQLiteSchema.baseVersion,
            version: version,
            baseStatements: baseStatements ?? SQLiteSchema.statements,
            baseVersionNotes: SQLiteSchema.baseVersionNotes,
            steps: steps
        )
    }

    /// A step that creates a table — safe to re-run, so a partially
    /// applied step can be retried.
    private func tableStep(_ version: Int, table: String) -> SQLiteSchema.MigrationStep {
        SQLiteSchema.MigrationStep(
            version: version,
            statements: ["CREATE TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY);"],
            notes: "test step \(version)"
        )
    }

    /// A step that CANNOT be re-run: the second INSERT violates the
    /// primary key of `app_meta`. Used to prove a step is not applied
    /// twice.
    private func singleShotStep(_ version: Int) -> SQLiteSchema.MigrationStep {
        SQLiteSchema.MigrationStep(
            version: version,
            statements: [
                "INSERT INTO app_meta (key, value_type, value, updated_at) " +
                "VALUES ('upgrade_probe', 'blob', X'00', 0);"
            ],
            notes: "test step \(version)"
        )
    }

    // MARK: - Raw file helpers

    /// Reads `PRAGMA user_version` straight from the database file —
    /// the backend's own view is not enough, the point is what the FILE
    /// carries.
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

    /// Writes `PRAGMA user_version` straight into the database file.
    private func writeUserVersion(_ version: Int, at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil),
            SQLITE_OK
        )
    }

    /// The versions recorded in the human-readable ledger.
    private func readLedger(at url: URL) throws -> [Int] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT version FROM schema_version ORDER BY version", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        var versions: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            versions.append(Int(sqlite3_column_int(stmt, 0)))
        }
        return versions
    }

    /// Whether a table exists in the database file.
    ///
    /// The step result is what decides the answer — asserting
    /// `SQLITE_ROW` here would fail the whole test when the table is
    /// ABSENT, which is exactly the case several tests ask about.
    private func tableExists(_ name: String, at url: URL) throws -> Bool {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        XCTFail("sqlite3_step failed (rc=\(rc)) while looking for table \(name)")
        return false
    }

    // MARK: - The contracts

    /// A fresh database carries the current schema version.
    func testFreshDatabaseIsStampedWithTheSchemaVersion() throws {
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.version,
            "a fresh database must be stamped with the current schema version"
        )
        XCTAssertEqual(
            try readLedger(at: dbURL),
            [SQLiteSchema.baseVersion],
            "the ledger must record the base version"
        )
    }

    /// Reopening a database is a no-op — and must not fail. The ledger
    /// row is written with `INSERT OR IGNORE` precisely because the
    /// row is already there.
    func testReopeningAnExistingDatabaseChangesNothing() throws {
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        _ = try SQLiteStorageBackend(databaseURL: dbURL)

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.version,
            "reopening must not change the schema version"
        )
        XCTAssertEqual(
            try readLedger(at: dbURL),
            [SQLiteSchema.baseVersion],
            "the ledger must hold exactly one row for the base schema"
        )
    }

    /// The upgrade path: a database that carries the tables but no
    /// version (what the old table-existence check produced) is stamped
    /// when it is opened.
    func testUnstampedExistingDatabaseIsStampedOnOpen() throws {
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        try writeUserVersion(0, at: dbURL)
        XCTAssertEqual(try readUserVersion(at: dbURL), 0, "precondition: the version is cleared")

        _ = try SQLiteStorageBackend(databaseURL: dbURL)

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.version,
            "an existing database must be brought up to the current schema version"
        )
    }

    /// A database written by a NEWER build must be REFUSED, not
    /// downgraded: this build does not know that schema.
    func testDatabaseFromANewerBuildIsRefused() throws {
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        let newer = SQLiteSchema.version + 1
        try writeUserVersion(newer, at: dbURL)

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: dbURL)) { error in
            guard let backendError = error as? StorageBackendError,
                  case .storageFailure(_, _, let detail) = backendError else {
                return XCTFail("expected a storageFailure, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("newer"),
                "the error must say the database is newer than this build: \(detail)"
            )
        }
        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            newer,
            "a refused database must not be rewritten"
        )
    }

    // MARK: - The upgrade path (the part that could not be tested before)

    /// A database that is LOCKED by another process fails as a
    /// TRANSIENT error — and changes nothing.
    ///
    /// The migration takes a write lock (`BEGIN IMMEDIATE`), so it can
    /// lose a race with another process. That failure is not a schema
    /// error: the database is intact and the next attempt can succeed.
    /// The distinction has to be machine-checkable, otherwise every
    /// caller has to re-derive it from the SQLite result code.
    func testALockedDatabaseFailsAsRetryableAndChangesNothing() throws {
        // A database at the base version.
        _ = try SQLiteStorageBackend(databaseURL: dbURL)

        // Connection A: takes the write lock and holds it.
        var lockHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &lockHandle), SQLITE_OK)
        defer { sqlite3_close(lockHandle) }
        XCTAssertEqual(
            sqlite3_exec(lockHandle, "PRAGMA busy_timeout = 100", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(lockHandle, "BEGIN IMMEDIATE", nil, nil, nil),
            SQLITE_OK,
            "precondition: the second connection must be able to take the write lock"
        )

        // Connection B: the one the migrator uses. Its busy timeout is
        // short so the test does not sit through the backend's 5s one.
        var migrateHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &migrateHandle), SQLITE_OK)
        defer { sqlite3_close(migrateHandle) }
        XCTAssertEqual(
            sqlite3_exec(migrateHandle, "PRAGMA busy_timeout = 100", nil, nil, nil),
            SQLITE_OK
        )

        let synthetic = schema(
            version: SQLiteSchema.baseVersion + 1,
            steps: [tableStep(SQLiteSchema.baseVersion + 1, table: "upgrade_probe")]
        )

        XCTAssertThrowsError(
            try SQLiteSchemaMigrator.migrate(db: migrateHandle, schema: synthetic)
        ) { error in
            guard let backendError = error as? StorageBackendError else {
                return XCTFail("expected a StorageBackendError, got \(error)")
            }
            XCTAssertTrue(
                backendError.isRetryable,
                "a lock timeout is transient and must be classified as retryable: \(backendError)"
            )
            if case .storageFailure(_, let code, _) = backendError {
                XCTAssertEqual(code, SQLITE_BUSY, "expected SQLITE_BUSY, got \(code)")
            }
        }

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.baseVersion,
            "a migration that lost the lock race must not have changed anything"
        )

        // Once the lock is released, the retry succeeds.
        XCTAssertEqual(sqlite3_exec(lockHandle, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        _ = try SQLiteStorageBackend(databaseURL: dbURL, schema: synthetic)
        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.baseVersion + 1,
            "the retry after the lock is released must complete the migration"
        )
    }

    /// A failed BASE migration leaves nothing behind either.
    ///
    /// This is the PRODUCTION path: a fresh install creates the whole
    /// schema with the base DDL, and an existing install that predates
    /// the version stamp runs it too. It is not hypothetical — the base
    /// DDL contains `CREATE INDEX ... ON items(is_pinned DESC, created_at
    /// DESC)`, and `IF NOT EXISTS` skips creating a TABLE, not an
    /// INDEX: against an older `items` table with different columns,
    /// that statement fails.
    ///
    /// The base statements are the REAL ones plus one that cannot run,
    /// so the test is discriminating: if a failed statement were
    /// swallowed, every table would survive AND the version would be
    /// stamped — a database that claims to be at the current version
    /// while missing part of the schema.
    func testAFailedBaseMigrationLeavesNothingBehind() throws {
        let broken = schema(
            version: SQLiteSchema.baseVersion + 1,
            steps: [tableStep(SQLiteSchema.baseVersion + 1, table: "upgrade_probe")],
            baseStatements: SQLiteSchema.statements + ["THIS IS NOT SQL;"]
        )

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: dbURL, schema: broken))

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            0,
            "a failed base migration must not stamp the version"
        )
        XCTAssertFalse(
            try tableExists("items", at: dbURL),
            "a failed base migration must not leave the tables it created behind"
        )
        XCTAssertFalse(
            try tableExists("upgrade_probe", at: dbURL),
            "a failed base migration must not run the upgrade steps"
        )
    }

    /// A failed migration must not leave the connection inside an open
    /// transaction.
    ///
    /// An open transaction keeps the write lock, which would block
    /// every other process from touching the file — and nothing in the
    /// failure path would say so.
    func testAFailedMigrationLeavesNoOpenTransaction() throws {
        // A database whose header says "below the base", so the base
        // DDL is what runs.
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        try writeUserVersion(0, at: dbURL)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }

        let broken = schema(
            version: SQLiteSchema.baseVersion + 1,
            baseStatements: [
                "CREATE TABLE IF NOT EXISTS base_probe (id TEXT PRIMARY KEY);",
                "THIS IS NOT SQL;"
            ]
        )

        XCTAssertThrowsError(try SQLiteSchemaMigrator.migrate(db: handle, schema: broken))
        XCTAssertEqual(
            sqlite3_get_autocommit(handle),
            1,
            "a failed migration must not leave the connection in an open transaction"
        )
    }

    /// A step that fails half-way leaves the database EXACTLY as it
    /// was — and a later, working step completes the migration.
    ///
    /// This is what makes "the version is stamped last, inside a
    /// transaction that also holds the DDL" a GUARD rather than a
    /// claim. Two mutations die here:
    /// * drop the transaction ⇒ the first statement of the step
    ///   commits on its own and `half_applied` survives;
    /// * swallow the failed statement (`try` → `try?`) ⇒ the step
    ///   "succeeds", the version gets stamped, and the half-applied
    ///   table survives.
    ///
    /// Both leave the database in a state no later open can tell from
    /// a successful migration.
    func testAFailedStepLeavesTheDatabaseUnchanged() throws {
        // A database at the base version.
        _ = try SQLiteStorageBackend(databaseURL: dbURL)

        // A step whose SECOND statement is not valid SQL.
        let broken = schema(
            version: SQLiteSchema.baseVersion + 1,
            steps: [
                SQLiteSchema.MigrationStep(
                    version: SQLiteSchema.baseVersion + 1,
                    statements: [
                        "CREATE TABLE IF NOT EXISTS half_applied (id TEXT PRIMARY KEY);",
                        "THIS IS NOT SQL;"
                    ],
                    notes: "test step"
                )
            ]
        )

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: dbURL, schema: broken))

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.baseVersion,
            "a failed migration must not stamp the version"
        )
        XCTAssertFalse(
            try tableExists("half_applied", at: dbURL),
            "a failed migration must not leave half of the step behind"
        )
        XCTAssertEqual(
            try readLedger(at: dbURL),
            [SQLiteSchema.baseVersion],
            "a failed step must not be recorded in the ledger"
        )

        // A working step must then complete the migration.
        let fixed = schema(
            version: SQLiteSchema.baseVersion + 1,
            steps: [tableStep(SQLiteSchema.baseVersion + 1, table: "upgrade_probe")]
        )
        _ = try SQLiteStorageBackend(databaseURL: dbURL, schema: fixed)

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.baseVersion + 1,
            "a later, working step must complete the migration"
        )
        XCTAssertTrue(
            try tableExists("upgrade_probe", at: dbURL),
            "the working step must have run"
        )
    }

    /// A database below the target version is migrated UP: the step
    /// runs, its table appears, and the version is stamped.
    ///
    /// This is the heart of N.4. Without it, "the version is
    /// authoritative" would be an untested claim.
    func testUpgradePathAppliesTheSteps() throws {
        // A database at the shipped (base) version.
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        XCTAssertEqual(try readUserVersion(at: dbURL), SQLiteSchema.baseVersion)

        let upgraded = schema(
            version: SQLiteSchema.baseVersion + 1,
            steps: [tableStep(SQLiteSchema.baseVersion + 1, table: "upgrade_probe")]
        )
        _ = try SQLiteStorageBackend(databaseURL: dbURL, schema: upgraded)

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.baseVersion + 1,
            "an upgraded database must carry the new version"
        )
        XCTAssertTrue(
            try tableExists("upgrade_probe", at: dbURL),
            "the upgrade step must have run"
        )
        XCTAssertEqual(
            try readLedger(at: dbURL),
            [SQLiteSchema.baseVersion, SQLiteSchema.baseVersion + 1],
            "the ledger must record every applied version"
        )
    }

    /// An already-current database runs NO step — not even one whose
    /// statements could not survive a second run.
    ///
    /// The probe step inserts a row with a primary key; running it
    /// twice fails. If the driver applied the steps unconditionally,
    /// the second open would throw — so this test fails if the version
    /// guard regresses.
    func testTheUpgradeStepIsNotAppliedTwice() throws {
        let upgraded = schema(
            version: SQLiteSchema.baseVersion + 1,
            steps: [singleShotStep(SQLiteSchema.baseVersion + 1)]
        )

        _ = try SQLiteStorageBackend(databaseURL: dbURL, schema: upgraded)
        // Must not throw: the step must not run a second time.
        _ = try SQLiteStorageBackend(databaseURL: dbURL, schema: upgraded)
        _ = try SQLiteStorageBackend(databaseURL: dbURL, schema: upgraded)

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            SQLiteSchema.baseVersion + 1
        )
        XCTAssertEqual(
            try readLedger(at: dbURL),
            [SQLiteSchema.baseVersion, SQLiteSchema.baseVersion + 1],
            "the ledger must not gain a second row for the same version"
        )
    }

    /// A bumped version whose step was FORGOTTEN is refused — and the
    /// database is left at its old version.
    ///
    /// The failure mode this prevents: the driver stamps version 3 on a
    /// database that only ever received version 2's changes, and every
    /// later open believes the upgrade happened.
    func testAMissingStepIsRefusedAndTheVersionIsNotStamped() throws {
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        let before = try readUserVersion(at: dbURL)

        // Version 3, but only the step for version 2 exists.
        let broken = schema(
            version: SQLiteSchema.baseVersion + 2,
            steps: [tableStep(SQLiteSchema.baseVersion + 1, table: "upgrade_probe")]
        )

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: dbURL, schema: broken)) { error in
            guard let backendError = error as? StorageBackendError,
                  case .storageFailure(_, _, let detail) = backendError else {
                return XCTFail("expected a storageFailure, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("missing"),
                "the error must name the missing step: \(detail)"
            )
        }
        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            before,
            "a refused migration must not stamp a version that was never reached"
        )
    }

    /// A GAP in the step chain is refused.
    ///
    /// The step for version 2 is missing while version 3 has one. The
    /// chain still ENDS on the target version, so the "did we reach the
    /// target" check alone would wave this through — and the database
    /// would silently skip version 2's changes. This test is what pins
    /// the gap check down.
    func testAGapInTheStepChainIsRefused() throws {
        _ = try SQLiteStorageBackend(databaseURL: dbURL)
        let before = try readUserVersion(at: dbURL)

        let gapped = schema(
            version: SQLiteSchema.baseVersion + 2,
            steps: [tableStep(SQLiteSchema.baseVersion + 2, table: "upgrade_probe")]
        )

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: dbURL, schema: gapped))
        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            before,
            "a gapped migration chain must not stamp the target version"
        )
        XCTAssertFalse(
            try tableExists("upgrade_probe", at: dbURL),
            "a refused migration must not have applied any step"
        )
    }

    /// The steps are applied OLDEST FIRST, whatever order they are
    /// listed in.
    func testStepsAreAppliedOldestFirst() throws {
        let base = SQLiteSchema.baseVersion
        let schemaTwo = schema(
            version: base + 2,
            steps: [
                // Deliberately out of order.
                tableStep(base + 2, table: "probe_v3"),
                tableStep(base + 1, table: "probe_v2")
            ]
        )

        _ = try SQLiteStorageBackend(databaseURL: dbURL, schema: schemaTwo)

        XCTAssertTrue(try tableExists("probe_v2", at: dbURL))
        XCTAssertTrue(try tableExists("probe_v3", at: dbURL))
        XCTAssertEqual(
            try readLedger(at: dbURL),
            [base, base + 1, base + 2],
            "the ledger must record the versions in order"
        )
        XCTAssertEqual(try readUserVersion(at: dbURL), base + 2)
    }

    // MARK: - The build-level guards

    /// A schema whose BASE version is not the shipped base is refused.
    ///
    /// The base DDL is never edited after shipping — that is what the
    /// step chain is for. A schema that claims a different base would
    /// leave version 1 unreachable ("I skipped v1"), so no database
    /// could ever be upgraded onto it. The driver refuses it rather
    /// than stamping a version it cannot reach.
    func testASchemaWithAWrongBaseVersionIsRefused() throws {
        let wrongBase = SQLiteSchema.Definition(
            baseVersion: SQLiteSchema.baseVersion + 1,
            version: SQLiteSchema.baseVersion + 1,
            baseStatements: SQLiteSchema.statements,
            baseVersionNotes: SQLiteSchema.baseVersionNotes,
            steps: []
        )

        XCTAssertThrowsError(
            try SQLiteStorageBackend(databaseURL: dbURL, schema: wrongBase)
        ) { error in
            guard let backendError = error as? StorageBackendError,
                  case .storageFailure(_, _, let detail) = backendError else {
                return XCTFail("expected a storageFailure, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("base version"),
                "the error must name the base version as the problem: \(detail)"
            )
        }

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            0,
            "a refused schema must not stamp a version"
        )
    }

    /// A target version SQLite cannot store is refused.
    ///
    /// `PRAGMA user_version` holds a 32-bit signed integer. A build
    /// that asked for more is asking for a version the database cannot
    /// carry — the stamp would be silently truncated, and the database
    /// would claim a version it never reached.
    func testAnOutOfRangeSchemaVersionIsRefused() throws {
        let tooLarge = SQLiteSchema.Definition(
            baseVersion: SQLiteSchema.baseVersion,
            version: Int(Int32.max) + 1,
            baseStatements: SQLiteSchema.statements,
            baseVersionNotes: SQLiteSchema.baseVersionNotes,
            steps: []
        )

        XCTAssertThrowsError(
            try SQLiteStorageBackend(databaseURL: dbURL, schema: tooLarge)
        ) { error in
            guard let backendError = error as? StorageBackendError,
                  case .storageFailure(_, _, let detail) = backendError else {
                return XCTFail("expected a storageFailure, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("outside the range"),
                "the error must say the version is unstorable: \(detail)"
            )
        }

        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            0,
            "a refused schema must not stamp a version"
        )
    }

    /// The migration refuses to run on a connection that is ALREADY in
    /// a transaction.
    ///
    /// The migrator owns its own transaction. Starting one inside
    /// another fails with "cannot start a transaction within a
    /// transaction" — an error that reads like a schema problem
    /// instead of "you called this at the wrong time". The driver
    /// checks up front and says exactly that.
    func testAMigrationOnATransactionalConnectionIsRefused() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil),
            SQLITE_OK,
            "precondition: the connection must be inside a transaction"
        )

        let synthetic = schema(
            version: SQLiteSchema.baseVersion + 1,
            steps: [tableStep(SQLiteSchema.baseVersion + 1, table: "upgrade_probe")]
        )

        XCTAssertThrowsError(
            try SQLiteSchemaMigrator.migrate(db: handle, schema: synthetic)
        ) { error in
            guard let backendError = error as? StorageBackendError,
                  case .storageFailure(_, let code, _) = backendError else {
                return XCTFail("expected a storageFailure, got \(error)")
            }
            XCTAssertEqual(
                code, SQLITE_MISUSE,
                "calling the migrator inside a transaction is a misuse, not a schema problem"
            )
        }

        XCTAssertEqual(
            sqlite3_get_autocommit(handle),
            0,
            "precondition: the caller's transaction must still be open and untouched"
        )
        XCTAssertEqual(
            try readUserVersion(at: dbURL),
            0,
            "a refused migration must not stamp a version"
        )
    }

    /// A broken schema is a PERMANENT failure — not a transient one.
    ///
    /// The retry ladder depends on this distinction: a caller that
    /// retries a permanent failure forever will spin, and a caller
    /// that treats a permanent failure as transient will give up on a
    /// database that would have worked. Only a lock contention
    /// (`SQLITE_BUSY` / `SQLITE_LOCKED`) is worth retrying.
    func testASchemaFailureIsNotRetryable() throws {
        // Version 3 with only the step for version 2 — a broken chain.
        let broken = schema(
            version: SQLiteSchema.baseVersion + 2,
            steps: [tableStep(SQLiteSchema.baseVersion + 1, table: "upgrade_probe")]
        )

        XCTAssertThrowsError(try SQLiteStorageBackend(databaseURL: dbURL, schema: broken)) { error in
            guard let backendError = error as? StorageBackendError else {
                return XCTFail("expected a StorageBackendError, got \(error)")
            }
            XCTAssertFalse(
                backendError.isRetryable,
                "a broken step chain is permanent — retrying it cannot help: \(backendError)"
            )
        }
    }
}
