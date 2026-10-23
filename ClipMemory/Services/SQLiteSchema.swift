//  SQLiteSchema.swift
//  ClipMemory
//
//  The SQLite schema DDL, split out of `SQLiteStorageBackend.swift`.
//
//  ID-CRASH-0022 (2026-10-20): the backend file had reached 1239
//  lines — eleven lines below the SwiftLint `file_length` error
//  ceiling (1250, see .swiftlint.yml). The schema text is ~100 lines
//  of SQL and carries no behaviour, so it lives here instead. This is
//  the same intent as the existing blanket file-length waiver on
//  CryptoService.swift (CRYPTO-LINT-0001) and BackupPackage.swift
//  (BACKUP-0001), but without adding to that debt.
//
//  (The 1239 is the committed line count of the parent of the split —
//  `git show 245c50c^:ClipMemory/Services/SQLiteStorageBackend.swift`
//  — so the next reader can check it rather than take it on faith.)
//
//  Contract: docs/design/storage-migration.md §2.

import Foundation

/// The complete schema for the ClipMemory SQLite store.
///
/// The statements are applied in order by `SQLiteSchemaMigrator`
/// and every one of them is idempotent (`IF NOT EXISTS`), so applying
/// them to an existing database is a no-op.
enum SQLiteSchema {

    // MARK: - Versions

    /// The schema version this build ships.
    ///
    /// ID-REVIEW-1024 (PR-D N.4, 2026-10-21): the version is now
    /// AUTHORITATIVE. It is read from SQLite's own `PRAGMA user_version`
    /// (the database header) and decides which migrations run — the
    /// `schema_version` table is only the human-readable ledger.
    ///
    /// Before this, the version was RECORDED but nothing READ it:
    /// `migrateSchema` decided whether to run by asking whether the
    /// `items` table existed, so an existing database could never be
    /// upgraded to a future schema, and a database written by a NEWER
    /// build was indistinguishable from a current one. That gap — and
    /// the rules that close it — are written up in
    /// docs/design/storage-migration.md §4.4.
    ///
    /// ID-REVIEW-1024 (PR-C, 2026-10-23): version 2 adds the trash
    /// dimension's columns (`deleted_at` / `tag_ids` / `ocr_text` /
    /// `ocr_attempted` / `decryption_failed`, and `expires_at` with a
    /// new meaning) — see `migrationSteps`. The version was bumped
    /// BECAUSE the columns changed: a database that still carried the
    /// v1 `trash_items` shape must be upgraded, not stamped.
    static let version = 2

    /// The version the base DDL below produces.
    ///
    /// The base DDL creates the whole schema in one go, so it is not
    /// an "upgrade" from anything — it is the floor. Upgrade steps
    /// take the schema from `baseVersion + 1` upwards.
    static let baseVersion = 1

    /// Notes recorded for the base schema in the ledger.
    static let baseVersionNotes = "ID-REVIEW-1024 PR-B initial schema"

    // MARK: - Shape

    /// One step of the schema upgrade path: the statements that take
    /// the schema from `version - 1` to `version`.
    struct MigrationStep: Sendable {
        /// The version this step PRODUCES.
        let version: Int
        /// The DDL / DML of the step.
        ///
        /// A step that fails halfway leaves the database at its OLD
        /// version, so the next open re-runs the WHOLE step — every
        /// statement must therefore be safe to re-run. Prefer the
        /// `IF NOT EXISTS` forms; SQLite has no
        /// `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so a column
        /// addition has to recreate the table (or be guarded by the
        /// statement itself).
        let statements: [String]
        /// Recorded in the `schema_version` ledger.
        let notes: String
    }

    /// A whole schema: the base DDL plus the upgrade steps that lead
    /// from the base version to `version`.
    ///
    /// This is a VALUE, not a global: `SQLiteStorageBackend` takes it
    /// as a parameter, so a test can drive the migration driver with a
    /// synthetic schema (a base plus one upgrade step) and prove that
    /// the upgrade path really runs. A driver that only ever sees
    /// `version == 1` with no steps cannot be distinguished from a
    /// driver that ignores the version entirely — the test would be
    /// green either way, i.e. a constant-true guard.
    ///
    /// `Sendable`: the definition is passed into the backend and read
    /// from the init thread; every member is immutable, so the
    /// conformance is free.
    struct Definition: Sendable {
        /// The version the base DDL produces.
        let baseVersion: Int
        /// The version this build expects the database to carry.
        let version: Int
        /// The DDL that creates the base schema.
        let baseStatements: [String]
        /// Notes recorded for the base version.
        let baseVersionNotes: String
        /// The upgrade steps. Must form a contiguous chain from
        /// `baseVersion + 1` to `version`.
        let steps: [MigrationStep]
    }

