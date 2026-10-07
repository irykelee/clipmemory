import Foundation
import os.log

/// ID-REVIEW-1024 (PR-A, code-review-2026-10-01 §八 batch 2): Storage backend
/// protocol for ClipboardStore dependency injection.
///
/// The protocol has TWO layers:
/// - **Array-level** (existing): `load()`, `save(_:)`, `loadTags()`, `saveTags(_:)`,
///   `saveBlob(_:)`. All backends implement these. Used by tests, by
///   `ClipboardStore` for the array-level fallback path, and by
///   `MemoryStorageBackend`/`SQLiteStorageBackend` when the granular
///   path throws `unsupportedFeature` (per docs/design/storage-migration.md
///   §3.2.1).
/// - **Granular** (new in PR-A): `upsertItem(_:)`, `hardDeleteItem(id:)`,
///   `upsertTag(_:)`, `attachTag(itemID:tagID:)`, `detachTag(itemID:tagID:)`,
///   `moveToTrash(itemID:trashSnapshot:)`, `restoreFromTrash(itemID:)`,
///   `loadAllIDs()`, `setMeta(key:value:type:)`, `meta(key:)`. Only
///   backends that can do row-level work implement these. Backends that
///   can't (legacy `FileStorageBackend`) MUST throw
///   `StorageBackendError.unsupportedFeature(_:)` so callers know to
///   fall back to the array-level path.
protocol StorageBackend {
    // MARK: - Array-level (existing, all backends implement)

    /// Loads all stored clipboard items.
    func load() throws -> [ClipboardItem]

    /// Saves the full list of clipboard items.
    func save(_ items: [ClipboardItem]) throws

    /// Loads all stored tags. Default impl returns empty — backends that don't
    /// support tags (or test backends that don't care) can rely on this.
    func loadTags() throws -> [Tag]

    /// Saves the full list of tags. Default impl no-ops; mirrors `loadTags()`.
    func saveTags(_ tags: [Tag]) throws

    /// Saves a pre-encoded JSON blob of the item list. CLIP-2 (2026-07-24):
    /// lets ClipboardStore run `JSONEncoder.encode` off the calling thread and
    /// hand only the finished `Data` back for the write, instead of the
    /// backend encoding a full item array on the main thread. The default
    /// implementation decodes and routes through `save(_:)` so item-array
    /// backends (in-memory test doubles) keep their existing semantics.
    ///
    /// PR-A note: `FileStorageBackend` overrides this default extension
    /// with a custom implementation that does read-back verification
    /// (`defaults.synchronize()` + memcmp). SQLiteStorageBackend (PR-B)
    /// will throw `unsupportedFeature`. The default extension stays for
    /// `MemoryStorageBackend` (test seam).
    func saveBlob(_ data: Data) throws

    // MARK: - Granular (PR-A; backends opt in by implementing)

    /// Upserts one item row. SQLiteStorageBackend (PR-B) is the primary
    /// implementer; FileStorageBackend throws unsupportedFeature;
    /// MemoryStorageBackend delegates to `save(_:)` (full-array pass).
    func upsertItem(_ item: ClipboardItem) throws

    /// Hard-deletes one item row by id. Used by ClipboardStore.saveItems
    /// delete-propagation (docs §3.2.1) to remove items no longer in
    /// the current array.
    func hardDeleteItem(id: UUID) throws

    /// Upserts one tag row.
    func upsertTag(_ tag: Tag) throws

    /// Adds `tagID` to `itemID`'s tag set. Per-item, per-tag — the caller
    /// loops over `item.tagIds` (a Set<UUID>).
    func attachTag(itemID: UUID, tagID: UUID) throws

    /// Removes `tagID` from `itemID`'s tag set.
    func detachTag(itemID: UUID, tagID: UUID) throws

    /// Moves `itemID` from items → trash_items in one atomic transaction.
    /// The `trashSnapshot: ClipboardItem` carries the data to persist
    /// (a snapshot because the source items.content_blob may change later
    /// — the trash must show what was trashed, not the current item).
    func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws

    /// Moves `itemID` back from trash_items → items in one atomic transaction.
    func restoreFromTrash(itemID: UUID) throws

    /// Returns the Set<UUID> of all item ids currently in the items table.
    /// Used by ClipboardStore.saveItems' delete-propagation diff.
    func loadAllIDs() throws -> Set<UUID>

