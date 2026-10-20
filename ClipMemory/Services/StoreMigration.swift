//
//  StoreMigration.swift
//  ClipMemory
//
//  ID-REVIEW-1024 (PR-B, code-review §八 batch 2): forward migration
//  from UserDefaults blobs to SQLite.
//
//  Trigger: `runOnce` is called by `ClipboardStore` (via `init` or
//  first `loadItems` call, whichever the integration prefers). It
//  checks `migration.v1.to.v2.completed` in the SQLite `app_meta` table
//  and is a no-op if it's already set. On a fresh install with no
//  UserDefaults blobs, the migration still sets the flag — future
//  launches skip the read pass.
//
//  Atomicity: the entire migration runs inside a single SQLite
//  transaction (BEGIN IMMEDIATE ... COMMIT). If any per-item INSERT
//  fails (FK violation, disk-full, etc.), the whole batch rolls back
//  and `migration.v1.to.v2.completed` stays unset — the next launch
//  retries. Per docs §4.3.4 the migration flag is the gate that
//  distinguishes "first launch on new binary" from "subsequent launches".
//
//  Source-blob retention: per docs §4.1 step 6, the migration KEEPS
//  the UserDefaults blobs defensively. Rollback (docs §4.2) needs
//  them. Removing them at migration time would lose the rollback path.
//
//  Schema coverage: items, trash, tags, item_tags junction. Per user
//  hard rule #3 "数据迁移任务必须扫全工件类型" — every artifact
//  type the legacy backend stored gets migrated. Images / OCR are
//  stored on disk by ImageStorage, not in UserDefaults, so they're
//  out of scope for this migration (the SQLiteStorageBackend's image
//  handling will arrive in a later PR).

import Foundation
import os.log

