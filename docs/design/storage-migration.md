# Storage migration design — UserDefaults → SQLite

> **Status**: design draft, pending user review. Per batch 2 of the code-review-2026-10-01 §八 (storage migration). No code changes yet — this document gates the implementation work.

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
    content_blob    BLOB    NOT NULL,                    -- AES-GCM ciphertext + tag
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
    item_id       TEXT    PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    trashed_at    INTEGER NOT NULL,
    expires_at    INTEGER NOT NULL,
    -- Snapshot of the item content at trash time. The original
    -- items.content_blob may be edited later (image re-encrypt, etc.);
    -- the trash must show what was trashed, not the current item.
    content_blob  BLOB    NOT NULL,
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

Schema is **forward-only**: every column either exists from `schema_version = 1` or is added in a strictly later migration.

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

**Triggered by**: app startup, behind a one-shot `UserDefaults` flag `migration.v1.to.v2.completed` (read once, set true on success). First launch after the new binary ships triggers migration.

**Steps**:
1. Open SQLite at `~/Library/Application Support/ClipMemory/store.sqlite3`. If file doesn't exist, create with schema_version = 1.
2. Read `UserDefaults` blobs for `clipboardItems` / `clipboardTrashedItems` / `clipMemoryTags`.
3. For each item, decode JSON → INSERT into `items` table (mapping `expiresAt` to unix seconds, `tagIds: Set<UUID>` to rows in `item_tags`).
4. For each tag, INSERT into `tags`.
5. Wrap the whole batch in `BEGIN IMMEDIATE TRANSACTION` + `COMMIT`. Single fsync per batch.
6. On success, set `migration.v1.to.v2.completed = true` and KEEP the UserDefaults blobs (defensive — see rollback).
7. On failure, delete the SQLite file (atomic, no corruption) and surface the error to `lastBackupErrorDate`-style machinery (existing pattern, ID-STORE-0016).

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

> **Migration flag storage** (P2 from auto-review, corrected): there's exactly ONE migration state flag, `migration.v1.to.v2.completed` (PR-B writes it, stored in **`app_meta`** — NOT in UserDefaults, despite the earlier draft saying so). The dual-read validation flag `migration.v1.to.v2.validated` (PR-B writes it on the second launch) is **separate** and also lives in **`app_meta`** — same store. The "completed" flag answers "did the migration run?"; the "validated" flag answers "does SQLite match UserDefaults?". Two flags, two questions, one store — `app_meta`. UserDefaults stays out of the migration state machine entirely. Once atomic-switch completes (PR-C-switch), both flags are checked at startup: if SQLite is missing OR `migration.v1.to.v2.validated == 0`, refuse to switch and trigger the rollback path.

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

### 4.4 Schema evolution

`schema_version` table is the gate. New migrations (`v2 → v3`) use `ALTER TABLE ... ADD COLUMN ...` with default value. Never destructive — no `DROP COLUMN`. Documented per-migration in `migrations/` directory:

```
migrations/
├── 001_initial.sql
├── 002_add_ocr_text_index.sql
└── ...
```

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

## 7. Split PR plan (5 PRs over ~2-3 weeks)

Each PR is independently mergeable, independently testable, and ships a working binary. Reversible at any commit because `FileStorageBackend` is always present.

| PR | Scope | LOC estimate | Risk | Reversibility |
|---|---|---|---|---|
| **PR-A: SQLiteStorageBackend skeleton** | New file `Services/SQLiteStorageBackend.swift`. Implements the granular protocol methods. **No callers yet.** Mirrors the array-level methods via SELECT * + rebuild. ~600 LOC. | M | Low — no callers, no behavior change |
| **PR-B: schema_version + migration v1** | New file `Services/StoreMigration.swift`. Implements the one-shot migration from UserDefaults blobs. Sets the `migration.v1.to.v2.completed` flag. ~300 LOC. | M | Low — failure = stay on UserDefaults |
| **PR-C: ClipboardStore per-keystroke writes via granular** | Switch `ClipboardStore.saveItems` / `flushPendingSaves` to use granular methods when backend is `SQLiteStorageBackend`, fall back to array-level for `FileStorageBackend`. ~150 LOC diff. | M-H | Med — touches main-thread hot path; needs per-keystroke instrumentation in tests |
| **PR-D: backup integration** | `BackupService.copyImagesIfPresent` and `BackupPackage` write blobs to the new SQLite format too (add `store.exportToBlobs` and `BackupPackage` consumes the new format on import). Or — simpler — backups keep using their own JSON staging (current behavior); only restore merges via the new backend. ~200 LOC. | L | Low — backups are already independent of storage format |
| **PR-E: UserDefaults deprecation + UI cleanup** | After 2 release cycles with SQLite primary path, demote `FileStorageBackend` to "import-only fallback" with `XCTSkip`-style guard, and remove the array-level `save(_:)` / `saveTags(_:)` path on the SQLite backend (force callers to granular). Also delete the UserDefaults `clipboardItems` etc. blobs from production defaults. ~100 LOC. | M | Med — irreversible (UserDefaults blobs gone) but gated behind 2-cycle soak |