    /// Sets a typed key/value pair in `app_meta` (or equivalent in the
    /// backend's own key/value store). `type` is `"blob"` | `"i64"` |
    /// `"json"` — see docs/design/storage-migration.md §2 `app_meta`.
    func setMeta(key: String, value: Data, type: String) throws

    /// Reads a key from `app_meta`; nil if absent.
    func meta(key: String) throws -> Data?
}

extension StorageBackend {
    func saveBlob(_ data: Data) throws {
        let items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        try save(items)
    }

    /// PR-A: granular methods default to `unsupportedFeature` (the static
    /// capability signal). Concrete backends override the ones they can
    /// implement; everything else throws, callers fall back to the
    /// array-level path (docs/design/storage-migration.md §3.1).
    func upsertItem(_ item: ClipboardItem) throws {
        throw StorageBackendError.unsupportedFeature("upsertItem: this backend stores items as a single array, use save(_:) instead")
    }
    func hardDeleteItem(id: UUID) throws {
        throw StorageBackendError.unsupportedFeature("hardDeleteItem: this backend stores items as a single array, no per-row delete is possible")
    }
    func upsertTag(_ tag: Tag) throws {
        throw StorageBackendError.unsupportedFeature("upsertTag: this backend stores tags as a single array, use saveTags(_:) instead")
    }
    func attachTag(itemID: UUID, tagID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("attachTag: this backend has no per-row item_tags table")
    }
    func detachTag(itemID: UUID, tagID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("detachTag: this backend has no per-row item_tags table")
    }
    func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws {
        throw StorageBackendError.unsupportedFeature("moveToTrash: this backend stores items as a single array, the trash is its own UserDefaults key managed by TrashStore")
    }
    func restoreFromTrash(itemID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("restoreFromTrash: this backend stores items as a single array, the trash is its own UserDefaults key managed by TrashStore")
    }
    func loadAllIDs() throws -> Set<UUID> {
        throw StorageBackendError.unsupportedFeature("loadAllIDs: this backend stores items as a single array, no per-row id set is available")
    }
    func setMeta(key: String, value: Data, type: String) throws {
        throw StorageBackendError.unsupportedFeature("setMeta: this backend has no app_meta table")
    }
    func meta(key: String) throws -> Data? {
        throw StorageBackendError.unsupportedFeature("meta: this backend has no app_meta table")
    }
}

/// ID-REVIEW-1024 (PR-A): granular methods fall back to the array-level
/// path via this error type. Lives in `StorageBackend.swift` (NOT
/// `BackupService.swift`'s `BackupError`) — the two error hierarchies
/// are separate concerns (storage vs backup); coupling them would
/// create an unwanted cross-module dependency.
enum StorageBackendError: Error, LocalizedError {
    /// Caller asked for a granular operation this backend can't do
    /// (e.g. `FileStorageBackend` can't do per-row updates because
    /// items live as a single JSON blob in UserDefaults). The caller
    /// should fall back to the array-level path (`save(_:)`,
    /// `saveTags(_:)`, etc.) which every backend supports.
    case unsupportedFeature(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFeature(let detail):
            return "StorageBackend granular operation unsupported: \(detail)"
        }
    }
}

// MARK: - File Storage (UserDefaults)

/// Production backend backed by UserDefaults — **despite the name, it
/// does NOT touch the filesystem**. The "File" in the name is a
/// historical artifact from when this protocol was first introduced
/// (then FileStorageBackend was intended to write to disk via
/// `~/Library/Application Support/ClipMemory/...`; that plan was
/// dropped in favor of UserDefaults for atomicity). Reads and writes
/// go through `UserDefaults.standard` only — see `init`, `load`,
/// `save`, `saveBlob`. Tests that want real disk isolation should use
/// a different backend or wrap with `testDefaults` via the
/// `makeTestDefaults()` test seam.
///
/// Writes are synchronous so `flushPendingSaves()` can guarantee data hits
/// the UserDefaults store before the app terminates.
final class FileStorageBackend: StorageBackend {
    // ID-PERF-0001 (2026-07-30 audit): hoist JSONEncoder allocation.
    // JSONEncoder is documented thread-safe for `.encode()` since macOS 10.15,
    // so a class-scope static is safe. Used serially per call site (each
    // save/saveTags runs to completion before the next).
    private static let itemsEncoder = JSONEncoder()
    private static let tagsEncoder = JSONEncoder()