    /// The schema this build ships.
    static let definition = Definition(
        baseVersion: baseVersion,
        version: version,
        baseStatements: statements,
        baseVersionNotes: baseVersionNotes,
        steps: migrationSteps
    )

    /// The upgrade steps, oldest first.
    ///
    /// ID-REVIEW-1024 (PR-C, 2026-10-23): version 2 is the first
    /// upgrade step. It rebuilds `trash_items` with the columns the
    /// trash dimension needs (docs §11 open question 5): the trash
    /// lost `deletedAt`, `tagIds`, `ocrText` / `ocrAttempted` and
    /// `decryptionFailed` on the way in and out, and `expires_at`
    /// meant "the trash retention deadline" instead of "the item's own
    /// expiry".
    ///
    /// The BASE DDL is deliberately NOT edited: the base version is
    /// never changed after shipping (see
    /// `SQLiteSchemaMigrator.validateBaseVersion`), so a fresh
    /// database creates the v1 shape and then runs this step, exactly
    /// like an existing v1 database does. Both end up at the same
    /// v2 shape — which is the whole point of the version chain.
    static let migrationSteps: [MigrationStep] = [
        MigrationStep(
            version: 2,
            statements: trashItemsV2Upgrade,
            notes: "ID-REVIEW-1024 PR-C: trash_items gains deleted_at / tag_ids / ocr_text / ocr_attempted / decryption_failed"
        )
    ]

    // MARK: - The v1 → v2 trash_items upgrade

    /// The v2 shape of `trash_items`.
    ///
    /// Column order mirrors the `items` table (id, type, is_pinned,
    /// is_encrypted, is_sensitive, decryption_failed, expires_at,
    /// created_at, content_hash, content_blob, ocr_text,
    /// ocr_attempted) with `updated_at` replaced by `deleted_at` and
    /// `tag_ids` added — so the row decoders for the two tables read
    /// alike.
    static let trashItemsV2Table = """
        CREATE TABLE trash_items_v2 (
            item_id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_encrypted INTEGER NOT NULL DEFAULT 1,
            is_sensitive INTEGER NOT NULL DEFAULT 0,
            decryption_failed INTEGER NOT NULL DEFAULT 0,
            expires_at INTEGER,
            created_at INTEGER NOT NULL,
            deleted_at INTEGER NOT NULL,
            content_hash TEXT,
            content_blob TEXT NOT NULL,
            tag_ids TEXT,
            ocr_text TEXT,
            ocr_attempted INTEGER NOT NULL DEFAULT 0
        )
        """

    /// The statements that take `trash_items` from the v1 shape to the
    /// v2 shape.
    ///
    /// SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so
    /// the column additions are done the only way SQLite allows: build
    /// the new table, copy the rows over, drop the old one, rename.
    ///
    /// **Re-runnable**: the step drops a leftover `trash_items_v2`
    /// first, so a second run starts from a clean slate. (The migrator
    /// runs the whole step inside the transaction that also carries
    /// the version stamp, so a failure rolls the DDL back as well and
    /// the next open starts from the v1 shape again.)
    ///
    /// **What the copy maps, and why:**
    /// * `deleted_at` ← the v1 `trashed_at`. That column was the only
    ///   record of WHEN the item was trashed, so it is the honest
    ///   source for the authoritative deletion moment.
    /// * `expires_at` ← NULL. The v1 column held the trash retention
    ///   deadline (`now + 30 days`), which is a PRODUCT policy, not
    ///   the item's own expiry — the v2 column means the item's own
    ///   expiry, exactly like `items.expires_at`. Carrying the old
    ///   value over would make a restored item look expired at a time
    ///   the user never asked for. The retention deadline is no longer
    ///   stored at all: `TrashStore` computes it from `deleted_at`
    ///   and the user's retention setting, which is the only place
    ///   that policy may live.
    /// * `tag_ids` ← `'[]'`, `ocr_text` ← NULL, `ocr_attempted` ← 0,
    ///   `decryption_failed` ← 0: the v1 table had no such columns,
    ///   so there is nothing to carry over. The rows themselves (the
    ///   content, the hash, the type, the flags, the creation time)
    ///   are preserved — that is the data the user would lose.
    static let trashItemsV2Upgrade: [String] = [
        "DROP TABLE IF EXISTS trash_items_v2",
        trashItemsV2Table,
        """
        INSERT INTO trash_items_v2 (
            item_id, type, is_pinned, is_encrypted, is_sensitive,
            decryption_failed, expires_at, created_at, deleted_at,
            content_hash, content_blob, tag_ids, ocr_text, ocr_attempted
        )
        SELECT
            item_id, type, is_pinned, is_encrypted, is_sensitive,
            0, NULL, created_at, trashed_at,
            content_hash, content_blob, '[]', NULL, 0
        FROM trash_items
        """,
        "DROP TABLE trash_items",
        "ALTER TABLE trash_items_v2 RENAME TO trash_items",
        "CREATE INDEX IF NOT EXISTS idx_trash_items_deleted_at ON trash_items(deleted_at)"
    ]

