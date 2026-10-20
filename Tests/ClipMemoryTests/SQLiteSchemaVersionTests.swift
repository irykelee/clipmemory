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
        steps: [SQLiteSchema.MigrationStep] = []
    ) -> SQLiteSchema.Definition {
        SQLiteSchema.Definition(
            baseVersion: SQLiteSchema.baseVersion,
            version: version,
            baseStatements: SQLiteSchema.statements,
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
}