    private let storageKey: String

    // P1-AUDIT-2026-09-22 (P2-2): dedicated logger so silent write
    // failures surface in Console.app / `log show` for triage.
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "StorageBackend")

    // ID-STORE-0015 (2026-08-14, L26 live drill path C): inject the defaults
    // suite so callers (notably TrashStore.init(backend:defaults:)) can route
    // the production defaults down to the storage layer. Default `.standard`
    // keeps every existing call-site working — the convenience inits in
    // ClipboardStore() now pass their `defaults` (which is `xcTestDefaults`
    // under XCTest, `.standard` in production) explicitly so this seam is
    // the only path that ever touches the host UserDefaults.
    private let defaults: UserDefaults

    init(storageKey: String = UserDefaultsKey.clipboardItems.rawValue,
         defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
    }

    func load() throws -> [ClipboardItem] {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([ClipboardItem].self, from: data)
    }

    func save(_ items: [ClipboardItem]) throws {
        let data = try Self.itemsEncoder.encode(items)
        defaults.set(data, forKey: storageKey)
    }

    /// CLIP-2: persist an already-encoded blob — the write itself is a single
    /// UserDefaults set; the expensive JSONEncoder pass happened on the
    /// caller's encoding queue.
    ///
    /// P1-AUDIT-2026-09-22 (P2-2) — honest scope (post OpenCode auto-review):
    ///
    /// **What this catches** (write-time, via read-back):
    /// - IN-MEMORY `set()` failure: UserDefaults that was sandbox-blocked
    ///   at process init and silently dropped the value (rare; backed by
    ///   `defaults.data(forKey:) == nil` immediately after `set()`).
    ///   `defaults.synchronize()` is invoked between set and read-back to
    ///   give the OS one chance to flush before the read-back check, but
    ///   in practice `synchronize()` only writes the in-memory cache to
    ///   the cfprefsd daemon — it does not surface write errors here.
    ///
    /// **What this does NOT catch** (write-time, despite the audit's
    /// headline scenarios):
    /// - ASYNC daemon flush failures (disk-full / permission-denied at
    ///   cfprefsd's periodic persist): `set()` already returned Void /
    ///   the cache accepted the value, so a later `synchronize()` /
    ///   read-back from the same process still returns the cached bytes.
    ///   The data will silently disappear on next process restart.
    /// - Process crash between `set()` and the daemon's flush: same.
    ///
    /// The sole caller is `ClipboardStore.saveItems()` →
    /// `flushSave catch` → `.clipboardSaveFailed` notification +
    /// `SaveRetryState` backoff (ID-SILENT-0022). Throwing on
    /// in-memory failure flows through that path correctly.
    func saveBlob(_ data: Data) throws {
        defaults.set(data, forKey: storageKey)
        // Force-flush attempt before read-back. Deprecated since
        // macOS 10.5 but still functional — it's the only mechanism
        // we have to nudge the daemon to write the in-memory cache
        // before we read it back. Suppress the deprecation warning
        // because every Foundation write code path is "deprecated"
        // under the same Apple guidance, and ignoring it is the
        // documented norm.
        defaults.synchronize()
        guard let readBack = defaults.data(forKey: storageKey),
              readBack == data else {
            logger.error("P1-AUDIT-2026-09-22 P2-2: saveBlob failed read-back for key '\(self.storageKey)' (silent write failure)")
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func loadTags() throws -> [Tag] {
        // Same UserDefaults key is used for both items and tags only if the caller
        // reuses the default key for both — but in practice tags use a different
        // key (ClipboardStore.tagStorageKey). This method reads whatever is at
        // `storageKey`; if it's the items array the decode will throw and the
        // caller treats it as empty tags.
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([Tag].self, from: data)
    }

    func saveTags(_ tags: [Tag]) throws {
        let data = try Self.tagsEncoder.encode(tags)
        defaults.set(data, forKey: storageKey)
        // ID-CRASH-0007 (2026-09-28 code-review P1-1): `defaults.set`
        // is `Void`-returning, never throws on disk-full / cfprefsd
        // rejection. Mirror `saveBlob()`'s read-back so the upstream
        // `flushTagSave catch` is actually reachable on write failure.
        // `synchronize()` is the only mechanism to nudge the daemon
        // to write the in-memory cache before we read it back. The
        // read-back catches in-memory set failures + most daemon
        // failures; async daemon flush failures and post-set process
        // crashes are still bounded by `StorageBackend.swift:96-119`'s
        // documented honesty about what read-back can't catch.
        defaults.synchronize()
        guard let readBack = defaults.data(forKey: storageKey),
              readBack == data else {
            logger.error("ID-CRASH-0007: saveTags failed read-back for key '\(self.storageKey)' (silent write failure)")
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: - PR-A granular overrides (all throw unsupportedFeature)

    /// PR-A rationale: `FileStorageBackend` keeps items as a single
    /// JSON blob in UserDefaults. Per-row updates would require
    /// loading the whole blob, modifying one item, and writing it
    /// back — but that IS just `save(_:)` again with a filtered
    /// array. We don't expose that as a granular method to avoid
    /// implying FileStorageBackend has true row-level storage; callers
    /// get the unsupportedFeature signal and fall back to `save(_:)`
    /// at the array level. The "throws always" implementation is the
    /// *testable* form of the unsupportedFeature contract — see
    /// `testFileStorageBackendGranularThrowsUnsupportedFeature`.
    func upsertItem(_ item: ClipboardItem) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend stores items as a single JSON blob; use save(_:) instead")
    }
    func hardDeleteItem(id: UUID) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend stores items as a single JSON blob; there is no per-row delete path")
    }
    func upsertTag(_ tag: Tag) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend stores tags as a single JSON blob; use saveTags(_:) instead")
    }
    func attachTag(itemID: UUID, tagID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend has no per-row item_tags table")
    }
    func detachTag(itemID: UUID, tagID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend has no per-row item_tags table")
    }
    func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend keeps trash in its own UserDefaults key via TrashStore; no per-row moveToTrash here")
    }
    func restoreFromTrash(itemID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend keeps trash in its own UserDefaults key via TrashStore; no per-row restoreFromTrash here")
    }
    func loadAllIDs() throws -> Set<UUID> {
        // Returning [] here would lie (mask the unsupportedFeature signal);
        // throwing is the contractually correct fallback so callers don't
        // silently delete items that are in the blob.
        throw StorageBackendError.unsupportedFeature("FileStorageBackend stores items as a single JSON blob; no per-row id set is available")
    }
    func setMeta(key: String, value: Data, type: String) throws {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend has no app_meta table")
    }
    func meta(key: String) throws -> Data? {
        throw StorageBackendError.unsupportedFeature("FileStorageBackend has no app_meta table")
    }
}