/// ID-REVIEW-1024 (PR-B): forward migration v1 → v2 from UserDefaults
/// blobs to a SQLite backend. Single-shot (guarded by
/// `migration.v1.to.v2.completed` in `app_meta`). Idempotent across
/// launches — second call is a no-op.
enum StoreMigration {
    private static let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "StoreMigration"
    )

    /// Run the migration once. Safe to call multiple times; second
    /// call returns immediately after seeing the completed flag.
    ///
    /// - Parameter source: UserDefaults containing the legacy v1 blobs
    ///   (clipboardItems, ClipMemoryTags, ClipboardTrashedItems).
    /// - Parameter target: SQLiteStorageBackend (or any StorageBackend
    ///   that implements the granular protocol methods — FileStorageBackend
    ///   and MemoryStorageBackend would be no-ops in practice since
    ///   SQLiteStorageBackend is the only one with a real `app_meta`).
    static func runOnce(source: UserDefaults, target: SQLiteStorageBackend) throws {
        // Idempotency gate: skip if completed flag is set.
        if try target.meta(key: "migration.v1.to.v2.completed") != nil {
            return
        }

        try target.beginTransaction()
        do {
            // ID-CRASH-0022 (2026-10-20): tags MUST be migrated before
            // items. `upsertItemInternal` mirrors `item.tagIds` into
            // item_tags, which carries a FOREIGN KEY on tags(id), so an
            // item whose tags are not yet present fails with
            // SQLITE_CONSTRAINT_FOREIGNKEY and aborts the whole batch.
            // The order is a hard dependency, not a preference.
            try migrateTags(source: source, target: target)
            try migrateItems(source: source, target: target)
            try migrateTrash(source: source, target: target)
            // Mark completed — setMeta writes via INSERT OR REPLACE.
            // The `value` is a single byte (1) so callers reading this
            // just need to check non-nil; the type discriminator is
            // 'i64' per the schema convention.
            try target.setMeta(
                key: "migration.v1.to.v2.completed",
                value: Data([0x01]),
                type: "i64"
            )
            try target.commitTransaction()
            Self.logger.info("v1 → v2 migration completed")
        } catch {
            // Rollback so future launches retry. The narrow-catch
            // fix in commit 051be13 only applies to the granular call
            // path; here we want every error to propagate so the
            // migration is atomic.
            // The rollback failure (if any) is logged inside
            // `rollbackTransaction`, which also recovers the
            // connection so later launches do not start inside a
            // dangling transaction. The ORIGINAL migration error is
            // the one the caller needs, so it is what gets rethrown.
            do {
                try target.rollbackTransaction()
            } catch {
                Self.logger.error(
                    "migration rollback failed: \(error.localizedDescription)"
                )
            }
            Self.logger.error("v1 → v2 migration failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Per-artifact migrators

    /// Decode a legacy blob from the source UserDefaults.
    ///
    /// Returns `nil` when the blob is ABSENT (nothing to migrate).
    ///
    /// ID-CRASH-0022 (2026-10-20): a blob that is absent and a blob
    /// that is present but UNREADABLE are different situations, and the
    /// old code conflated them: `try? JSONDecoder().decode(...)` made a
    /// corrupt blob look like "there is nothing to migrate", so the
    /// migration reported success, set the completed flag — and that
    /// batch of history was never migrated, then never migrated again.
    /// Permanent, silent data loss. Now only an absent blob is a
    /// no-op; an unreadable one fails the migration, so the flag stays
    /// unset, the next launch retries, and the cause is logged.
    private static func decodeLegacy<T: Decodable>(
        _ type: T.Type,
        key: String,
        from source: UserDefaults
    ) throws -> [T]? {
        guard let data = source.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            Self.logger.error(
                "legacy blob \(key) is unreadable, refusing to skip it: \(error.localizedDescription)"
            )
            throw error
        }
    }

    private static func migrateItems(
        source: UserDefaults,
        target: SQLiteStorageBackend
    ) throws {
        guard let items = try decodeLegacy(
            ClipboardItem.self,
            key: UserDefaultsKey.clipboardItems.rawValue,
            from: source
        ), !items.isEmpty else {
            return
        }
        // ID-CRASH-0022 (2026-10-20): the legacy layout stored tag
        // membership in ClipboardItem.tagIds and the tag CATALOG in a
        // separate blob, so an item can reference a tag id the catalog
        // does not carry — and item_tags has a FOREIGN KEY on
        // tags(id), so without a parent row the membership INSERT
        // aborts the entire batch (the flag stays unset and every
        // launch retries forever). Placeholder rows keep the membership
        // intact.
        //
        // One batch for the whole migration, not one call per item: the
        // per-item version issued O(items × tags) no-op INSERTs inside
        // the migration transaction.
        let allTagIds = items.reduce(into: Set<UUID>()) { $0.formUnion($1.tagIds) }
        try target.ensureTagPlaceholders(allTagIds)
        for item in items {
            try target.upsertItem(item)
        }
    }

    private static func migrateTags(
        source: UserDefaults,
        target: SQLiteStorageBackend
    ) throws {
        guard let tags = try decodeLegacy(
            Tag.self,
            key: UserDefaultsKey.clipboardTags.rawValue,
            from: source
        ), !tags.isEmpty else {
            return
        }
        for tag in tags {
            try target.upsertTag(tag)
        }
    }

    private static func migrateTrash(
        source: UserDefaults,
        target: SQLiteStorageBackend
    ) throws {
        guard let trashed = try decodeLegacy(
            ClipboardItem.self,
            key: UserDefaultsKey.trashedItems.rawValue,
            from: source
        ), !trashed.isEmpty else {
            return
        }
        for trashItem in trashed {
            // ID-CRASH-0022 (2026-10-20): the old code inserted the
            // snapshot into `items` first, then moved it to trash,
            // because trash_items used to carry `REFERENCES items(id)`.
            // That FK is gone — trash_items is an independent store
            // (docs §3.3) — so `moveToTrash` writes the trash row
            // directly. Dropping the intermediate insert also drops a
            // real bug: it ran `upsertItem`, which mirrors
            // `trashItem.tagIds` into item_tags and so needed those
            // tags to exist.
            try target.moveToTrash(itemID: trashItem.id, trashSnapshot: trashItem)
        }
    }
}
