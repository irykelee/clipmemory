//
//  StoreMigration.swift
//  ClipMemory
//
//  ID-REVIEW-1024 (PR-B, code-review §八 batch 2): forward migration
//  from UserDefaults blobs to SQLite.
//
//  Trigger: `runOnce` will be called by `ClipboardStore` once the
//  SQLite backend is wired into production. Today there are ZERO
//  production call sites — only `StoreMigrationTests` drives it (the
//  same "backend currently has zero production call sites" state that
//  CLAUDE.md records). When wiring it in, the `init` throw MUST be
//  routed to a user-visible channel (NSAlert / DiagnosticsBanner), not
//  silently swallowed back to UserDefaults — the obligation is written
//  down in docs/design/storage-migration.md §4.4.1. It checks
//  `migration.v1.to.v2.completed` in the SQLite `app_meta` table
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
    /// The `app_meta` key that records "the v1 → v2 migration ran".
    static let completedFlagKey = "migration.v1.to.v2.completed"

    /// ID-CRASH-0022 (2026-10-20, auto-review P1): the flag is tagged
    /// `'i64'`, and the schema contract (docs/design/storage-migration.md
    /// §2) defines `'i64'` as an **8-byte little-endian signed integer**,
    /// with the read recipe `data.withUnsafeBytes { $0.loadUnaligned(as:
    /// Int64.self) }`. The flag used to be written as `Data([0x01])` — ONE
    /// byte — while tagged `'i64'`. A flag that says "i64" must BE an
    /// i64: the doc's own read recipe traps (`loadUnaligned` on a
    /// 1-byte buffer) for the next reader that follows the contract.
    ///
    /// The value is `1` = "migration completed".
    private static let completedFlagValue: Int64 = 1

    /// Encode an Int64 the way the `'i64'` contract says: 8 bytes,
    /// little-endian.
    private static func encodeI64(_ value: Int64) -> Data {
        withUnsafeBytes(of: value) { Data($0) }
    }

    /// Interpret a stored `app_meta` value as the completed flag.
    ///
    /// - Legacy encoding: the pre-2026-10-20 code wrote the 1-byte
    ///   `Data([0x01])`. It is accepted as "completed" so an existing
    ///   database is not re-migrated (a re-run is destructive — see
    ///   `migrateTrash`).
    /// - Contract encoding: 8-byte little-endian Int64 == 1.
    /// - Anything else (wrong length, wrong value): treated as
    ///   **completed** as well, and logged as an error.
    ///
    ///   The direction matters. The migration reads the LEGACY blobs,
    ///   which the migration deliberately KEEPS (docs §4.1 step 6) — so
    ///   a re-run does not re-import the current state, it re-imports
    ///   the OLD snapshot over it. Re-running on a flag we cannot
    ///   interpret would roll the user's newer data back to the legacy
    ///   one. Skipping is the safe direction: nothing is lost (the
    ///   legacy blobs are still there), and the anomaly is logged. An
    ///   operator who really wants to re-migrate can clear the flag
    ///   deliberately.
    static func isCompletedFlag(_ raw: Data?) -> Bool {
        guard let raw else { return false }
        if raw == Data([0x01]) { return true }
        guard raw.count == MemoryLayout<Int64>.size else {
            Self.logger.error(
                "migration flag '\(completedFlagKey)' has an unexpected length (\(raw.count) bytes) — treating the migration as completed"
            )
            return true
        }
        let value = raw.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        if value != completedFlagValue {
            Self.logger.error(
                "migration flag '\(completedFlagKey)' holds \(value), expected \(completedFlagValue) — treating the migration as completed"
            )
            return true
        }
        return true
    }

    /// The source history, decoded ONCE.
    ///
    /// ID-REVIEW-1027 (2026-11-12, independent verifier round 3 · P2-1):
    /// the mirror used to read the source blobs TWICE — once inside the
    /// migration, once for the verification comparison. Between the two
    /// reads the source can move (the user copies something during the
    /// launch), and the comparison then holds a NEWER source against a
    /// FROZEN copy ⇒ ⇒ a faithful copy is declared "diverged" ⇒ ⇒ a
    /// false banner and a pointless rebuild on the next launch. The
    /// verifier measured it: 4000 items migrated, one added mid-flight,
    /// and the copy was judged divergent even though not one row differed.
    ///
    /// ⇒ ⇒ So the source is decoded ONCE and this snapshot is what BOTH
    /// the migration and the comparison see. They cannot disagree,
    /// because they are looking at the same array.
    struct SourceSnapshot {
        /// The history blob's items.
        let items: [ClipboardItem]
        /// The tag catalog blob's tags.
        let tags: [Tag]
    }

    /// Decode the source history ONCE.
    ///
    /// Throws when a blob is present but UNREADABLE — that is the
    /// ID-CRASH-0022 contract: an unreadable blob must FAIL the
    /// migration, never look like "there is nothing to migrate".
    static func snapshot(from source: UserDefaults) throws -> SourceSnapshot {
        SourceSnapshot(
            items: try decodeLegacy(
                ClipboardItem.self,
                key: UserDefaultsKey.clipboardItems.rawValue,
                from: source
            ) ?? [],
            tags: try decodeLegacy(
                Tag.self,
                key: UserDefaultsKey.clipboardTags.rawValue,
                from: source
            ) ?? []
        )
    }

    static func runOnce(source: UserDefaults, target: SQLiteStorageBackend) throws {
        // Idempotency gate: skip if completed flag is set.
        let rawFlag = try target.meta(key: completedFlagKey)
        if isCompletedFlag(rawFlag) {
            return
        }
        try runOnce(source: source, target: target, snapshot: try snapshot(from: source))
    }

    /// Run the migration against an ALREADY-DECODED source snapshot.
    ///
    /// ID-REVIEW-1027 (2026-11-12, round 3 · P2-1): the caller decodes
    /// the source once and hands the same snapshot to the migration and
    /// to the verification ⇒ ⇒ the two can never disagree about what the
    /// source said at that moment.
    ///
    /// The TRASH blob is deliberately NOT part of the snapshot: it is
    /// read here, inside the migration, exactly as before. It is not part
    /// of the comparison, so reading it separately cannot produce a
    /// TOCTOU — and keeping it out means a trash blob that becomes
    /// unreadable AFTER the migration cannot break the mirror.
    static func runOnce(
        source: UserDefaults,
        target: SQLiteStorageBackend,
        snapshot: SourceSnapshot
    ) throws {
        // Idempotency gate: skip if completed flag is set.
        let rawFlag = try target.meta(key: completedFlagKey)
        if isCompletedFlag(rawFlag) {
            return
        }

        do {
            try target.withTransaction {
                // ID-CRASH-0022 (2026-10-20): the ids that are ALREADY in
                // the items table when the migration starts. On a first run
                // this is empty; on a re-run (the flag was cleared, the
                // operator asked for it) it holds the CURRENT state — and
                // an id in it that also appears in the legacy trash blob is
                // an item the user restored after the last migration.
                // Captured BEFORE `migrateItems`, so the freshly migrated
                // items do not count as "already there".
                let preexistingItemIDs = try target.loadAllIDs()
                // ID-CRASH-0022 (2026-10-20): tags MUST be migrated before
                // items. `upsertItemInternal` mirrors `item.tagIds` into
                // item_tags, which carries a FOREIGN KEY on tags(id), so an
                // item whose tags are not yet present fails with
                // SQLITE_CONSTRAINT_FOREIGNKEY and aborts the whole batch.
                // The order is a hard dependency, not a preference.
                try migrateTags(snapshot.tags, target: target)
                // ID-REVIEW-1027 (2026-11-12, independent verifier round 3 ·
                // P1-1): the TRASH is migrated BEFORE the items, and the order
                // is load-bearing.
                //
                // `moveToTrash` does two things: it writes the trash row AND
                // it DELETEs the row from `items`. With the old order (items
                // first) the item was already in `items` when the trash was
                // imported ⇒ ⇒ the DELETE removed it ⇒ ⇒ the mirror's history
                // lost an item the source still had ⇒ ⇒ the verification said
                // "diverged" ⇒ ⇒ the copy was marked for rebuild ⇒ ⇒ the next
                // launch rebuilt it from the SAME source ⇒ ⇒ the SAME
                // divergence ⇒ ⇒ **forever**: a permanent false divergence, a
                // permanent banner, and a full re-migration on every launch.
                //
                // With the trash imported FIRST, `items` does not hold the
                // row yet ⇒ ⇒ the DELETE is a no-op ⇒ ⇒ an item that is in
                // BOTH blobs ends up in BOTH tables of the mirror ⇒ ⇒ the
                // copy is faithful to the history blob AND to the trash blob
                // ⇒ ⇒ the comparison passes ⇒ ⇒ the self-healing converges.
                //
                // Safe because `trash_items` carries NO foreign key to
                // `items(id)` (deliberate — SQLiteSchema.swift:299) and
                // `upsertTrashItemInternal` writes no `item_tags` row, so the
                // trash import needs neither the items nor the tags.
                try migrateTrash(
                    source: source,
                    target: target,
                    preexistingItemIDs: preexistingItemIDs
                )
                try migrateItems(snapshot.items, target: target)
                // Mark completed — setMeta writes via INSERT OR REPLACE.
                // ID-CRASH-0022 (2026-10-20): the value is now the 8-byte
                // little-endian Int64 the `'i64'` contract requires, not the
                // 1-byte `Data([0x01])` the old code wrote.
                try target.setMeta(
                    key: completedFlagKey,
                    value: encodeI64(completedFlagValue),
                    type: "i64"
                )
            }
            Self.logger.info("v1 → v2 migration completed")
        } catch {
            // The rollback is the transaction scope's job now
            // (ID-REVIEW-1027): withTransaction rolls back on a
            // failure, recovers the connection if the ROLLBACK
            // itself fails, and never lets the rollback error
            // replace the original error. The ORIGINAL migration
            // error is the one the caller needs, so it is what
            // gets rethrown.
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
            // ID-CRASH-0022 (2026-10-20): wrap the raw DecodingError so
            // the KEY NAME travels with the error. The bare
            // `DecodingError` says "the data couldn't be decoded" and
            // nothing about WHICH blob — and the migration touches three
            // of them.
            let detail = "legacy blob \(key) is unreadable: \(error.localizedDescription)"
            Self.logger.error("\(detail) — refusing to skip it")
            throw StorageBackendError.storageFailure(
                sql: "JSONDecoder().decode([\(T.self).self], from: defaults[\(key)])",
                code: -1,
                detail: detail
            )
        }
    }

    private static func migrateItems(
        _ items: [ClipboardItem],
        target: SQLiteStorageBackend
    ) throws {
        guard !items.isEmpty else {
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
        _ tags: [Tag],
        target: SQLiteStorageBackend
    ) throws {
        guard !tags.isEmpty else {
            return
        }
        for tag in tags {
            try target.upsertTag(tag)
        }
    }

    private static func migrateTrash(
        source: UserDefaults,
        target: SQLiteStorageBackend,
        preexistingItemIDs: Set<UUID>
    ) throws {
        guard let trashed = try decodeLegacy(
            ClipboardItem.self,
            key: UserDefaultsKey.trashedItems.rawValue,
            from: source
        ), !trashed.isEmpty else {
            return
        }
        // The ids that must NOT be moved into the trash.
        //
        // ID-REVIEW-1027 (2026-11-12, independent verifier round 3 · P1-1):
        // this set is the ids that were ALREADY in `items` when the
        // migration started (ID-CRASH-0022's original protection — on a
        // re-run, the flag was cleared deliberately, an id that is in the
        // DB and also in the legacy trash blob is an item the user
        // restored, and `moveToTrash` would DELETE its row).
        //
        // It is deliberately NOT "the ids the history blob lists". That
        // was tried first and it is wrong: skipping the trash import for
        // those ids leaves the mirror's TRASH missing rows the source
        // has ⇒ ⇒ the copy is not faithful to the trash blob. The right
        // fix for the dual-blob state is the migration ORDER (trash
        // before items ⇒ `moveToTrash`'s DELETE is a no-op ⇒ ⇒ the item
        // lands in BOTH tables), not a narrower import.
        let restoredIDs = preexistingItemIDs
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
            //
            // ID-CRASH-0022 (2026-10-20, later the same day): `moveToTrash`
            // also DELETEs the item's row from `items`. When the legacy
            // trash blob holds an item that is ALSO in `items` — the
            // user restored it after the last migration, and the legacy
            // blob was never rewritten — the move would delete the
            // restored row. The item would not vanish (it lands in the
            // trash), but it would silently leave the history. So the
            // ids that are already in the history are skipped.
            guard !restoredIDs.contains(trashItem.id) else {
                Self.logger.error(
                    "migration: skipping trash item \(trashItem.id.uuidString) — it is already in the items table (restored after the last migration)"
                )
                continue
            }
            // ID-REVIEW-1024 (PR-C, 2026-10-23): the trash row is
            // written by `moveToTrash` → `upsertTrashItemInternal`,
            // which carries the FULL v2 column set (`deleted_at`,
            // `tag_ids`, `ocr_text`, `ocr_attempted`,
            // `decryption_failed`, and an `expires_at` that means the
            // item's own expiry). The legacy blob's `deletedAt` is
            // the deletion moment, so the migrated rows keep the
            // retention semantics they had in the UserDefaults store;
            // a legacy row without a `deletedAt` falls back to the
            // write moment (documented in `upsertTrashItemInternal`).
            try target.moveToTrash(itemID: trashItem.id, trashSnapshot: trashItem)
        }
    }
}