// MARK: - Memory Storage (Testing)

/// In-memory backend for testing without persisting to UserDefaults.
final class MemoryStorageBackend: StorageBackend {
    // I-7 fix (2026-07-20 audit): the in-memory backend's mutable arrays
    // were not protected against concurrent reads/writes. Swift arrays do
    // not give a hard guarantee against cross-thread mutation (Array
    // mutation is documented as not thread-safe). Production code paths
    // are main-actor; tests typically run synchronously; but a test that
    // races `save()` from two threads, or reads `items` while another
    // thread mutates it, can crash or silently drop data. Use an
    // NSLock to keep the contract honest for any future caller.
    private let lock = NSLock()
    private var _items: [ClipboardItem] = []
    private var _tags: [Tag] = []

    init(items: [ClipboardItem] = []) {
        self._items = items
    }

    func load() throws -> [ClipboardItem] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    func save(_ items: [ClipboardItem]) throws {
        lock.lock(); defer { lock.unlock() }
        self._items = items
    }

    func loadTags() throws -> [Tag] {
        lock.lock(); defer { lock.unlock() }
        return _tags
    }

    func saveTags(_ tags: [Tag]) throws {
        lock.lock(); defer { lock.unlock() }
        self._tags = tags
    }

    // MARK: - PR-A granular overrides (array-level equivalence)