## 8. Test plan

Each PR adds tests covering the scope. Cumulative test count target after PR-E: ~1150 (current 1048 + ~100 new).

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

### 8.3 PR-C test scope

- Add `testFlushPendingSavesGranularVsArray` to `ClipboardStoreTests`:
  - With `SQLiteStorageBackend`, `flushPendingSaves` writes only the diff (N items updated → N row writes), verified via SQLite write-count metric (not exposed today — would need a wrapper or file-system counter on the SQLite file).
  - With `FileStorageBackend`, `flushPendingSaves` still does the full-blob write (regression).
- Add `testConcurrentFlushPendingSaves` — multi-thread save safety.
- Add `testUnsupportedFeatureFallback` — `ClipboardStore` falls back to array-level when granular throws `unsupportedFeature`.

### 8.4 PR-D test scope

- `BackupPackageSQLiteRoundTripTests` (new file, ~6 tests):
  - `testExportReadsFromSQLiteBackend` — backup reads from SQLite via new path
  - `testImportWritesBackToSQLite` — restore path writes via new granular methods
  - `testTrashRoundTripViaSQLite` — backup includes trash_items content snapshot
  - `testBackupImageHardLinkUnaffected` — orthogonal regression (ID-REVIEW-1018)
  - `testTrashRetentionPurgeViaSQLite` — retention_days column drives delete

### 8.5 PR-E test scope

- `LegacyFileStorageBackendRemovalTests`:
  - Verify SQLite is the only registered backend post-removal
  - Verify "panic + roll back to last good SQLite snapshot" path on corruption

### 8.6 Cross-cutting

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
- Dual-read validation phase (`migration.v1.to.v2.validated`) succeeds on a fixture with intentional mismatches (verifies the rollback path itself).

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

## 12. Rollout risk summary

| Risk | Mitigation |
|---|---|
| SQLite file corruption on power loss | WAL + `synchronous=NORMAL` survives mid-commit; `PRAGMA integrity_check` at startup recovers to last good snapshot |
| Migration data loss | Migration wraps in `BEGIN IMMEDIATE TRANSACTION`; failure path keeps UserDefaults blobs intact (step 4.1.6); `migration.v1.to.v2.completed` flag is atomic |
| Performance regression on tiny libraries (<100 items) | SQLite per-row overhead ≈ 5µs per write; for <100 items the array-level path is still cheaper — `SQLiteStorageBackend` will only be used when `items.count > 1000` (threshold tunable) |
| Cross-platform SQLite behavior on macOS 13/14/15 | Use only documented-stable SQLite features (no JSON1 extension for v1, FTS5 for later); test on all 3 SDK targets via CI matrix |

---

**Reviewer checklist** (when this doc is up for review):

- [ ] Schema covers all `ClipboardItem` fields including OCR text + tag attachments
- [ ] Protocol change (Option A) keeps the array-level path intact for tests + fallback
- [ ] Migration is atomic (single SQLite transaction wrapping the whole batch)
- [ ] Rollback is always possible (`FileStorageBackend` retained forever, UserDefaults blobs kept after migration)
- [ ] Per-PR acceptance criteria are objectively measurable (latency target, file size bounds, test counts)
- [ ] Cross-cutting tests (TSan, performance) are part of the plan, not added "later"

If any item is unclear or the design drifts from the actual code-review-2026-10-01 §八 text, flag it on this PR and update the doc.
