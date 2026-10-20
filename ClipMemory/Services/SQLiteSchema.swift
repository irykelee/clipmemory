//  SQLiteSchema.swift
//  ClipMemory
//
//  The SQLite schema DDL, split out of `SQLiteStorageBackend.swift`.
//
//  ID-CRASH-0022 (2026-10-20): the backend file had reached 1246 lines
//  — four lines below the SwiftLint `file_length` error ceiling (1250,
//  see .swiftlint.yml). The schema text is ~100 lines of SQL and
//  carries no behaviour, so it lives here instead. This is the same
//  intent as the existing blanket file-length waiver on
//  CryptoService.swift (CRYPTO-LINT-0001) and BackupPackage.swift
//  (BACKUP-0001), but without adding to that debt.
//
//  Contract: docs/design/storage-migration.md §2.

import Foundation

/// The complete schema for the ClipMemory SQLite store.
///
/// The statements are applied in order by
/// `SQLiteStorageBackend.migrateSchema()` and every one of them is
/// idempotent (`IF NOT EXISTS`), so applying them to an existing
/// database is a no-op.
enum SQLiteSchema {

    /// Schema version recorded in the `schema_version` table.
    ///
    /// NOTE (ID-CRASH-0022, 2026-10-20): the version is RECORDED, but
    /// nothing READS it yet — `migrateSchema` decides whether to run
    /// by checking whether the `items` table exists. So an existing
    /// database can never be upgraded to a future schema by this
    /// code. That gap is tracked as the schema-versioning debt in
    /// docs/design/storage-migration.md (open question #4) and must be
    /// closed before the backend carries a second schema version.
    static let version = 1

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
        """,
        """
        INSERT INTO schema_version (version, migrated_at, notes)
        VALUES (1, datetime('now'), 'ID-REVIEW-1024 PR-B initial schema')
        """
    ]
}