    /// PR-A rationale: `MemoryStorageBackend` doesn't persist to
    /// disk, so "granular" methods just rebuild the underlying
    /// `_items` / `_tags` arrays. They never throw `unsupportedFeature`
    /// because the array-level operation is always available — the
    /// test seam verifies the path is byte-equivalent to calling
    /// `save(_:)` directly.
    func upsertItem(_ item: ClipboardItem) throws {
        // Replace-by-id: rebuild _items with the new value at the right
        // index, or append if not present. This is the array-level
        // pass — no row-level storage to talk to.
        lock.lock(); defer { lock.unlock() }
        var found = false
        for (idx, existing) in _items.enumerated() where existing.id == item.id {
            _items[idx] = item
            found = true
            break
        }
        if !found { _items.append(item) }
    }

    func hardDeleteItem(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        _items.removeAll { $0.id == id }
    }

    func upsertTag(_ tag: Tag) throws {
        lock.lock(); defer { lock.unlock() }
        var found = false
        for (idx, existing) in _tags.enumerated() where existing.id == tag.id {
            _tags[idx] = tag
            found = true
            break
        }
        if !found { _tags.append(tag) }
    }

    /// In-memory `item.tags` are kept on `ClipboardItem.tagIds: Set<UUID>`
    /// (not in `item_tags`), so `attachTag` / `detachTag` just rewrite
    /// the in-memory item's tag set. Real persistence layer is out of
    /// scope for the in-memory backend.
    func attachTag(itemID: UUID, tagID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = _items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = _items[idx]
        if !item.tagIds.contains(tagID) {
            var ids = item.tagIds
            ids.insert(tagID)
            item = item.with(tagIds: ids)
            _items[idx] = item
        }
    }

    func detachTag(itemID: UUID, tagID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = _items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = _items[idx]
        if item.tagIds.contains(tagID) {
            var ids = item.tagIds
            ids.remove(tagID)
            item = item.with(tagIds: ids)
            _items[idx] = item
        }
    }

    /// In-memory "trash" semantics: a single `_trashItems: [ClipboardItem]`
    /// array, separate from `_items`. (Per docs/design §3.3 — separate
    /// table for trash mirrors TrashStore's "trash is its own store".)
    /// SQLiteStorageBackend (PR-B) will write to a real `trash_items`
    /// table with FK to `items`; here in PR-A we mirror the same
    /// shape with two in-memory arrays.
    private var _trashItems: [ClipboardItem] = []
    func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws {
        lock.lock(); defer { lock.unlock() }
        _items.removeAll { $0.id == itemID }
        _trashItems.removeAll { $0.id == itemID }
        _trashItems.append(trashSnapshot)
    }
    func restoreFromTrash(itemID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let trashIdx = _trashItems.firstIndex(where: { $0.id == itemID }) else { return }
        let restored = _trashItems[trashIdx]
        _trashItems.remove(at: trashIdx)
        if !_items.contains(where: { $0.id == itemID }) {
            _items.append(restored)
        }
    }
    func loadAllIDs() throws -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(_items.map(\.id))
    }
    func setMeta(key: String, value: Data, type: String) throws {
        // No persistence layer here — the in-memory backend doesn't
        // carry meta. PR-B (SQLiteStorageBackend) implements this on
        // top of the real app_meta table.
        throw StorageBackendError.unsupportedFeature("MemoryStorageBackend has no app_meta table")
    }
    func meta(key: String) throws -> Data? {
        throw StorageBackendError.unsupportedFeature("MemoryStorageBackend has no app_meta table")
    }
}

/// ID-REVIEW-1024 (PR-A): SQLiteStorageBackend **placeholder** class.
/// The real implementation lands in PR-B (single-connection + sqlite3
/// handles + WAL + NORMAL). For PR-A this class exists so that:
///   - the `case is SQLiteStorageBackend:` switch arm in
///     `ClipboardStore.saveItems` (per docs §3.2.1) compiles;
///   - `loadAllIDs()` is available for ClipboardStore.saveItems'
///     delete-propagation diff (PR-B replaces the throw with a real
///     `SELECT id FROM items` query);
///   - ClipboardStore falls back to `save(_:)` array-level on
///     `StorageBackendError.unsupportedFeature` — verified by the
///     integration test `testClipboardStoreFallbackToArrayPath`.
///
/// Every method throws `unsupportedFeature` so the caller falls
/// back. PR-B replaces each method body with the SQLite impl; the
/// class skeleton, error contract, and protocol conformance stay
/// unchanged.
///
/// This is NOT an "amend" — it is a forward commit. PR-A introduces
/// the placeholder so PR-B can do a clean class replacement without
/// touching unrelated files.
final class SQLiteStorageBackend: StorageBackend {
    init() {}

