# Storage migration design — UserDefaults → SQLite

> **Status**: implemented in stages. PR-A (backend), PR-B (migration), PR-C's trash dimension and PR-D (schema authority) have shipped; **§4.3.5 (the mirror phase) landed 2026-11-12 with ID-REVIEW-1027**. The atomic switch (`migration.v1.to.v2.switched = 1`) and the dual-write phase are still ahead — see §7.

## 1. Motivation

The current storage layer (`FileStorageBackend`, `Services/StorageBackend.swift:51`) writes items / trash / tags as **JSON blobs in UserDefaults**:

- `save(items:)` encodes the whole `[ClipboardItem]` array to a single `Data`, then `defaults.set(data, forKey:)`. Same for trash and tags.
- One UserDefaults key per blob (`clipboardItems`, `clipboardTrashedItems`, `clipMemoryTags`).

This works at current scale (≤10K items, `keepCount ≤ 30` daily backups per audit observation) but has structural limits:

| Limit | Symptom today | Threshold |
|---|---|---|
| Read cost | `load()` decodes the WHOLE blob on every save/load (CLIP-2 mitigates with `saveBlob`) | blob >5MB → visible UI hitch on every keystroke |
| Write contention | `flushPendingSaves()` writes full blobs (whole array encode + set) | history >10K items → write latency 50-200ms |
| Crash window | in-memory UserDefaults cache vs cfprefsd daemon flush (see `StorageBackend.swift:96-119`) | every save has ≤30s daemon-flush window |
| Query model | no partial reads, no index | search / filter / page need full blob decode |

SQLite gives:
- Indexed queries (`WHERE expiresAt < ?`, `WHERE contentHash = ?`)
- Row-level updates (1 item edited → 1 row write, not 10MB blob)
- Crash safety (see §1.1 below)
- Bounded memory footprint for hot reads

### 1.1 Crash-safety argument (replaces the OpenCode-review claim)

The earlier draft said "ACID crash safety (WAL + fsync per commit)". That claim was loose. Here's the precise contract:

- **`PRAGMA journal_mode = WAL`** — write-ahead log records every page mutation in a separate file before flushing the main DB. A reader never blocks a writer.
- **`PRAGMA synchronous = NORMAL`** — the WAL file is `fsync`'d at checkpoint boundaries (every 1000 pages, by default). The main DB file is `fsync`'d on each checkpoint, not on each commit. A process crash can lose up to ~1 checkpoint's worth of uncheckpointed transactions — typically sub-second on macOS with `kCheckpointInterval = 1000`.
- **What this guarantees**: after a crash + restart, every committed transaction is durable; partial transactions roll back automatically.
- **What this does NOT guarantee** (call out honestly per ID-STORE-0016 / ID-CRASH-0007):
  - Asynchronous daemon flush failures (disk-full / permission-denied at SQLite's own fsync): indistinguishable from "not yet flushed" — the data was `COMMIT`'d, the OS may have lost the WAL before fsync landed.
  - Process kill between `COMMIT` return and the WAL fsync: same as above.
- **Compared to UserDefaults**: UserDefaults has an analogous window (cfprefsd daemon flush ~30s, see `StorageBackend.swift:107-118`) but is *also* silent — no error path from `defaults.set`. SQLite at least surfaces `PRAGMA synchronous = FULL` as an opt-in for stronger durability if needed. We're picking NORMAL as the default; FULL is one PRAGMA away if a future audit demands it.

The conservative claim: **SQLite-WAL-NORMAL strictly dominates UserDefaults on crash-safety** because both have a similar async-flush window, but SQLite's is bounded to a checkpoint interval (~seconds) vs cfprefsd's variable daemon interval (could be longer under load). We accept the same trade-off shape that UserDefaults already does — but with smaller window and a clearer upgrade path (`PRAGMA synchronous = FULL`).

## 2. SQLite schema

Single database file at `~/Library/Application Support/ClipMemory/store.sqlite3`. Foreign keys ON, journal = WAL, synchronous = NORMAL.

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;

CREATE TABLE schema_version (
    version    INTEGER PRIMARY KEY,
    migrated_at TEXT    NOT NULL,
    notes      TEXT
);

-- Items: one row per ClipboardItem (active clipboard history).
-- Note: tags are NOT denormalized into items.tag_ids — `item_tags`
-- junction table is the single source of truth; storing both creates
-- a write-time consistency window that has bitten similar designs
-- (see §3.2 for the consequence of dual-write drift).
CREATE TABLE items (
    id              TEXT    PRIMARY KEY,                -- UUID string
    type            TEXT    NOT NULL,                    -- ClipboardItemType raw
    is_pinned       INTEGER NOT NULL DEFAULT 0,
    is_encrypted    INTEGER NOT NULL DEFAULT 1,
    is_sensitive    INTEGER NOT NULL DEFAULT 0,
    decryption_failed INTEGER NOT NULL DEFAULT 0,        -- ID-STORE-0010: per-item decrypt failure flag (sticky)
    expires_at      INTEGER,                            -- unix seconds, NULL = no expiry
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    -- P1 from auto-review: content_hash is nullable because legacy
    -- items (pre-ID-STORE-0010) may not have a hash; migration writes
    -- NULL for them (NOT empty string — NULL and '' behave differently
    -- under unique indexes and IS NOT NULL filters, and the column below
    -- is nullable by design).
    -- P1 clarification (nemotron 2026-10-07): this is NOT a new concern —
    -- ClipboardItem.contentHash is already `String?` with
    -- decodeIfPresent; the column simply mirrors the existing model
    -- semantics.
    content_hash    TEXT,                                -- hex contentHash for dedup; NULL for legacy items
    content_blob    TEXT    NOT NULL,                    -- base64-encoded AES-GCM ciphertext (ClipboardItem.content is `String?`)
    ocr_text        TEXT,                                -- nullable, when OCR was done
    ocr_attempted   INTEGER NOT NULL DEFAULT 0
    -- P0 from auto-review: NO `source_app` column. ClipboardItem has
    -- no source_app field (it stores no bundle id); tracking source app
    -- happens in the AnalyticsLogger, not in the item store. Adding
    -- a dead column would diverge from the model and waste space.
);
CREATE INDEX idx_items_pinned_created_at ON items(is_pinned DESC, created_at DESC);
CREATE INDEX idx_items_expires_at        ON items(expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX idx_items_content_hash       ON items(content_hash);
CREATE INDEX idx_items_decryption_failed ON items(decryption_failed) WHERE decryption_failed = 1;
-- Partial index serves the failure-dashboard query (WHERE decryption_failed = 1).
-- Healthy-item listings scan the table by design — do NOT flip this to a
-- full index without measuring the write amplification on the hot insert path.

-- Trash: SEPARATE table from items, mirroring TrashStore.swift's
-- "trash is its own store" invariant (CLAUDE.md "TrashStore.swift —
-- 回收站单独存储（2026-07-26 抽出；HIGH-1）"). A deleted item moves
-- from items → trash_items via a single atomic transaction; the
-- restore path moves trash_items → items. trash_items rows are
-- auto-purged by retention_days (default 30, configurable via
-- 'trashedItemsRetentionDays' app_meta key).
CREATE TABLE trash_items (
    -- ID-CRASH-0022 (2026-10-20): NO foreign key to items(id).
    --
    -- This line used to read
    --   item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    -- which contradicts §3.3's own moveToTrash sequence:
    --   INSERT INTO trash_items (...) VALUES (...);
    --   DELETE FROM items WHERE id = ?;
    -- The CASCADE deletes the trash row that was just inserted (its
    -- parent items row is the one being removed), so every move-to-trash
    -- ended with an empty trash. Keeping the FK without the CASCADE
    -- does not work either: the FK demands a live parent items row,
    -- but the restore path moves trash → items precisely because that
    -- items row no longer exists.
    --
    -- §3.3 "trash is preserved as a separate store" (the
    -- TrashStore.swift own-store invariant, quoted above) is the
    -- authoritative intent: a trash row is a snapshot with its own
    -- lifecycle, not a child of an items row.
    item_id       TEXT    PRIMARY KEY,
    trashed_at    INTEGER NOT NULL,
    expires_at    INTEGER NOT NULL,
    -- Snapshot of the item content at trash time. The original
    -- items.content_blob may be edited later (image re-encrypt, etc.);
    -- the trash must show what was trashed, not the current item.
    -- TEXT (not BLOB) for the same reason as items.content_blob above.
    content_blob  TEXT    NOT NULL,
    -- P1 from auto-review: nullable (same rationale as items.content_hash:
    -- legacy trash blobs (trashed pre-ID-STORE-0010) have no hash).
    content_hash  TEXT,
    is_encrypted  INTEGER NOT NULL DEFAULT 1,
    type          TEXT    NOT NULL,
    is_pinned     INTEGER NOT NULL DEFAULT 0,
    is_sensitive  INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL
    -- NO source_app (same rationale as items table).
);
CREATE INDEX idx_trash_items_expires_at ON trash_items(expires_at);

CREATE TABLE tags (
    id           TEXT    PRIMARY KEY,
    name         TEXT    NOT NULL,
    color_hex    TEXT    NOT NULL,
    is_auto      INTEGER NOT NULL DEFAULT 0,            -- isAutoSuggested
    created_at   INTEGER NOT NULL
);

-- item_tags: SINGLE source of truth for item ↔ tag membership.
-- item_tags rows are written in the same transaction as the
-- corresponding item upsert; no parallel JSON column to drift from.
CREATE TABLE item_tags (
    item_id  TEXT    NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    tag_id   TEXT    NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
    PRIMARY KEY (item_id, tag_id)
);
CREATE INDEX idx_item_tags_tag_id ON item_tags(tag_id);

-- app_meta: typed key/value store for settings that don't deserve a
-- dedicated column. Each row carries its own type discriminator so
-- callers can detect encoding drift without parsing attempts. The
-- (key) is the only PK; writes to the same key serialize via the
-- SQLite WAL. JSON values are re-validated by the app's own JSONDecoder
-- at read time (no schema versioning needed because each known key's
-- encoding is fixed by the calling code path).
CREATE TABLE app_meta (
    key        TEXT    PRIMARY KEY,
    value_type TEXT    NOT NULL DEFAULT 'blob',   -- 'blob' | 'i64' | 'json'
    value      BLOB    NOT NULL,
    updated_at INTEGER NOT NULL
);
-- value_type binary formats (P2 from auto-review, corrected):
--   'blob'  — raw bytes, opaque to the schema (e.g. serialized Set<String>)
--   'i64'   — 8-byte little-endian signed integer; matches `Int64` natively.
--             Conversion helpers (corrected — `Int64` doesn't have
--             `withUnsafeBytes` directly; use `withUnsafeBytes(of:)` for
--             reading, and `loadUnaligned(as:)` for Data → typed reads
--             since `Data` buffers aren't guaranteed 8-byte aligned):
--               let data = withUnsafeBytes(of: int64Value) { Data($0) }
--               let value = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
--   'json'  — UTF-8 JSON text; identical to 'blob' on the wire but tagged
--             so callers don't need to guess whether to JSONDecoder.

-- Last `updated_at` column: the schema carries this so a future
-- "value too old to trust" check is possible without parsing the
-- value. For now it's informational only; readers don't check it.
-- app_meta key registry (enforced by code, not SQL — keeps the table
-- ID-REVIEW-1022/nemotron clarification: keys like migration.v1.to.v2.* /
-- last*Error* live ONLY in this SQLite table — they are deliberately NOT
-- UserDefaultsKey enum cases (migration state must not survive a rollback
-- that restores the UserDefaults blob).
-- generic). Adding a new key: also add it to `AppMetaKey` enum in
-- the production source so the build catches typos at compile time.
--
--   key                                value_type  description
--   -----------------------------------  ----------  --------------------------------
--   'lastPruneDate'                       'i64'       prune-side telemetry
--   'lastBackupDate'                      'i64'       throttle gate
--   'maxClipboardItems'                   'i64'       cap (replaces `maxClipboardItems`)
--   'keepCount'                           'i64'       retention count (replaces `backupKeepCount`)
--   'safeModeCrashCount'                  'i64'       crash counter
--   'ocrEnabled' / 'ocrPreviewEnabled'    'i64'       toggles
--   'sensitiveClearHours'                 'i64'       auto-clear interval
--   'imageIntegrityScannedMtimes'         'json'      mtime cache (replaces `ImageIntegrity.scannedMtimes`)
--   'trashedItemsRetentionDays'           'i64'       default 30
--   'lastBackupErrorDate' / '…Message'     'i64' / 'blob'
--   'lastPruneErrorDate' / '…Message'     'i64' / 'blob'
--   'excludedBundleIds'                   'json'      serialized Set<String>
--   'migration.v1.to.v2.completed'       'i64'       1 once migration done
```

Schema is **forward-only**: every column either exists from schema version 1 (`PRAGMA user_version = 1` — see §4.4) or is added in a strictly later migration.

## 3. StorageBackend protocol changes

`Services/StorageBackend.swift:6` currently has:
```swift
protocol StorageBackend {
    func load() throws -> [ClipboardItem]
    func save(_ items: [ClipboardItem]) throws
    func loadTags() throws -> [Tag]
    func saveTags(_ tags: [Tag]) throws
    func saveBlob(_ data: Data) throws
}
```

For SQLite we want **granular writes** so callers don't have to pass the whole array. Two design options:

### Option A — extend protocol (recommended)

Add row-level methods alongside the existing ones (keep the array-level ones as a fallback / test seam):

```swift
protocol StorageBackend {
    // existing array-level (kept for tests + atomic snapshot use cases)
    func load() throws -> [ClipboardItem]
    func save(_ items: [ClipboardItem]) throws
    func loadTags() throws -> [Tag]
    func saveTags(_ tags: [Tag]) throws
    func saveBlob(_ data: Data) throws

    // new granular methods (used by SQLite backend; UserDefaults
    // backend throws `unsupportedFeature` so callers fall back to
    // the array-level path)
    func upsertItem(_ item: ClipboardItem) throws
    func upsertTag(_ tag: Tag) throws
    func attachTag(itemID: UUID, tagID: UUID) throws
    func detachTag(itemID: UUID, tagID: UUID) throws
    func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws
    func restoreFromTrash(itemID: UUID) throws
    func hardDeleteItem(id: UUID) throws           -- removes row
    func setMeta(key: String, value: Data, type: String) throws
    func meta(key: String) throws -> Data?
}
```

> **`TrashSnapshot` type note** (P1 from auto-review): the protocol takes `trashSnapshot: ClipboardItem` (NOT a new `TrashSnapshot` type). The signature matches `TrashStore.moveToTrash` today — `ClipboardItem` already carries all fields needed for the trash row (content_blob snapshot, content_hash, type, is_pinned, is_sensitive, is_encrypted, created_at — note: ClipboardItem has NO source_app field; source bundle ids are never persisted per item). The snapshot passed to `moveToTrash(itemID:trashSnapshot:)` MUST carry `deletedAt` already set (the caller sets it; TrashStore does not mutate the snapshot's `deletedAt` — its `var deletedAt` is caller-owned). The SQLite backend snapshots the item at trash time and persists it into `trash_items.content_blob`. No new type needed.

`FileStorageBackend` keeps the array-level methods and **throws** `StorageBackendError.unsupportedFeature` on granular ones (it can't do row-level on UserDefaults). `SQLiteStorageBackend` implements everything.

This keeps existing callers (`ClipboardStore.saveItems`, `loadItems`, `loadTags`, etc.) working via the array-level path; only NEW write paths (the per-keystroke save in `flushPendingSaves`) use granular methods.

### Option B — replace protocol entirely

Too disruptive — touches every test that uses `MemoryStorageBackend`. Option A is strictly additive and lets us flip `ClipboardStore` to granular writes one call site at a time.

### Decision: **Option A**.

### 3.0 New `StorageBackendError` enum (P1 from auto-review)

The granular-method fallback requires an error type that lives in `StorageBackend.swift`, not in `BackupService.swift`'s `BackupError`. The two error enums are separate concerns (storage vs backup); coupling them would create an unwanted cross-module dependency.

> **Forward-looking (P0 clarification):** this enum does NOT exist in the current tree (`StorageBackend.swift` today only defines the protocol + `FileStorageBackend`/`MemoryStorageBackend`). It is introduced by PR-A. Everything below describes the post-PR-A state.

The PR-A diff adds to `StorageBackend.swift`:

```swift
// StorageBackend.swift (new enum, PR-A):
enum StorageBackendError: Error {
    case unsupportedFeature(String)   // message describes which granular op isn't supported by this backend
}
```

`SQLiteStorageBackend` will **never** throw this — granular methods are its primary path. `FileStorageBackend` throws this from every granular method it doesn't implement (it's the static capability signal). `MemoryStorageBackend` will implement granular methods too (PR-A scope) so it doesn't throw this either — the legacy-test seam is array-level.

### 3.1 Fallback strategy (Option A's `StorageBackendError.unsupportedFeature` path)

`ClipboardStore` callers must handle the fallback gracefully — never crash on a `FileStorageBackend` that can't do granular writes. The pattern:

```swift
// ClipboardStore.swift (after PR-C):
func addItem(_ item: ClipboardItem) throws {
    do {
        try backend.upsertItem(item)
        // tag rows are dual-written the same way — see §3.2.1 for the
        // tagID loop (the loop variable there is `tagID`, not `tag.id`).
    } catch StorageBackendError.unsupportedFeature {
        // Fall back to array-level path. This is OK because the legacy
        // FileStorageBackend only throws `unsupportedFeature` from
        // granular methods, never from array-level.
        try saveItems(items + [item])    // array-level round-trip
    }
}
```

Why this is safe:
- `FileStorageBackend.upsertItem(_:)` **always** throws `unsupportedFeature`. It's a *static* capability of the backend type, not a runtime condition.
- The fallback re-reads the full blob (slow but correct) and re-writes it. There's a partial-write window between the granular attempt and the array-level retry — but the granular attempt throws BEFORE any state mutation (`upsertItem` is atomic per row, no half-write), so the retry starts from the unmodified state.
- Granular methods that succeed don't trigger fallback — only `unsupportedFeature` does. So a SQLite backend always uses granular; a UserDefaults backend always uses array. There's no mixed-mode window in normal operation.

### 3.2 `saveBlob` semantics per backend

`saveBlob(_:)` semantics were originally defined for `FileStorageBackend` (whole-blob write) but are ambiguous for a SQLite backend. Per-backend:

| Backend | `saveBlob(_:)` behavior |
|---|---|
| `FileStorageBackend` | **Custom override** (NOT the default protocol extension): decode the JSON to `[ClipboardItem]`, then call `save(_:)`, then run a read-back verification (`defaults.synchronize()` + `defaults.data(forKey:) == data`) before returning. This catches in-memory `set` failures (rare; per ID-CRASH-0007). |
| `SQLiteStorageBackend` | **Throws** `StorageBackendError.unsupportedFeature("saveBlob not supported on SQLite; use upsertItem instead")`. SQLite doesn't store blobs; calling `saveBlob(_:)` here is a programmer error caught at runtime. The only caller that historically used `saveBlob` is `flushPendingSaves`, which PR-C rewrites to use `upsertItem` per item (no more blob path). |
| `MemoryStorageBackend` | Default protocol extension: decode the JSON, replace `_items`. Same as `save(_:)`. |

`SQLiteStorageBackend` overrides the default `saveBlob(_:)` in its own declaration (since protocol extensions can't selectively throw — the default would silently run for everyone). The override is explicit: `func saveBlob(_ data: Data) throws { throw StorageBackendError.unsupportedFeature("saveBlob not supported on SQLite; use upsertItem instead") }`.

> **Note** (P0 from auto-review): the earlier draft said "Default protocol extension" for `FileStorageBackend.saveBlob` — that's wrong. The actual production code overrides with read-back verification (`StorageBackend.swift:120-135`). The table above corrects it. The P0 was "design describes non-existent behavior" — the contract says the behavior is what `FileStorageBackend` ACTUALLY does, not what the default protocol extension says.

`loadTags()` / `saveTags(_:)` keep the same convention — they're array-level (tags have ~100 items max, no granular needed) and work uniformly across backends.

### 3.2.1 Caller migration (PR-C)

`ClipboardStore+Persistence.swift:34`'s `saveItems()` still uses `saveBlob(_:)`. PR-C adds a `backendType` discriminator. The shape below matches the production `ClipboardStore+Persistence.swift:34` signature (`saveItems() throws` — the current production version doesn't take an items param; the caller computes the diff locally):

> **P0 clarification (nemotron 2026-10-07):** the code snippets below call protocol methods that do **not** exist in the current `StorageBackend` protocol (`loadAllIDs`, `beginTransaction`/`commitTransaction`/`rollbackTransaction`, granular ops) — they are **PR-C deliverables**, specified here so PR-C implements them. This document is a design; absence from the current tree is expected, not drift.

```swift
// PR-C: switches the save strategy by backend type. Uses existing
// protocol methods (no new `changedSince` / `loadAllIDs` — those would
// require separate protocol additions, deferred until usage justifies
// the surface growth). Per-item loop is fine at ClipMemory's scale
// (≤10K items per save — far below the per-call cost threshold where
// batch APIs pay off).
func saveItems() throws {
    let items = items                 // current `items` array on this store
    switch backend {
    case is SQLiteStorageBackend:
        // Granular — one row per changed item, with delete-propagation
        // for items present in DB but absent from the new array (see
        // §4.3.2 delete-propagation note).
        let currentIDs = Set(items.map(\.id))
        for item in items {
            try backend.upsertItem(item)
            // P1 from auto-review: ClipboardItem.tagIds is Set<UUID>; the
            // singular attachTag method must be looped per tag id.
            for tagID in item.tagIds {
                try backend.attachTag(itemID: item.id, tagID: tagID)
            }
            // Migration of legacy items (pre-ID-STORE-0010) may have
            // nil contentHash; that's a per-item concern handled in
            // SQLiteStorageBackend.upsertItem, not here.
        }
        let dbIDs = (try backend.loadAllIDs())
        for staleID in dbIDs.subtracting(currentIDs) {
            try backend.hardDeleteItem(id: staleID)
        }
    case let file as FileStorageBackend:
        try file.save(items)                    // array-level, unchanged
    case let mem as MemoryStorageBackend:
        try mem.save(items)                      // array-level, unchanged
    case is MemoryStorageBackend:                // unreachable — covered above
        break
    @unknown default:
        assertionFailure("unknown StorageBackend: \(backend)")
    }
}
```

> **Code-shape note** (P2 from auto-review): `FileStorageBackend.save(_:)` takes `[ClipboardItem]`, NOT `Data`. The earlier draft's `backend.save(serializeToBlob(items))` is the wrong call signature — `Data`-typed input is the `saveBlob(_:)` contract. The corrected pattern above uses `file.save(items)` which preserves the existing array-level contract.

This avoids the `saveBlob` → `unsupportedFeature` exception path on SQLite while keeping `FileStorageBackend`'s blob path working.

> **Telemetry note** (P3 from auto-review): `recordStorageError` (in §4.3.2 example) is **new** — not a reuse of `lastBackupErrorDate`. Storage errors and backup errors are separate telemetry chains. The `lastBackupErrorDate`/`lastBackupErrorMessage` pair is owned by `BackupService`; storage errors get their own pair (`lastStorageErrorDate`/`lastStorageErrorMessage`) under the same `app_meta` pattern.

### 3.3 Trash model — preserved as a separate store

`deleted_at INTEGER` on `items` was rejected by the OpenCode review (concern: split-brain with existing `TrashStore.swift`). Instead, `trash_items` is a separate table mirroring `items` structure (see schema §2 above). The protocol adds `moveToTrash(itemID:trashSnapshot:)` and `restoreFromTrash(itemID:)` methods; the SQLite backend writes both rows in one atomic transaction:

```sql
BEGIN IMMEDIATE TRANSACTION;
  INSERT INTO trash_items (item_id, content_blob, ...) VALUES (...);
  DELETE FROM items WHERE id = ?;
COMMIT;
```

The existing `TrashStore.swift` is rewritten as a thin wrapper over the SQLite backend (no behavior change visible to the UI); its public API (`trashItem(_:)`, `restoreFromTrash(_:)`, `purgeExpiredTrash()`) stays the same.

`FileStorageBackend` continues to use the existing JSON-blob trash (UserDefaults key `ClipboardTrashedItems`). Trash restoration from a `FileStorageBackend` reads from that blob; from a `SQLiteStorageBackend` reads from `trash_items`. Both paths converge on the same `ClipboardItem` shape.

## 4. Migration / rollback paths

### 4.1 Forward migration (UserDefaults → SQLite)

**Triggered by**: app startup, behind a one-shot flag `migration.v1.to.v2.completed`, stored in the SQLite `app_meta` table — **not** in UserDefaults (see the correction note in §4.3.1). First launch after the new binary ships triggers migration.

**Steps** (ID-CRASH-0022, 2026-10-20 — this list now matches the implementation; the earlier draft had items before tags, which cannot work):

1. Open SQLite at `~/Library/Application Support/ClipMemory/store.sqlite3`. If the file doesn't exist, create it at schema version 1 — i.e. `PRAGMA user_version = 1` (the authoritative version lives there, not in the `schema_version` table — see §4.4).
2. Read the `UserDefaults` blobs `ClipboardItems` / `ClipboardTrashedItems` / `ClipMemoryTags`.
3. **Tags first** — for each tag, INSERT into `tags`. `item_tags.tag_id` REFERENCES `tags(id)` with `foreign_keys = ON`, so an item whose tag has not been inserted yet fails the whole batch. The order is a hard dependency, not a preference.
4. **Items next** — for each item, decode JSON → INSERT into `items` (mapping `expiresAt` to unix seconds) and mirror `tagIds: Set<UUID>` into `item_tags`. An item may reference a tag id the legacy tag catalog does not carry; a placeholder tag row (`name = ""`) is created for it so the membership survives instead of aborting the batch.
5. **Trash last** — for each trashed item, write the snapshot into `trash_items` (§3.3 — an independent store, no FK to `items`).
6. Wrap the whole batch in `BEGIN IMMEDIATE TRANSACTION` + `COMMIT`. Single fsync per batch.
7. On success, set `migration.v1.to.v2.completed` and KEEP the UserDefaults blobs (defensive — see rollback).
8. On failure: **roll the transaction back and keep the SQLite file**. The flag is NOT set, so the next launch retries from scratch, and the legacy blobs are never touched. (The earlier draft said "delete the SQLite file" — wrong twice over: it would destroy a partially-migrated store a retry could have completed, and it is not what the implementation does. The destructive path is §4.2's explicit, user-confirmed rollback.)
9. A legacy blob that EXISTS but cannot be decoded is a **failure**, not "there is nothing to migrate": the migration aborts and the flag stays unset. (Treating an unreadable blob as absent made the migration report success over a batch of history that was then silently never migrated — and never migrated again, because the flag said "done".)

> **Not implemented yet — the `validated` flag**: §4.3.1's second-launch dual-read check (`migration.v1.to.v2.validated`, plus `lastMigrationMismatch` / `lastDualReadMismatch`) has **no implementation anywhere in the codebase** — PR-B delivers the one-shot forward migration only. The flag, the divergence check and the banner must land before the atomic switch (§4.3.3) can be trusted; until then `migration.v1.to.v2.validated` must be treated as *absent*, never as *validated*.

### 4.2 Rollback (SQLite → UserDefaults)

**Triggered by**: any SQLite read failure during steady-state (corruption, schema-version mismatch beyond repair, fsync exhaustion, `PRAGMA integrity_check` failure).

Steps:
1. Delete the SQLite file.
2. Clear `migration.v1.to.v2.completed`.
3. Re-open with the existing `FileStorageBackend` (UserDefaults blobs are still present from the migration in step 4.1.6).
4. Surface the rollback via a new `app_meta` row (`lastRollbackReason`) AND a UI banner (`BackupSettingsView`-adjacent slot).

`FileStorageBackend` is **kept forever** as the fallback path — it's the well-tested behavior the app shipped with for 2+ years. SQLite is purely additive.

### 4.3 Dual-read / double-write window (the missing section in the earlier draft)

This is the operational guarantee that the rollback in §4.2 actually works. Per the OpenCode review, the earlier draft stopped at §4.1 + §4.2 without specifying how the two paths stay coherent. Here's the full picture:

| Phase | Time window | Read path | Write path | UserDefaults state | SQLite state |
|---|---|---|---|---|---|
| Pre-migration | v2.9.x and earlier | UserDefaults (array) | UserDefaults (array) | **current** | absent |
| **Dual-read validation** | 1 launch after PR-B ships | UserDefaults + SQLite (both) | UserDefaults only | **current** | mirror copy |
| **Dual-write** | 2 launches after PR-C ships (1 release cycle) | UserDefaults (primary) + SQLite (read-through cache) | **both** | **current** | mirror copy |
| **Atomic switch** | 3rd launch after PR-C ships | SQLite (primary) | SQLite only | **stale copy (keep 2 cycles)** | **current** |
| **Steady state** | ongoing | SQLite | SQLite | (kept as fallback only) | **current** |
| **Rollback** | on SQLite read failure | UserDefaults | UserDefaults | **current** | absent |

### 4.3.1 Dual-read validation phase (PR-B)

The first launch after PR-B migrates the UserDefaults blob into SQLite (§4.1 above). The second launch after PR-B:

1. Reads UserDefaults blob (same as before).
2. Reads SQLite (just migrated).
3. Computes `Set<UUID>` of item ids in each.
4. **If they differ**: rollback to UserDefaults, surface the mismatch via `app_meta('lastMigrationMismatch')`, log to `Diagnostics`. The user sees a UI banner the next time they open Settings.
5. **If they match**: mark `migration.v1.to.v2.validated = 1` (separate flag, stored in `app_meta`). No writes yet.

This catches silent migration bugs (corruption, encoding drift) **before** we trust SQLite as the primary path.

> **Migration flag storage** (P2 from auto-review, corrected): there's exactly ONE migration state flag, `migration.v1.to.v2.completed` (PR-B writes it, stored in **`app_meta`** — NOT in UserDefaults, despite the earlier draft saying so). The dual-read validation flag `migration.v1.to.v2.validated` is **separate** and also lives in **`app_meta`** — same store. The "completed" flag answers "did the migration run?"; the "validated" flag answers "does SQLite match UserDefaults?". Two flags, two questions, one store — `app_meta`. UserDefaults stays out of the migration state machine entirely. Once atomic-switch completes (PR-C-switch), both flags are checked at startup: if SQLite is missing OR `migration.v1.to.v2.validated == 0`, refuse to switch and trigger the rollback path.
>
> **ID-CRASH-0022 (2026-10-20) — status correction**: PR-B does **not** write `migration.v1.to.v2.validated`; the second-launch dual-read check described above is **not implemented** (0 references in the codebase). The clause "PR-B writes it on the second launch" was aspirational. Until it ships, the atomic switch must not be gated on that flag, and `validated` must be read as *absent* rather than *validated*.

### 4.3.2 Dual-write phase (PR-C + 1 release cycle)

`ClipboardStore` writes to **both** backends per `addItem` / `flushPendingSaves`, with explicit compensating semantics for the SQLite-fails path. **Order matters**: `upsertTag` BEFORE `attachTag` because `item_tags.tag_id` REFERENCES `tags.id` with `foreign_keys = ON` — attaching to a non-existent tag throws FK violation. The order below is the only correct order.

```swift
// PR-C: dual-write is atomic on the SQLite side (BEGIN/COMMIT wraps
// all writes to items + item_tags + trash_items in one transaction),
// and BEST-EFFORT on the UserDefaults side (it either succeeds
// entirely or doesn't run at all — the catch block records the error
// and bails without touching UserDefaults). UserDefaults is the
// source of truth during dual-write; SQLite is the mirror.

do {
    // P1 from auto-review: wrap SQLite writes in a transaction so
    // partial failure leaves SQLite consistent (not the UserDefaults-
    // diverged state the earlier draft allowed).
    try sqliteBackend.beginTransaction()
    do {
        try sqliteBackend.upsertItem(item)
        try sqliteBackend.upsertTag(tag)        // FK prerequisite
        try sqliteBackend.attachTag(itemID: item.id, tagID: tag.id)
    } catch {
        try sqliteBackend.rollbackTransaction()
        throw error
    }
    try sqliteBackend.commitTransaction()
} catch {
    // SQLite write failed. Do NOT touch UserDefaults — the
    // split-brain would be worse than a write failure. Surface to
    // app_meta telemetry and bail.
    recordStorageError(message: error.localizedDescription)
    throw error
}
try fileBackend.upsertItem(item)               // throws `StorageBackendError.unsupportedFeature` for granular; caller falls back
```

> **Atomicity note** (P1 from auto-review): SQLite writes are wrapped in `BEGIN`/`COMMIT` so a partial failure (e.g., FK violation on the third insert) rolls back the whole transaction — no half-written state. The fallback window (write SQLite successfully, then crash before UserDefaults write) is bounded to one user action (one `addItem` call).
>
> **Validation**: dual-read divergence check runs **on every launch** during the dual-write phase, not just the second-launch one-shot. `ClipboardStore.init` reads both stores on startup, computes `Set<UUID>` of items in each, and if they differ, sets `app_meta('lastDualReadMismatch') = (timestamp, diff_summary)` and surfaces the UI banner. The PR-B second-launch one-shot (`migration.v1.to.v2.validated = 1`) was a one-time integrity check; per-launch dual-read is the **continuous** integrity check that catches dual-write drift at runtime, not after a release. This closes the P1 gap the earlier draft left open.

Reads go to UserDefaults first (it's the source of truth during dual-write). SQLite reads happen on launch as a warm-up cache only. **One release cycle** of dual-write is required before atomic-switch (the migration risks need real-world soak).

> **Delete propagation** (P2 from auto-review): `ClipboardStore.saveItems(_:)` MUST pass the FULL current `items` array on every flush, not just changed items. The SQLite backend computes a diff and applies `DELETE` for items present in DB but not in the new array (e.g., expired items purged, items deleted via `deleteItem(_:)`). Without this, dual-write produces stale rows on the SQLite side that never get cleaned up. See §3.2.1 caller code — the diff-and-DELETE pass is part of the `case is SQLiteStorageBackend` branch.

### 4.3.3 Atomic switch (PR-C ships with the switch flag, off by default)

Switching is gated by `app_meta('migration.v1.to.v2.switched')` — default 0, flipped to 1 by a separate PR (`PR-C-switch`) **one release cycle after PR-C**:

- `ClipboardStore.init` reads the flag once at launch.
- 0 → use UserDefaults primary, SQLite secondary (dual-write above).
- 1 → use SQLite primary, UserDefaults secondary (mirror reads for rollback safety).
- This is a **build-time decision** (requires a separate release), not a runtime toggle, to keep the migration easy to reason about.

### 4.3.4 Rollback validation during dual-write / atomic-switch

Rollback is a destructive action (deletes the SQLite file). It's gated by:

- **At least one launch** must have completed with `migration.v1.to.v2.validated = 1` (proves the dual-read phase succeeded).
- The SQLite read failure must be **consistent across retries** (3 consecutive failures within 30s, not a single transient fsync miss).
- A UI confirmation prompt: "Storage has fallen back to the legacy backup. Your latest changes may be temporarily hidden. [Keep backup] [Restore SQLite]".

This makes rollback the explicit, last-resort path — never a silent fallback.

### 4.3.5 The mirror phase (PR-C0, shipped 2026-11-12 — ID-REVIEW-1027)

The phase table in §4.3 has a row between "pre-migration" and
"dual-write": **dual-read validation**, whose window is "1 launch after
PR-B ships". This is that phase, and it is what makes the SQLite backend
a production citizen at all — before it, the backend had **zero**
production call sites, which is exactly why §4.4.1's obligation could
not be discharged.

| | read path | write path | UserDefaults state | SQLite state |
|---|---|---|---|---|
| **mirror (this phase)** | UserDefaults | UserDefaults | **current** | **verified copy** |

⇒ ⇒ The user's history **does not move**. The read path, the write path
and the rollback path are all unchanged ⇒ ⇒ the blast radius of any
failure here is **zero for the user's data**: the source blobs are never
modified, and a failed seed leaves the **verification stamp** unset, so
the next launch re-checks the copy from the last good state.

**What runs at launch** (`AppDelegate.applicationDidFinishLaunching`,
background queue, never blocking the launch):

1. open the store at `~/Library/Application Support/ClipMemory/store.sqlite3`
   — a failure here (disk full, permission denied, a corrupt file, a
   store from a newer build) is the `init` failure §4.4.1 talks about;
2. **decode the source ONCE** — the history blob and the tag blob are
   decoded into a single `StoreMigration.SourceSnapshot`;
3. if the migration flag is unset, run the v1 → v2 migration **against that
   snapshot**;
4. **verify the copy**: the mirror's item ids **and content hashes** must
   match the snapshot's, and its tag ids must match the catalog's **∪ the
   ids the items reference** — the migration deliberately creates
   placeholder rows for a referenced tag the catalog does not carry
   (`item_tags` has a FOREIGN KEY on `tags(id)`), and comparing the raw
   id sets would call every faithful copy "diverged". A real mismatch is
   a migration bug, and it is reported rather than swallowed;
5. report every failure to the user-visible channel (banner), never as a
   log line.

⇒ ⇒ **The source is read ONCE, and that is load-bearing** (independent
verifier round 3 · P2-1): the source used to be read TWICE — once by the
migration, once by the comparison — and the source is **live** (the user
copies things while the app runs) ⇒ ⇒ between the two reads it can move ⇒ ⇒
the comparison then held a **newer** source against a **frozen** copy ⇒ ⇒ a
faithful copy was declared "diverged" ⇒ ⇒ a false banner and a pointless
rebuild. The verifier measured it: 4000 items migrated, one added
mid-flight, and the copy was judged divergent even though not one row
differed. ⇒ ⇒ **one snapshot, handed to both** ⇒ ⇒ they cannot disagree.

⇒ ⇒ **The trash migration must not DELETE what the history says is there**
(independent verifier round 3 · P1-1): an item that is in **both** the
history blob and the trash blob (the two legacy blobs are written by two
INDEPENDENT debounce writers, so a kill between the two writes leaves it
in both) went through `moveToTrash` ⇒ ⇒ `moveToTrash` **DELETEs the row
from `items`** ⇒ ⇒ the mirror's history lost an item the source still
had ⇒ ⇒ the verification declared the copy "diverged" ⇒ ⇒ the copy was
marked for rebuild ⇒ ⇒ rebuilt from the **same** source ⇒ ⇒ the **same**
divergence ⇒ ⇒ **forever**: a permanent false divergence, a permanent
banner, and a full re-migration on every launch.

⇒ ⇒ **The fix is the migration ORDER, not a narrower import**: the trash
is imported **before** the items ⇒ ⇒ `items` does not hold the row yet
⇒ ⇒ `moveToTrash`'s DELETE is a no-op ⇒ ⇒ the item lands in **both**
tables ⇒ ⇒ the copy is faithful to the history blob **and** to the trash
blob ⇒ ⇒ the comparison passes ⇒ ⇒ the self-healing really converges.
⇒ ⇒ (Safe because `trash_items` carries **no** foreign key to
`items(id)` — deliberate, see `SQLiteSchema.swift:299` — and
`upsertTrashItemInternal` writes no `item_tags` row, so the trash import
needs neither the items nor the tags.)
⇒ ⇒ ⚠️ the **first** attempt at this fix narrowed the trash import
instead (skip every id the history blob lists) ⇒ ⇒ that leaves the
mirror's **trash** missing rows the source has ⇒ ⇒ the copy is then not
faithful to the trash blob ⇒ ⇒ **the order is the fix; the narrower
import is not.**

⇒ ⇒ **Two stamps and a marker, three different facts** (ID-REVIEW-1027,
independent verifier P1-1 / P2-1):

| state | means | written when |
|---|---|---|
| `migration.v1.to.v2.completed` | the data was **imported** | inside the migration transaction |
| `migration.v1.to.v2.verified` | the copy was **checked** | only after a successful comparison |
| `store.sqlite3.rebuild` (sidecar file) | this copy must be **thrown away and re-seeded** | when the comparison failed |

⇒ the `alreadySeeded` short-circuit needs **both stamps** ⇒ ⇒ a copy that
failed its verification is **re-checked on the next launch** (and the
banner comes back) instead of being quietly accepted forever.

⇒ ⇒ **The check is a ONE-SHOT, and that is deliberate** (independent
verifier P2-1): the mirror is a **frozen snapshot** and the source keeps
moving ⇒ comparing the copy against the *live* source on every launch
would report a divergence after the user's very next copy — a permanent
false alarm with no way out. ⇒ ⇒ so the copy is compared **once**, against
the source **as it was when the migration read it**, and after that it is
a snapshot (the doc's "no dual-write" bullet).

⇒ ⇒ **A failed check discards the copy** (the sidecar marker) ⇒ the next
launch deletes the store file **before opening a connection** and seeds it
again from the CURRENT source ⇒ ⇒ **self-healing**: the failure is
reported once, and the next launch repairs it instead of replaying it
forever. (The wipe cannot happen inside the failing run: the backend has
no `close()`, only `deinit`, and deleting the file under an open
connection turns every later statement into "disk I/O error" — measured.)
⇒ ⇒ ⚠️ **"repairs it" was a claim, not a fact, until round 3**: a
divergence whose CAUSE is on the source side (e.g. the dual-blob item
above) is repaired into the **same** divergence ⇒ ⇒ the self-healing only
converges once the cause is gone ⇒ ⇒ see the P1-1 note above.

⇒ ⇒ **The banner has a recovery leg too**: a successful seed posts
`.storageMirrorRecovered` ⇒ the observer clears `storageMirrorIssue` ⇒ a
banner that outlives its failure would train the user to ignore banners.
⇒ ⇒ **and EVERY path that means "the store is fine" posts it** (round 3 ·
P2-2): the short-circuit path (`.alreadySeeded` — both stamps in place)
used to stay silent ⇒ ⇒ a launch that found the copy already in place
left the banner claiming a fault that no longer existed ⇒ ⇒ the banner
outlived the failure it was reporting.

⇒ ⇒ **The banner state is durable** (independent verifier P1-1):
`mergePendingDiagnostics()` rebuilds `DecryptionDiagnostics` from the
pending-diagnostics queue, and the queue knows nothing about the flags
**observers** set ⇒ rebuilding without carrying them over erased the
storage issue on the next merge — and since the menu-bar app does not
open a window at launch, the failure was usually reported while there
was no window to show it in ⇒ ⇒ the flags are carried over now
(`testMergingPendingDiagnosticsKeepsTheObserverSetFlags`).

**What is deliberately NOT here** — the two things that make this phase
safe rather than a half-built switch:

- **No dual-write.** The mirror is a snapshot of the migration moment,
  not a live replica ⇒ the continuous divergence check belongs to the
  dual-write phase, not here.
- **No switch.** `migration.v1.to.v2.switched` stays 0 ⇒ the atomic
  switch is still a separate release, and the rollback path (UserDefaults
  primary) is untouched.

**The next phase (dual-write)** writes to both stores per flush, with
UserDefaults still primary, and needs the "one owner for the tag
catalog" constraint from §5.6 to hold.

**Honest residuals of this phase** (ID-REVIEW-1027, independent verifier
P2-1 / P2-4 / P2-5 — all recorded rather than quietly dropped):

- **The array-level `save(_:)` still has §5.6's blast radius.** It writes
  every item's `tagIds` into `item_tags`, so a dangling tag id would
  abort the whole batch there too. It is **not reachable today** (the
  trash path uses `saveTrash`, and the migration uses the granular
  methods) ⇒ ⇒ but it **must** be fixed before the atomic switch, when
  this path becomes the fallback. ⇒ **first item on the switch PR's
  checklist.**
- **`SQLiteStorageBackend.swift` sits exactly on SwiftLint's
  `file_length` error threshold (1250 lines).** One more line turns a
  warning into a build failure ⇒ ⇒ any change to that file must either
  stay under the line or come with a split.
- **The verification compares ids, content hashes and tag ids — and
  nothing else.** It does NOT compare per-item tag membership
  (`item_tags`), the item's `content` / `type` / `isPinned` /
  `ocrText` / `decryptionFailed`, or **the recycle-bin dimension** (the
  migration imports it — and since round 3 the copy is faithful to it —
  but **the check does not look at it**) ⇒ ⇒ a migration
  that dropped an item↔tag association or mangled the trash import
  would still pass the check and get the "verified" stamp ⇒ ⇒ the check
  is a **migration smoke test**, not a proof of fidelity ⇒ ⇒ widening
  it belongs with the dual-write phase (where both sides are live and a
  full comparison is affordable). ⇒ ⇒ ⚠️ note the asymmetry: the trash
  dimension is now **imported faithfully** (the order fix above), but it
  is still **unverified** ⇒ ⇒ a future trash-import regression would
  not be caught by the stamp.
- **The diagnostics banner's `dismissed` flag is shared** with the other
  banners (it is only reset by the key-preparation event) ⇒ ⇒ a user who
  dismissed an earlier banner in the same session can miss a later
  storage banner. Low probability (the mirror runs in the first seconds
  of the launch), but it weakens "must be user-visible" slightly ⇒ it
  belongs on the switch PR's checklist too.
- **If the rebuild marker cannot be written, self-healing is impossible.**
  ⇒ ⇒ the marker is a sidecar file next to the store, so writing it needs
  the app-support directory to be writable — which it was, moments
  earlier, because the database in it was just opened and written ⇒ ⇒
  in practice this is nearly unreachable. But if it happens, the copy is
  never discarded ⇒ ⇒ every launch re-verifies it against a source that
  has moved on ⇒ ⇒ the same divergence is replayed, and the diverged
  banner comes back every launch. The failure is logged at `error` level
  (round 3 · P3-2 raised it from `debug`) and the user still sees the
  diverged banner, so it is **not** a silent failure ⇒ ⇒ but the "retry
  succeeds" property is lost ⇒ ⇒ it belongs on the switch PR's checklist
  (where a real fallback path can be added).


### 4.4 Schema evolution

> **ID-REVIEW-1024 (PR-D N.4, 2026-10-21) — the gate is now `PRAGMA user_version`, not the `schema_version` table.**
>
> The draft below said the `schema_version` TABLE is the gate. It was not: the version was *recorded* there and **nothing read it** — `migrateSchema` decided whether to run by asking whether the `items` table existed. An existing database could therefore never be upgraded to a future schema, and a database written by a NEWER build was indistinguishable from a current one. That made every future `ALTER TABLE` a dead end: there was no mechanism to decide *which* migrations to run.
>
> The version now lives in SQLite's own `PRAGMA user_version` (the database header) and is authoritative. The `schema_version` table remains as a **human-readable ledger** of what was applied (it is what a human reads when asking "what happened to this file?"), not as the decision input.

**The rules** (implemented in `ClipMemory/Services/SQLiteSchemaMigrator.swift`):

| Database version | Action |
|---|---|
| `== ` this build's version | nothing to do |
| `<` this build's version | apply the base DDL (if below the base) and every upgrade step above the database's version, then stamp the version |
| `>` this build's version | **REFUSE** — the file was written by a newer build; touching a schema this build does not understand is how databases get corrupted |

**The whole migration runs in ONE transaction** (`BEGIN IMMEDIATE` … `COMMIT`; `ROLLBACK` on any failure). The DDL, the ledger rows and the version stamp commit together or not at all. `PRAGMA user_version` lives in the database header, and the header is written like any other page — so the stamp is transactional too (measured: a `ROLLBACK` puts the old version back, under WAL as well). That is what makes "the version can never disagree with the schema" a property of the implementation rather than a hope.

The version is read **twice**: once without a lock (the common case — the database is already current, and then the migration must not touch the file at all), and once **inside** the transaction, after the write lock has been granted. The second read closes the window in which another process could have changed the version between the first read and the lock.

Four invariants make the upgrade path safe:

1. **The version is stamped in the same transaction as the DDL it describes.** A failed migration therefore leaves the database **exactly** as it was — same version, same schema, no half-applied table (measured: after a `ROLLBACK` the main `.sqlite3` file is byte-for-byte identical, and so is the `-wal` side file; those files *may* differ in other situations, because SQLite rewrites them) — and the next open retries from a clean state. Every statement in a step must still be safe to re-run (`IF NOT EXISTS` forms; SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so a column addition has to recreate the table).
2. **The step chain must be contiguous.** The compiled-in steps must cover `baseVersion + 1 … version` with no gap. A gap would let the database JUMP a version — the missing version's changes would never be applied. **This chain validation is the only thing that catches a gap**: the reachability check in invariant 3 would wave it through, because a chain with a hole still ends on the target version. It therefore runs *before* anything is written.
3. **Never stamp a version that was not reached.** The stamp happens only after the chain has landed exactly on the target version. Stamping a version whose migration never ran is the worst possible outcome: every later open would believe the upgrade happened and skip it forever. (With a contiguous chain the version is always reachable, so the check in the driver is defence in depth rather than the primary guarantee — the primary guarantee is invariant 2.)
4. **A failed step is never swallowed.** A statement that fails aborts the migration; the failure propagates out of `SQLiteStorageBackend.init`. Swallowing it would commit a half-applied step *and* stamp the version — a state no later open can tell from a successful migration. This covers the base DDL as well as the upgrade steps: the base DDL is the production path (a fresh install creates the whole schema with it), and it contains statements that can genuinely fail — `CREATE INDEX IF NOT EXISTS … ON items(is_pinned DESC, created_at DESC)` against an older `items` table with different columns raises "no such column", because `IF NOT EXISTS` skips creating a *table*, not an *index*.

A version bump that forgets its step is caught the first time a database needs migrating — the driver refuses and names the missing version, instead of silently producing a database that is missing a version's changes.

**Adding a schema version** is therefore: add a `SQLiteSchema.MigrationStep` to `SQLiteSchema.migrationSteps`, bump `SQLiteSchema.version`, and make the step's statements idempotent. The base DDL itself is never edited after shipping — that is what the step chain is for. The base version stays at 1 forever; the driver refuses a schema whose base is anything else.

**The chain is validated without materialising the version range.** The obvious check — `Array((baseVersion + 1)…version)` — asks for one element per version, so a typo in the target version (999_999_999) would allocate gigabytes before anything noticed. The driver checks the chain by **count + bounds** instead: `expectedCount` distinct versions, all inside `(baseVersion, version]`, can only *be* the whole range. It allocates nothing. The two agree for `baseVersion < version`; they differ in two places, both towards safety — the new check **rejects** a duplicated version (a set comparison would collapse it), and it **accepts** `baseVersion >= version` (the old range would trap at runtime, and the shipped schema `baseVersion == version == 1` sits exactly in that case). The missing versions are *sampled*, not enumerated — only `expectedCount` versions can be present, so the first gap always falls inside a window of that size. The target version is bounded to `0…Int32.max` (what SQLite can actually store in `PRAGMA user_version`) by the same validation, so an unstorable version is refused **before anything is written** rather than after.

New migrations (`v2 → v3`) use `ALTER TABLE ... ADD COLUMN ...` with a default value, or the recreate-the-table pattern where SQLite has no idempotent form. Never destructive — no `DROP COLUMN`.

**Lock contention is TRANSIENT, schema errors are PERMANENT.** The migration takes a write lock, so it can lose a race with another process; that failure is `SQLITE_BUSY` / `SQLITE_LOCKED`, the database is untouched, and the next attempt can succeed. `StorageBackendError.isRetryable` makes that distinction machine-checkable (it reads the SQLite result code the error already carries) instead of a judgement call repeated at every call site. A caller that wants a retry ladder asks that property.

**WAL caveat (measured, not assumed).** In WAL mode the header change lands in the `-wal` side file first and reaches the main file at the next checkpoint. Another connection still reads the right value (it reads the WAL too), but **copying the `.sqlite3` file without its `-wal` companion yields a database that never received the migration** — and, when the WAL has not been checkpointed, the copy is missing the whole schema, not just the version (measured: `no such table`). Once the WAL *has* been checkpointed, copying the `.sqlite3` alone is correct. Any future backup of the SQLite file must either take the `-wal` file with it or checkpoint first.

### 4.4.1 The obligation when this is wired up (PR-C)

`SQLiteStorageBackend.init` throws — disk full, permission denied, a corrupt file, or **a database written by a newer build**. The third link of the project's "报错 → 重试 → 用户可见" rule is **not** implemented yet, and today it cannot be: the backend has **zero production call sites** (`ClipboardStore` still uses `FileStorageBackend`).

Whoever wires the SQLite backend into production MUST:

1. surface `init`'s failure to the user (NSAlert / DiagnosticsBanner) — **not** a log line;
2. for the "database is newer than this build" case, say so plainly ("请升级 ClipMemory") instead of falling back to the UserDefaults store behind the user's back — a silent fallback would mean the user reading and writing two different sets of data;
3. keep the retry trigger honest: the version stamp is not written on failure, so the next launch retries the migration from the last good state.

Leaving this unwritten is how the obligation disappears with PR-C.

**状态：2026-11-12（ID-REVIEW-1027）—— 本节义务已部分落地，剩余部分挂在原子切换上。**

| 义务 | 状态 | 落地位置 |
|---|---|---|
| 1. init 失败必须**用户可见**（不是一行日志） | ✅ 已落地（**含持久性**） | `StorageMirrorService.seedAndReport` → `.storageMirrorFailed` 通知 → `AppDelegate.storageMirrorFailedObserver` → `DiagnosticsBanner`（`banner.storage.*`）。`NotificationObserverAssertionTests` 的反向断言会盯着这个通知**必须有生产 observer** ⇒ 死通道回不来。⇒ **两处「有通道 ≠ 用户看得到」的坑已补**（独立核验员 P1-1）：① `mergePendingDiagnostics()` 重建诊断结构体时现在**带上**观察者设的字段 ⇒ 否则下一次合并就把横幅状态抹掉（而菜单栏 App 启动时不开窗口 ⇒ 失败发生时通常根本没有窗口可显示）；② 恢复时发 `.storageMirrorRecovered` ⇒ **横幅会消失**，不会一直挂着一条已经修好的故障。 |
| 2. "比本构建新"要说清楚（"请升级 ClipMemory"） | ✅ 已落地（分类层） | `StorageBackendError.databaseFromNewerBuild(foundVersion:supportedVersion:)` 是**独立错误类型**（不是塞在 `storageFailure` 的 detail 里的一句 "newer"）⇒ 展示层可以**按类型**分流，不用字符串匹配。`StorageMirrorService.failureReason(for:)` 把它映射成 `.fromNewerBuild` ⇒ 横幅文案明确写"请升级"。 |
| 3. 重试触发诚实（失败不写版本戳，下次启动重试） | ✅ 已落地（**两个戳 + 一个重建标记**） | **迁移戳** `migration.v1.to.v2.completed` 写在**同一个事务**里 ⇒ 抛错即回滚 ⇒ 戳不落 ⇒ 下次启动重试（`testAFailedSeedLeavesTheFlagUnsetSoTheNextLaunchRetries`）。**校验戳** `migration.v1.to.v2.verified` 独立于迁移戳 ⇒ **只有比对通过才写 1** ⇒ 比对失败写 0 ⇒ 下次启动**重新校验**（`testADivergedCopyIsNotMarkedVerifiedSoTheNextLaunchRetries`）。⇒ 两个戳都齐了才走 `alreadySeeded` 短路 ⇒ ⇒ 「重试诚实」对**抛错**与**校验不通过**两条路径都成立（独立核验员 P1-1 指出原实现只覆盖前者）。⇒ ⇒ **而且重试是能成功的**：校验不过 ⇒ 副本被打上 `store.sqlite3.rebuild` 标记 ⇒ **下次启动先删副本再重建**（删在**开连接之前**，因为后端没有 `close()`）⇒ ⇒ 从**当前**源重新播种并校验 ⇒ ⇒ **一次失败、一次自愈**，而不是把同一次失败每次启动重放一遍（独立核验员 P2-1）。 |
| 2 的**后半句**："不回落到 UserDefaults" | ⏳ 挂在**原子切换**上 | 镜像阶段（§4.3.5）UserDefaults **本来就是**主存储 ⇒ 不存在"回落到另一个数据源" ⇒ 这半句要到 `migration.v1.to.v2.switched = 1` 的那一版才成立 ⇒ 那一版必须把"新库不可读"变成**硬失败**（不许静默回落）。**本节的义务没有消失，只是换了触发条件。** |


**Observer 生命周期（2026-11-13 补）**：本节新加的两个 observer token
（`storageMirrorFailedObserver` / `storageMirrorRecoveredObserver`）走的是仓库
既有的 **leak guard** 模式 —— 每个 `NSObjectProtocol?` token 都必须在**同类**的
`deinit` 里被 `removeObserver` 释放 ⇒ ⇒ 否则那个 token 会比它的 delegate 活得久。
⇒ ⇒ 这条不变量现在由**全族**守卫兜底：`ObserverTokenLifecycleTests` 扫描
`ClipMemory/` 全树，断言**每一个**声明的 observer token 都在**同文件的 `deinit`**
里被释放 ⇒ ⇒ ⇒ 下次再加一个忘了清理的 observer，CI 会当场报红，而不是等下一次
独立审核撞上。⇒ ⇒ ⇒ ⚠️ **不要**把释放放在 `applicationWillResignActive` ——
用户切走再切回，横幅就再也不会出现/消失 ⇒ ⇒ ⇒ ⇒ 那是拿一个泄漏换一个功能缺失。

**守卫加固：释放必须发生在「注册所用的那个」通知中心**（2026-11-13 独立核验
F-1）。第一条不变量只检查「deinit 里有 removeObserver」⇒ ⇒ **不检查是在哪个
中心释放的** ⇒ ⇒ ⇒ 独立核验员把释放改成另一个中心后守卫**仍然绿** ⇒ ⇒ ⇒ ⇒
而 token 会永远留在原中心的派发表里 ⇒ ⇒ ⇒ ⇒ 这不是假想：本仓真的犯过一次同类
错（ID-APP-0002，`sessionDidResignActiveObserver` 注册在 `NotificationCenter.default`
却在 workspace 中心上释放）⇒ ⇒ ⇒ ⇒ 故第二条不变量把「已释放」升级成**配对**：
**同一个 token，必须在它注册时用的那个通知中心上被释放** ⇒ ⇒ ⇒ ⇒ 中心别名
（`let nc = NSWorkspace.shared.notificationCenter`）由守卫**解析后再比较** ⇒ ⇒
无法识别的中心写法**报红而不是放过**（「查不到 ⇒ 报红」）。

**守卫的已知盲区（2026-11-13 实测，不要当成"全覆盖"）**：① 声明写法必须字面命中
`var <name>: NSObjectProtocol?` ⇒ ⇒ 用 typealias / `any NSObjectProtocol?` /
把 token 存进集合 ⇒ ⇒ 守卫**看不见**这个 token；② 移除必须写成
`if let <alias> = <token> { … removeObserver( … ) }` ⇒ ⇒ 换成 `guard let` 或带
嵌套花括号的写法 ⇒ ⇒ 守卫会**报红**（把已正确释放的 token 误报成泄漏）⇒ ⇒ ⇒ ⇒
**这条的失效方向与①③相反**：①③ 是真·假阴性（漏掉真缺陷），② 是**假阳性**
（守卫过窄、误伤）⇒ ⇒ ⇒ ⇒ 代价是误报，不是漏报；③ 守卫按**文件**聚合 deinit body ⇒ ⇒ 同一文件将来
出现第二个带 deinit 的类型时，A 类的 token 可能被 B 类的 deinit「顶账」。
⇒ ⇒ 三条都是**已知残留**，不是"已覆盖" ⇒ ⇒ ⇒ ⇒ 新增 observer 请照抄既有写法
（`var xObserver: NSObjectProtocol?` +
`if let o = xObserver { NotificationCenter.default.removeObserver(o) }`）⇒ ⇒ ⇒ ⇒
这样才在守卫的射程内。

## 5. Concurrency / connection model (SQLite + existing thread constraints)

SQLite + `ClipboardStore` already has a `@MainActor` constraint on its `@Published` properties, plus an `NSLock`-protected inner store (`ClipboardStore.swift:131` per existing architecture). The SQLite backend must fit into this constraint cleanly. Here's the model:

### 5.1 Single-connection architecture (no connection pool)

`SQLiteStorageBackend` holds **one** `sqlite3` connection for the lifetime of the app. SQLite's per-connection serialization gives us a free mutex — every write goes through the same connection, so writes are automatically serialized in the order they're called. No need for an external queue or pool.

**Connection lifecycle**: `init` opens the connection (synchronously, on whatever thread called `init` — typically `@MainActor`); `deinit` closes it. Schema migration runs in `init` (after the connection is open).

### 5.2 Thread usage rule

`SQLiteStorageBackend` is **not** `@MainActor`. Granular methods are called from:
- `@MainActor` callers (UI-driven `addItem`, `flushPendingSaves` debounced to utility queue)
- The save dispatch queue (`DispatchQueue.global(qos: .utility).async`) — same queue `runImageIntegrityScan` already uses
- The load queue (`performLoadWork`'s utility queue)

All three paths hit the same connection. SQLite's `sqlite3_step()` is thread-safe when called from multiple threads **on the same connection** as long as no two threads are inside `step()` simultaneously (per SQLite docs). To enforce that, `SQLiteStorageBackend` wraps each method body in an `NSLock`:

```swift
final class SQLiteStorageBackend: StorageBackend {
    private let lock = NSLock()
    private var db: OpaquePointer?       // sqlite3 *
    init(...) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_open(...)
        sqlite3_exec(self.db, "PRAGMA foreign_keys = ON;", ...)
        // ...
    }
    func upsertItem(_ item: ClipboardItem) throws {
        lock.lock(); defer { lock.unlock() }
        sqlite3_prepare_v2(self.db, ...)
        sqlite3_bind_text(..., item.contentBlob)
        sqlite3_step(...)
    }
}
```

Per-call lock acquisition is ~50ns — well below any UI latency threshold. This is the same pattern as `MemoryStorageBackend` (`StorageBackend.swift:183-184`), so we're not introducing a new threading concept — just applying it to a new backend.

### 5.3 WAL checkpoint + connection lifetime

`sqlite3_wal_checkpoint(db, SQLITE_CHECKPOINT_PASSIVE, ...)` is invoked:
- On `flushPendingSaves` completion (every debounced save — but only if there's pending WAL > 100 pages; `SQLITE_CHECKPOINT_PASSIVE` doesn't block readers)
- On application `applicationWillTerminate` (best-effort; OS may force-kill us before it returns)

The PASSIVE mode doesn't truncate the WAL — it just advances the checkpoint so readers can release old pages. Active truncation is `SQLITE_CHECKPOINT_TRUNCATE` but blocks writers for the duration; we don't need it.

### 5.4 Read concurrency

Multiple readers can hit the same connection simultaneously (SQLite supports this — readers use a shared lock). The `NSLock` around method bodies is **exclusive** which is over-cautious for reads (acknowledged as a deliberate v1 simplification in the auto-review). The cost is that a long `load()` blocks a short `upsertItem()`. For ClipMemory's data size (≤10K items) the load time is ≤50ms; the contention window is negligible.

If profiling later shows contention, the v2 implementation switches to `pthread_rwlock_t` (reader-writer) — `read_lock` for load methods, `write_lock` for upsertItem / moveToTrash / etc. The wire-format of `StorageBackend` doesn't change; it's a backend-internal optimization. For v1 we ship exclusive-only.

### 5.5 ✅ 已修复：事务归属按连接状态推断（ID-REVIEW-1027，2026-11-12）

**状态：2026-10-24 独立审核发现 → 2026-11-12 修复。** 本节不再是"接线前必须解决"的前置条件。

**缺陷（原样保留，供追溯）。** `inTransaction` 用 `isInsideTransaction`（即 `sqlite3_get_autocommit(db) == 0`，**连接级**状态）来判断"调用方是否已经拥有事务"。可是锁是**每次方法调用**级别的：`withLock` 只在单个 public 方法体内持有 `NSRecursiveLock`，`beginTransaction()` 返回后锁就释放了。

于是 `ClipboardStore+Persistence.swift` 里这种写法会留下窗口：

```swift
try backend.beginTransaction()   // ← 持锁 → 释放锁
try backend.upsertItem(...)      // ← 持锁 → 释放锁
try backend.commitTransaction()  // ← 持锁 → 释放锁
```

在 `beginTransaction()` 与 `commitTransaction()` 之间，另一条线程可以进来。它看到 `autocommit == 0`，就以为"调用方拥有事务"，于是走 SAVEPOINT 分支，**把自己的写操作挂进了别人的事务**。后果：

1. 另一线程的写入被外层事务的 COMMIT 一起提交 —— 它自己以为还没提交；
2. 外层事务若走 ROLLBACK（错误路径），另一线程刚刚"成功"返回的写入会**一起被回滚**，看起来像凭空消失；
3. 事务归属没有任何显式记录，日志里也看不出这次写入到底归谁 —— 出事后无法归因。

**修法：把事务收敛成单一持锁作用域（§5.5 修复项 1）。** `SQLiteStorageBackend.withTransaction { … }` 一次持锁完成 BEGIN…COMMIT，**锁覆盖整个事务**：

```swift
func withTransaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    if isInsideTransaction {
        return try runInSavepoint(body)   // 嵌套：SAVEPOINT 隔离
    }
    try exec("BEGIN IMMEDIATE TRANSACTION")
    do {
        let result = try body()
        try exec("COMMIT")
        return result
    } catch {
        do { try rollbackTransaction() } catch { /* 记日志，不替换原错误 */ }
        throw error
    }
}
```

⇒ **修的是形状，不是加一个 flag**：事务开着的时候，**别的线程根本进不来这个后端** ⇒ ⇒ `isInsideTransaction` 只可能因为**本线程**开了事务而为真 ⇒ ⇒ 它要回答的"归属"问题从此有了确定答案。

⇒ **三件套同时落地**（本节原列的"接线前必须做的三件事"）：

1. ✅ 单一持锁作用域 —— `withTransaction { … }`（见上）。旧三件套 `beginTransaction` / `commitTransaction` / `rollbackTransaction` **已删除**（`rollbackTransaction` 降为 private，只有 `withTransaction` 能回滚一个事务）⇒ ⇒ **缺陷形状本身不可达**：没人能再开一个"锁不覆盖全程"的事务。
2. ✅ 并发回归测试 —— `SQLiteStorageBackendRegressionTests.testConcurrentWriteIsNotAbsorbedIntoAnotherThreadsTransaction`（2026-11-12 从 `SQLiteStorageBackendTests` 拆出：加进原文件会让它越过 SwiftLint 的 800 行阈值）：A 线程持事务并回滚，B 线程同时写 ⇒ 断言 B 的写**被提交**（用**第二个连接**读回 —— 只有已提交的行列才对另一个连接可见）且 A 的行没有提交。
3. ✅ 本节与 §4.4.1 的义务在同一轮里同时满足（见 §4.4.1 与 §4.3.5）。

⇒ **调用点已全部迁移**：`granularSave`（`ClipboardStore+Persistence.swift`）与 `StoreMigration.runOnce` 都改用 `withTransaction`；后端内部 7 处 `withLock { inTransaction { … } }` 也一并收敛。

⇒ ⚠️ **这一节的第一版实现并没有兑现上面那段代码**（2026-11-12 全量测试抓出来的，记在这里以免后人重蹈）：第一版的 `withTransaction` **函数体里没有 `lock.lock()`**，但它的**文档注释**已经写着「holding the connection lock for the WHOLE transaction」⇒ ⇒ **注释承诺了、实现没做**。⇒ 全量 `xcodebuild test` 撞出 `testConcurrentUpsertsDoNotCorruptOrLoseRows` 失败，报 `no such savepoint: clipmemory_sp`（另一个线程的 `COMMIT` 把本线程的 savepoint 一起销毁了）⇒ ⇒ 补上 `lock.lock()` / `defer { lock.unlock() }` 之后才真正修好。

⇒ **判别力**（2026-11-12 变异验证，实测）：去掉 `withTransaction` 的 `lock.lock()` ⇒ `testConcurrentWriteIsNotAbsorbedIntoAnotherThreadsTransaction` **变红**（`executed=1` ⇒ 用例确实执行）；未变异时同一用例**绿** ⇒ ⇒ 该用例对「锁是否覆盖全程」**有判别力**，不是「用例会存在」而已。


### 5.6 ✅ 已修复：一条悬空标签引用会作废整次 items 保存（ID-REVIEW-1027，2026-11-12）

**状态：2026-10-24 独立审核发现 → 2026-11-12 修复。** 本节不再是"接线前必须解决"的前置条件。

**缺陷（原样保留，供追溯）。** `ClipboardStore+Persistence.granularSave` 对每个 item 都会 `attachTag(itemID:tagID:)`，但只在 `tags` 目录里**找得到**该 tag 时才 `upsertTag`。标签目录读不出来时（`.tagBackendCorrupted` → `tags = [:]`）而 items blob 带着 tag id，`attachTag` 就会撞上 `item_tags` 的外键约束 → 整个事务回滚 → **用户的整份剪贴板历史这一轮全部保存失败**。

代码里的注释把它称为"the loud failure we want"——**响是响的，但爆炸半径不对**：一个悬空引用本该只影响那一条关联，实际却作废了整次保存。

**修法：缩小失败范围（§5.6 修复项 1）。** `granularSave` 在写之前把 item 的 `tagIds` 过滤成"标签目录里确实存在的"那些，**只跳过那一条关联并记日志**，其余写入照常：

```swift
let attachable = item.tagIds.filter { tags[$0] != nil }
let dangling = item.tagIds.subtracting(attachable)
if !dangling.isEmpty {
    logger.error("ID-REVIEW-1027: skipped \(dangling.count) tag link(s) — the tag catalog does not carry them")
}
var sanitized = item
sanitized.tagIds = attachable
try backend.upsertItem(sanitized)
for tagID in attachable {
    try backend.attachTag(itemID: item.id, tagID: tagID)
}
```

⇒ ⇒ **没有用"无名占位 tag"糊过去**：那会凭空造出一个用户从没创建过的标签，而且后端自己的契约写着"a regular write referencing an unknown tag must fail loudly, not invent a tag"（见 `ensureTagPlaceholders`）⇒ ⇒ 修法落在**调用方**（调用方本来就知道目录里有没有这个 tag），后端的"响"保持不变。

**标签目录的所有者（§5.6 修复项 2）**：镜像阶段（§4.3.5）里 `items` / `tags` / `trash` 三个维度由**同一个** `SQLiteStorageBackend` 实例承载 ⇒ ⇒ 目录只有一个 owner，不存在"两处各写一半"。**双写阶段**（下一轮）落地时，同一条约束继续成立。

**回归测试**：`SQLiteStorageBackendRegressionTests.testOneDanglingTagReferenceDoesNotVoidTheWholeSave`（同上，从 `SQLiteStorageBackendTests` 拆出） —— 标签目录为空 + item 带 tag id ⇒ 断言**其余 item 仍然保存成功**（正是本节要求的断言）。


## 7. Split PR plan (6 PRs over ~2-3 weeks)

Each PR is independently mergeable, independently testable, and ships a working binary. Reversible at any commit because `FileStorageBackend` is always present.

| PR | Scope | LOC estimate | Risk | Reversibility |
|---|---|---|---|---|
| **PR-A: SQLiteStorageBackend skeleton** | New file `Services/SQLiteStorageBackend.swift`. Implements the granular protocol methods. **No callers yet.** Mirrors the array-level methods via SELECT * + rebuild. ~600 LOC. | M | Low — no callers, no behavior change |
| **PR-B: schema_version + migration v1** | New file `Services/StoreMigration.swift`. Implements the one-shot migration from UserDefaults blobs. Sets the `migration.v1.to.v2.completed` flag. ~300 LOC. | M | Low — failure = stay on UserDefaults |
| **PR-C0: mirror phase — first production call site** ✅ **shipped 2026-11-12** | New file `Services/StorageMirrorService.swift`. Opens the SQLite backend at startup, runs the one-shot migration, then does a **one-shot** content comparison against the live UserDefaults source. Writes the second stamp `migration.v1.to.v2.verified`. On divergence: sidecar marker ⇒ **rebuild the copy on the next launch** (delete happens *before* the connection opens). Failures surface via `DiagnosticsBanner` (`.storageMirrorFailed`) with a recovery channel (`.storageMirrorRecovered`). **The read/write path still runs on UserDefaults**; `migration.v1.to.v2.switched` stays `0`. See §4.3.5. | M | Low-Med — read-only mirror; the worst case is "the copy is stale/absent", never "the source is damaged" |
| **PR-C: ClipboardStore per-keystroke writes via granular** | Switch `ClipboardStore.saveItems` / `flushPendingSaves` to use granular methods when backend is `SQLiteStorageBackend`, fall back to array-level for `FileStorageBackend`. ~150 LOC diff. | M-H | Med — touches main-thread hot path; needs per-keystroke instrumentation in tests |
| **PR-D: backup integration** | `BackupService.copyImagesIfPresent` and `BackupPackage` write blobs to the new SQLite format too (add `store.exportToBlobs` and `BackupPackage` consumes the new format on import). Or — simpler — backups keep using their own JSON staging (current behavior); only restore merges via the new backend. ~200 LOC. | L | Low — backups are already independent of storage format |
| **PR-E: UserDefaults deprecation + UI cleanup** | After 2 release cycles with SQLite primary path, demote `FileStorageBackend` to "import-only fallback" with `XCTSkip`-style guard, and remove the array-level `save(_:)` / `saveTags(_:)` path on the SQLite backend (force callers to granular). Also delete the UserDefaults `clipboardItems` etc. blobs from production defaults. ~100 LOC. | M | Med — irreversible (UserDefaults blobs gone) but gated behind 2-cycle soak |

## 8. Test plan

Each PR adds tests covering the scope. Cumulative test count target after PR-E: ~1150 (current 1048 + ~100 new).

> **Count discipline (ID-TEST-0002, 2026-08-16)**: the number above is a **planning target written when the plan was drafted**, not a live fact — the repo has moved well past it. The **only** source of truth for the current count is `./Scripts/test-count.sh` (static estimate) / `./Scripts/test-count.sh --run` (real `Executed N tests`). ⇒ ⇒ do **not** read the "~1150" above as the suite's current size, and do **not** hard-code a count into release notes.

### 8.1 PR-A test scope

- `SQLiteStorageBackendTests` (new file, ~15 tests):
  - `testUpsertItemThenLoadReturnsSameBytes` — round-trip integrity
  - `testUpsertItemUpdatesUpdatedAtColumn` — timestamp semantics
  - `testMoveToTrashPreservesRow` — trash semantics (item gone from items, row in trash_items)
  - `testRestoreFromTrashRemovesTrashRow`
  - `testHardDeleteItemRemovesRow` — actual delete via cascade
  - `testAttachTagPersistsAcrossReload` — junction table
  - `testConcurrentUpsertDoesNotCorrupt` — multi-thread writes (`XCTAssertNoThrow` × N threads × N iterations)
  - `testCorruptDatabaseThrowsOnLoadAndRecoversOnRecreate` — corruption path
  - `testPragmaConfiguration` — verify `foreign_keys=ON`, `journal_mode=WAL`, `synchronous=NORMAL` actually applied
  - `testBulkInsertPerformance` — 10K items in <1s (vs current blob's ~3-5s)
  - `testAtomicityOnCrash` — fork subprocess that writes then SIGKILLs; verify SQLite WAL recovery
  - `testUnsupportedFeatureForGranular` — `FileStorageBackend.upsertItem(_:)` throws `StorageBackendError.unsupportedFeature`

### 8.2 PR-B test scope

- `StoreMigrationTests` (new file, ~8 tests):
  - `testMigrationCopiesAllItems` — round-trip equivalence
  - `testMigrationPreservesTagAttachments` — `item_tags` rows
  - `testMigrationHandlesTrashItems` — `trash_items` populated from `ClipboardTrashedItems` blob
  - `testMigrationIdempotent` — second run with flag set is a no-op
  - `testMigrationFailureKeepsUserDefaults` — injection of failure mid-batch
  - `testMigrationRollbackAfterCorruptSQLite` — corruption → rollback → UserDefaults path
  - `testDualReadValidationPhase` — second-launch dual-read verification catches divergence
  - `testMigrationNotRunOnFreshInstall` — no blobs → no migration

### 8.3 PR-C0 test scope (shipped 2026-11-12)

- `SQLiteStorageBackendRegressionTests` (new file, 2 tests) — the two defects the independent verifier found in the existing backend:
  - `testConcurrentWriteIsNotAbsorbedIntoAnotherThreadsTransaction` — the **transaction-ownership** regression (§5.5): a write issued on one thread must not land inside another thread's transaction. Orchestrated with a **handshake** (not a sleep) so the interleaving is deterministic; every wait is **bounded** (30s) and each party uses its **own** semaphore — a shared counting semaphore had one permit consumed by two waiters, which hung the suite for 6 minutes.
  - `testOneDanglingTagReferenceDoesNotVoidTheWholeSave` — the **blast radius** regression (§5.6): an item carrying a tag id that the catalog does not have must not abort the save of every other item.
- `StorageMirrorServiceTests` (new file, 14 tests) — the mirror phase:
  - the copy is **seeded** from the source and the two stamps land (`completed` + `verified`);
  - a **dangling tag reference in the source** must NOT be read as a divergence (the migration creates a placeholder row for it) — this is the "placeholder-tolerant comparison" rule;
  - an item whose **content hash differs** MUST be read as a divergence;
  - a **diverged copy** must NOT get the verified stamp, and must be **re-checked on the next launch**;
  - a **diverged copy** is **rebuilt on the next launch** (the sidecar marker ⇒ the file is deleted before the connection opens);
  - the **rebuild marker** is not written for a faithful copy;
  - `testSeedDoesNotModifyTheSourceBlobs` asserts the **source blobs** (items + tags + trash) are untouched by the seed ⇒ ⇒ ⚠️ **this is the SOURCE-INTEGRITY assertion, NOT the verification comparison** — the comparison itself (`contentsMatch`) covers **items + tags only**; the recycle-bin dimension is imported by the migration but **not** compared (see §4.3.5's residual). ID-REVIEW-1027 round 3 · P3-1 flagged this sentence as self-contradictory with §4.3.5; it is now unambiguous.
  - a copy that is already seeded needs **both** stamps to short-circuit;
  - **round 3** — an item in **both** the history blob and the trash blob must NOT cause a divergence (the self-healing has to CONVERGE, not replay the same failure on every launch);
  - **round 3** — the source must be read **exactly once** (the migration and the comparison share one snapshot);
  - **round 3** — the `.alreadySeeded` path must ALSO report that the store is healthy (the recovery leg).
- `ClipboardStoreDiagnosticsTests` — `testMergingPendingDiagnosticsKeepsTheObserverSetFlags`: the **durable banner state** (§4.3.5) — `mergePendingDiagnostics()` must carry the observer-set flags (`tagsLoadFailed`, `storageMirrorIssue`) across, or the storage banner is erased by the next merge.
- `LocalizationKeysTests` — `testEveryEnglishKeyExistsInAllSevenLanguageFiles`: a **generic** 7-language guard. (The ledger had claimed this guard existed; it did **not** ⇒ it was written.)
- **Mutation checking — the honest scope** (ID-REVIEW-1027 round 3 · P2-3): the fixes below are mutation-checked, i.e. reverting the fix ⇒ the test must go RED, with `executed ≥ 1` recorded (a skipped test proves nothing) and a byte-identical restore verified afterwards:

  | fix | mutation | test |
  |---|---|---|
  | §5.5 transaction ownership | drop `withTransaction`'s `lock.lock()` | `testConcurrentWriteIsNotAbsorbedIntoAnotherThreadsTransaction` |
  | §5.6 dangling tag | drop the catalog filter | `testOneDanglingTagReferenceDoesNotVoidTheWholeSave` |
  | placeholder-tolerant comparison | compare the raw tag id sets | `testSeedWithADanglingTagReferenceIsNotReportedAsDiverged` |
  | separate verified stamp | the divergence path writes "verified" | `testADivergedCopyIsNotMarkedVerifiedSoTheNextLaunchRetries` |
  | content-hash comparison | delete the whole hash comparison | `testTheCopyComparisonRejectsAnItemWithTheWrongContent` |
  | rebuild marker | never mark the diverged copy | `testADivergedCopyIsRebuiltOnTheNextLaunch` |
  | merge carries the flags | rebuild the diagnostics without them | `testMergingPendingDiagnosticsKeepsTheObserverSetFlags` |
  | 7-language guard | drop a key from `es.lproj` | `testEveryEnglishKeyExistsInAllSevenLanguageFiles` |
  | notification has a consumer | delete the AppDelegate observer | `testEveryCustomNotificationHasAtLeastOneProductionObserver` |
  | failure is posted | `report()` stops posting | `testSeedFailureIsPostedToTheUserVisibleChannel` |
  | `contentsMatch` is real | make it always true | 4 of the mirror tests |
  | **round 3 · P1-1** dual-blob state | move the trash import back AFTER the items (`moveToTrash` deletes the row again) | `testAnItemInBothTheHistoryAndTheTrashBlobDoesNotCauseAPermanentDivergence` |
  | **round 3 · P2-1** one snapshot | read the source a second time | `testTheSourceIsReadOnlyOnceSoTheComparisonSeesTheMigratedSnapshot` |
  | **round 3 · P2-2** recovery leg | drop the `.alreadySeeded` recovery post | `testTheRecoveryNotificationIsPostedEvenWhenTheCopyWasAlreadySeeded` |
  | **round 3** (既有守卫) | drop the "already restored" protection | `testMigrationDoesNotDeleteAlreadyRestoredItems` |

  ⇒ ⇒ **the tests that are NOT in this table** were not individually mutation-checked; they are covered by the table's mutations (a mutation that turns several tests red covers the rest) ⇒ ⇒ **"every new test is mutation-checked" was an overclaim and is withdrawn** (round 3 · P2-3).

### 8.4 PR-C test scope

- Add `testFlushPendingSavesGranularVsArray` to `ClipboardStoreTests`:
  - With `SQLiteStorageBackend`, `flushPendingSaves` writes only the diff (N items updated → N row writes), verified via SQLite write-count metric (not exposed today — would need a wrapper or file-system counter on the SQLite file).
  - With `FileStorageBackend`, `flushPendingSaves` still does the full-blob write (regression).
- Add `testConcurrentFlushPendingSaves` — multi-thread save safety.
- Add `testUnsupportedFeatureFallback` — `ClipboardStore` falls back to array-level when granular throws `unsupportedFeature`.

### 8.5 PR-D test scope

- `SQLiteSchemaVersionTests` (new file, 17 tests) — ID-REVIEW-1024 N.4, the schema version is AUTHORITATIVE (`PRAGMA user_version`), not a row in the `schema_version` table:
  - the version is stamped, and re-opening changes nothing (`testFreshDatabaseIsStampedWithTheSchemaVersion`, `testReopeningAnExistingDatabaseChangesNothing`);
  - an existing database is brought up to the current version (`testUnstampedExistingDatabaseIsStampedOnOpen`);
  - a database from a NEWER build is refused, not downgraded (`testDatabaseFromANewerBuildIsRefused`);
  - the upgrade path really runs (`testUpgradePathAppliesTheSteps`, `testStepsAreAppliedOldestFirst`, `testTheUpgradeStepIsNotAppliedTwice`);
  - a broken chain is refused — missing step and gap alike (`testAMissingStepIsRefusedAndTheVersionIsNotStamped`, `testAGapInTheStepChainIsRefused`);
  - a FAILED migration leaves nothing behind and no open transaction (`testAFailedBaseMigrationLeavesNothingBehind` — the base DDL is the *production* path, `testAFailedMigrationLeavesNoOpenTransaction`, `testAFailedStepLeavesTheDatabaseUnchanged`);
  - the build-level guards (`testASchemaWithAWrongBaseVersionIsRefused`, `testAnOutOfRangeSchemaVersionIsRefused`, `testAMigrationOnATransactionalConnectionIsRefused`);
  - the transient/permanent distinction (`testALockedDatabaseFailsAsRetryableAndChangesNothing` ⇒ `SQLITE_BUSY` is retryable; `testASchemaFailureIsNotRetryable` ⇒ a broken chain is permanent).
- `SQLiteBinderTests` (new file, 8 tests) — the shared `SQLiteValue` binder: text / integer / negative / `Int64.max` / bool / blob / **empty blob is not NULL** / explicit null. The binder is exhaustive by construction, so there is no "unsupported type" branch to test — that is the point of the enum.
- `BackupPackageSQLiteRoundTripTests` (new file, ~6 tests):
  - `testExportReadsFromSQLiteBackend` — backup reads from SQLite via new path
  - `testImportWritesBackToSQLite` — restore path writes via new granular methods
  - `testTrashRoundTripViaSQLite` — backup includes trash_items content snapshot
  - `testBackupImageHardLinkUnaffected` — orthogonal regression (ID-REVIEW-1018)
  - `testTrashRetentionPurgeViaSQLite` — retention_days column drives delete

### 8.6 PR-E test scope

- `LegacyFileStorageBackendRemovalTests`:
  - Verify SQLite is the only registered backend post-removal
  - Verify "panic + roll back to last good SQLite snapshot" path on corruption

### 8.7 Cross-cutting

- All existing tests must continue to pass (1048 tests today, +0 new for the legacy path).
- One new tsan-full weekly job sub-step: run the SQLite backend's concurrent test 50× times and confirm zero races (mirrors the audit pattern from ID-CRASH-0057).
- `BackupServiceExceptionPathTests` ID-REVIEW-1022 follow-up: keep these test cases alive for `FileStorageBackend` even after SQLite primary, because the legacy backend is still reachable via rollback.

## 9. Acceptance criteria (per PR)

**PR-A acceptance**:
- 15 new SQLiteStorageBackend tests pass.
- Existing 1048 tests unchanged (no behavior change in callers).
- `du -k store.sqlite3` shows zero growth when no items added (WAL checkpoint properly runs).
- Concurrency test (PR-A test 6) runs 50× times with zero races.

**PR-B acceptance**:
- 8 new StoreMigration tests pass.
- One-shot migration verified on real `.standard` fixtures (a fixture captured from a v2.9.6 install with 2000 items, 50 tags, 100 image attachments — runs the migration in <5s, content matches bit-for-bit).
- `migration.v1.to.v2.completed` flag is set; second launch is no-op.
- ~~Dual-read validation phase (`migration.v1.to.v2.validated`) succeeds on a fixture with intentional mismatches (verifies the rollback path itself).~~ ⇒ ⇒ **moved to PR-C0** and **renamed**: the flag is `migration.v1.to.v2.verified` (the "validated" name was aspirational and was never implemented — see §4.1 / §4.3.1's ID-CRASH-0022 note).

**PR-C0 acceptance** (shipped 2026-11-12):
- The SQLite backend has **at least one production call site** — `AppDelegate.startStorageMirror()` opens it on a background queue at launch ⇒ ⇒ §4.4.1's obligation is discharged rather than aspirational.
- A store whose `PRAGMA user_version` is **newer than this build** is **refused**, and the refusal is **user-visible** (banner), not a log line (`StorageBackendError.databaseFromNewerBuild`).
- Every init/verification failure is reported through `.storageMirrorFailed` ⇒ ⇒ `DiagnosticsBanner`; **no silent swallow** (§「报错 → 重试 → 用户可见」).
- The verification is **one-shot** (two stamps: `completed` + `verified`); a copy that fails its check is **re-checked on the next launch**, not accepted forever.
- A failed check **self-heals**: the sidecar marker ⇒ the copy is deleted **before the connection opens** on the next launch and re-seeded ⇒ ⇒ the banner does not replay forever.
- The read/write path is **unchanged** (UserDefaults primary); `migration.v1.to.v2.switched` stays `0` ⇒ ⇒ the rollback path is intact.
- The fixes this phase ships are **mutation-checked**: reverting the fix ⇒ the corresponding test goes RED (`executed ≥ 1`, byte-identical restore verified). The exact scope is the table in §8.3 — **"every new test" was an overclaim and is withdrawn** (independent verifier round 3 · P2-3).
- The 7-language L10n guard passes for every new key (`LocalizationKeysTests.testEveryEnglishKeyExistsInAllSevenLanguageFiles`).

**PR-C acceptance**:
- All 1048 prior tests still pass.
- New per-keystroke save reduces median latency (target: <10ms p95 vs current ~30-80ms).
- WAL file size stays bounded (`<10MB` after 1000 saves).
- `testUnsupportedFeatureFallback` exercises both backends in the same test suite.

**PR-D acceptance**:
- Backup round-trip preserves items/trash/tags content byte-for-byte.
- Hard-link image path (ID-REVIEW-1018) unchanged.
- `testTrashRoundTripViaSQLite` shows `trash_items` content blob matches pre-trash `items.content_blob`.

**PR-E acceptance**:
- FileStorageBackend array-level `save(_:)` / `saveTags(_:)` removed.
- UserDefaults blobs deleted on launch when SQLite is active.
- Tests that previously mocked `FileStorageBackend` updated to mock `SQLiteStorageBackend` or use `MemoryStorageBackend`.
- 2 release cycles (v2.10.0 / v2.11.0) of soak prove no rollback needed.

## 10. Out of scope

- **Search index full-text search (FTS5)** — useful but separate PR. SQLite schema has hooks for it (`ocr_text` column already) but the FTS5 virtual table is a separate migration.
- **Network sync** — not in this design.
- **Schema versioning beyond v1 → v2** — future migrations go through `ALTER TABLE`, documented as they land.
- **Encryption at rest** — current AES-GCM per-item encryption (CryptoService) stays the same. The SQLite database file itself is NOT encrypted at rest (Apple sandbox + file permissions `0o600` cover it). If on-disk encryption is later required, SQLCipher is the path — separate design.

## 11. Open questions for review

1. **WAL file rotation policy** — `WAL` grows until checkpoint; default is at 1000 pages. For ClipMemory's ~5-10K item ceiling that's fine. Should we cap at e.g. 200MB? (Proposed: no, audit baseline + this PR's row-level writes keep WAL bounded under 10MB.)

2. **`app_meta` vs separate tables for hot keys** — hot keys like `lastBackupDate` are read on every UI render. Keep them in `app_meta` (cheap key/value) or split into a `kv` table? (Proposed: `app_meta` is fine; SQLite handles single-row reads in microseconds.)

3. **Per-keystroke WAL flush cost** — `synchronous=NORMAL` + WAL gives crash safety with one fsync per commit. For per-keystroke saves, batching N keystrokes into one commit (e.g. via a 50ms debounce in `flushPendingSaves`) reduces WAL pressure. (Proposed: keep current debounce; PR-C tests measure the actual latency impact.)

4. **MemoryStorageBackend semantic** — keep as test-only seam? Or expose a `MemoryStorageBackend` adapter on top of SQLite (`:memory:` pragma) for fast tests? (Proposed: keep the in-memory array backend for tests where SQLite would be overkill; add SQLite-backed memory backend later if needed.)

5. **The trash side is not yet a first-class citizen of the protocol** — **this is a PR-C gate, not a PR-B item.** ID-CRASH-0022 (2026-10-20, opencode review `auto-review-20261020-170730-89948` P1) found that the SQLite trash store does not carry the fields a faithful recycle bin needs:

   | Field | Where it is lost | Consequence if SQLite becomes the trash backend |
   |---|---|---|
   | `deletedAt` | `upsertTrashItemInternal` writes `trashed_at = Date()`; `decodeTrashRow` never reads it back | `purgeExpiredTrash` filters on `deletedAt != nil` ⇒ **nothing would ever expire** ⇒ the retention policy is dead and the bin grows forever |
   | `expires_at` | hardcoded to `now + 30 days`, ignoring the user's `trashRetentionDays` (3/7/14/30) | the stored expiry contradicts the user's setting |
   | `tagIds` | no column; `decodeTrashRow` returns `tagIds = []` | restoring an item silently drops its tag associations |
   | `ocrText` / `ocrAttempted` / `decryptionFailed` | no columns | restoring drops the cached OCR text and the decryption-failed flag |

   The same gap shows up on the protocol side: `StorageBackend` has `moveToTrash` / `restoreFromTrash` but no trash DIMENSION (`loadTrashAll` / `saveTrash` / `purgeTrash`), so `TrashStore` drives the trash through the array-level `load()` / `save(_:)` — which in SQLite terms means "load the MAIN ITEMS as if they were the trash" and "write the trash by deleting every row in `items`".

   ⇒ **PR-C must land both halves together**: the protocol gains a trash dimension, and `trash_items` gains the columns above (at minimum `deleted_at` + `tag_ids`; `ocr_text` / `ocr_attempted` / `decryption_failed` if the trash is to round-trip faithfully). Until then the SQLite backend must NOT be wired to `TrashStore` — the trap is dormant only because PR-B's backend has no production instantiation site.

## 12. Rollout risk summary

| Risk | Mitigation |
|---|---|
| SQLite file corruption on power loss | WAL + `synchronous=NORMAL` survives mid-commit; `PRAGMA integrity_check` at startup recovers to last good snapshot |
| Migration data loss | Migration wraps in `BEGIN IMMEDIATE TRANSACTION`; failure path keeps UserDefaults blobs intact (step 4.1.6); `migration.v1.to.v2.completed` flag is atomic |
| Performance regression on tiny libraries (<100 items) | SQLite per-row overhead ≈ 5µs per write; for <100 items the array-level path is still cheaper — `SQLiteStorageBackend` will only be used when `items.count > 1000` (threshold tunable) |
| Cross-platform SQLite behavior on macOS 13/14/15 | Use only documented-stable SQLite features (no JSON1 extension for v1, FTS5 for later); test on all 3 SDK targets via CI matrix |
| Trash wired to SQLite before the trash dimension exists | §11 open question 5 — `TrashStore` drives the trash through the array-level `load()` / `save(_:)`, which in SQLite terms means "read the main items as the trash" and "write the trash by deleting every row in `items`". PR-C gate: the protocol gains `loadTrashAll` / `saveTrash` / `purgeTrash` AND `trash_items` gains `deleted_at` + `tag_ids` before the backend is wired |

---

**Reviewer checklist** (when this doc is up for review):

- [ ] Schema covers all `ClipboardItem` fields including OCR text + tag attachments
- [ ] Protocol change (Option A) keeps the array-level path intact for tests + fallback
- [ ] Migration is atomic (single SQLite transaction wrapping the whole batch)
- [ ] Rollback is always possible (`FileStorageBackend` retained forever, UserDefaults blobs kept after migration)
- [ ] Per-PR acceptance criteria are objectively measurable (latency target, file size bounds, test counts)
- [ ] Cross-cutting tests (TSan, performance) are part of the plan, not added "later"

If any item is unclear or the design drifts from the actual code-review-2026-10-01 §八 text, flag it on this PR and update the doc.