    // MARK: - Ledger

    /// The statement and bindings that record an applied version in
    /// the `schema_version` ledger.
    ///
    /// `INSERT OR IGNORE`: stamping an existing database for the first
    /// time must not fail on the primary key — the row is already
    /// there from the old code path.
    ///
    /// `OR IGNORE` also means the ledger records the FIRST application
    /// of a version: if the same version is ever applied again (a
    /// database whose header was rolled back by hand, say), the row
    /// keeps its ORIGINAL `notes` and `migrated_at`. That is the
    /// intent — the ledger is a history of what happened, not a mirror
    /// of the current notes — but it does mean "notes changed" is not
    /// reflected in the ledger for an already-applied version.
    ///
    /// The values are BOUND, never interpolated into SQL. The version
    /// is bound from the same argument that names it, so the recorded
    /// version and the intended version cannot drift apart.
    static func versionRecord(
        for version: Int,
        notes: String
    ) -> (sql: String, bindings: [(Int32, SQLiteValue)]) {
        (
            sql: """
            INSERT OR IGNORE INTO schema_version (version, migrated_at, notes)
            VALUES (?, datetime('now'), ?)
            """,
            bindings: [(1, .integer(Int64(version))), (2, .text(notes))]
        )
    }

    // MARK: - Base DDL

    /// The DDL, in dependency order: parents before children, so a
    /// foreign key never references a table that does not exist yet.
    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_encrypted INTEGER NOT NULL DEFAULT 1,
            is_sensitive INTEGER NOT NULL DEFAULT 0,
            decryption_failed INTEGER NOT NULL DEFAULT 0,
            expires_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            content_hash TEXT,
            content_blob TEXT NOT NULL,
            ocr_text TEXT,
            ocr_attempted INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_items_pinned_created_at
            ON items(is_pinned DESC, created_at DESC);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_items_expires_at
            ON items(expires_at) WHERE expires_at IS NOT NULL;
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_items_content_hash
            ON items(content_hash);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_items_decryption_failed
            ON items(decryption_failed) WHERE decryption_failed = 1;
        """,
        """
        CREATE TABLE IF NOT EXISTS trash_items (
            -- ID-CRASH-0022 (2026-10-20): deliberately NO foreign
            -- key to items(id). The old
            -- `REFERENCES items(id) ON DELETE CASCADE` deleted the
            -- trash row that §3.3's moveToTrash had just written
            -- (its parent items row is the one being removed);
            -- keeping the FK without the CASCADE fails too,
            -- because §3.3's restore path moves trash → items
            -- precisely because that items row is gone.
            -- Full argument: docs/design/storage-migration.md §2.
            --
            -- ID-REVIEW-1024 (PR-C, 2026-10-23): this is still the V1
            -- shape, and that is deliberate — the base DDL is the
            -- schema as it shipped at version 1 and is never edited
            -- after shipping (the version chain is what carries a
            -- schema forward). The v2 shape — `deleted_at`,
            -- `tag_ids`, `ocr_text`, `ocr_attempted`,
            -- `decryption_failed`, and an `expires_at` that means the
            -- item's own expiry — is created by the v1 → v2 step in
            -- `trashItemsV2Upgrade`. A fresh database runs the base
            -- DDL and then that step, so it ends up with exactly the
            -- same table an upgraded database has.
            item_id TEXT PRIMARY KEY,
            trashed_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            content_blob TEXT NOT NULL,
            content_hash TEXT,
            is_encrypted INTEGER NOT NULL DEFAULT 1,
            type TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_sensitive INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_trash_items_expires_at
            ON trash_items(expires_at);
        """,
        """
        CREATE TABLE IF NOT EXISTS tags (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            color_hex TEXT NOT NULL,
            is_auto INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS item_tags (
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (item_id, tag_id)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_item_tags_tag_id
            ON item_tags(tag_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS app_meta (
            key TEXT PRIMARY KEY,
            value_type TEXT NOT NULL DEFAULT 'blob',
            value BLOB NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            migrated_at TEXT NOT NULL,
            notes TEXT
        );
        """
    ]
}