    // Array-level (these exist for protocol conformance; the SQLite
    // backend doesn't store whole arrays, but they implement the
    // protocol contract for callers that always use save(_:)).
    func load() throws -> [ClipboardItem] {
        // The SQLite backend would query rows + decode; for the
        // placeholder PR-A returns empty so the protocol conformance
        // is real (not a stub `fatalError`). PR-B replaces this with
        // a real SELECT + decoder pipeline.
        return []
    }
    func save(_ items: [ClipboardItem]) throws {
        // SQLiteStorageBackend's normal save path is granular
        // (upsertItem in a transaction). The array-level save(_:)
        // exists only for callers that pass a whole array — the
        // placeholder delegates to upsertItem per item.
        try items.forEach { try upsertItem($0) }
    }
    func loadTags() throws -> [Tag] {
        return []
    }
    func saveTags(_ tags: [Tag]) throws {
        try tags.forEach { try upsertTag($0) }
    }
    func saveBlob(_ data: Data) throws {
        // Per docs §3.2 — SQLiteStorageBackend.saveBlob is a programmer
        // error (callers should use upsertItem). Throwing here surfaces
        // the misuse immediately rather than silently round-tripping
        // through JSON like the default protocol extension does.
        throw StorageBackendError.unsupportedFeature("saveBlob not supported on SQLite; use upsertItem instead")
    }

    // MARK: - SQLite-specific transaction helpers (PR-B implements)

    // These are NOT part of the StorageBackend protocol — they're
    // SQLite-specific (single connection, BEGIN/COMMIT/ROLLBACK
    // wrappers around granular ops). PR-A exposes the signatures so
    // the caller (ClipboardStore.saveItems' granular path) can use
    // them; PR-B implements the bodies (PRAGMA foreign_keys=ON +
    // single connection + sqlite3_prepare_v2 + step + commit).

    /// Begins a write transaction on the underlying sqlite3
    /// connection. All subsequent granular ops run inside this
    /// transaction until `commitTransaction` or `rollbackTransaction`
    /// is called. PR-A placeholder always throws (real impl in PR-B).
    func beginTransaction() throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend.beginTransaction: PR-B will implement via sqlite3_exec(db, 'BEGIN IMMEDIATE', nil, nil, nil)")
    }

    /// Commits the current transaction.
    func commitTransaction() throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend.commitTransaction: PR-B will implement via sqlite3_exec(db, 'COMMIT', nil, nil, nil) + WAL fsync per the design's §1.1 synchronous=NORMAL contract")
    }

    /// Rolls back the current transaction.
    func rollbackTransaction() throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend.rollbackTransaction: PR-B will implement via sqlite3_exec(db, 'ROLLBACK', nil, nil, nil)")
    }

    // Granular (PR-A: all throw unsupportedFeature; PR-B replaces each
    // body with the real SQLite impl).
    func upsertItem(_ item: ClipboardItem) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement upsertItem as INSERT … ON CONFLICT(id) DO UPDATE")
    }
    func hardDeleteItem(id: UUID) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement hardDeleteItem as DELETE FROM items WHERE id = ?")
    }
    func upsertTag(_ tag: Tag) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement upsertTag as INSERT … ON CONFLICT(id) DO UPDATE")
    }
    func attachTag(itemID: UUID, tagID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement attachTag as INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)")
    }
    func detachTag(itemID: UUID, tagID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement detachTag as DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?")
    }
    func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement moveToTrash as a single transaction: INSERT INTO trash_items … + DELETE FROM items WHERE id = ?")
    }
    func restoreFromTrash(itemID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement restoreFromTrash as a single transaction: DELETE FROM trash_items WHERE item_id = ? + INSERT INTO items …")
    }
    func loadAllIDs() throws -> Set<UUID> {
        // For PR-B: SELECT id FROM items.
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement loadAllIDs as SELECT id FROM items")
    }
    func setMeta(key: String, value: Data, type: String) throws {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement setMeta as INSERT INTO app_meta (key, value_type, value) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE")
    }
    func meta(key: String) throws -> Data? {
        throw StorageBackendError.unsupportedFeature("SQLiteStorageBackend: PR-B will implement meta as SELECT value, value_type FROM app_meta WHERE key = ?")
    }
}
