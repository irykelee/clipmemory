import Foundation
import os.log
import SQLite3

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

    // MARK: - Trash dimension (PR-C gate, docs §11 open question 5)

    /// Loads every item currently in the recycle bin.
    ///
    /// The trash is a DIMENSION of the store, not a view of the main
    /// item list. Answering this with the main items hands the caller
    /// the wrong data, and answering "save the trash" by replacing the
    /// main items destroys the history — that is exactly the trap
    /// docs §11 open question 5 describes. A backend that keeps the
    /// trash in its own key/table implements this; a backend that
    /// cannot MUST throw `StorageBackendError.unsupportedFeature` so
    /// the caller falls back to the array-level path.
    func loadTrashAll() throws -> [ClipboardItem]

    /// Saves the full list of trashed items.
    ///
    /// Same contract as `save(_:)`, but for the trash dimension: the
    /// array replaces the trash's own contents and MUST NOT touch the
    /// main items.
    func saveTrash(_ items: [ClipboardItem]) throws

    /// Permanently deletes the given trashed items.
    ///
    /// The retention window and the "ask before a large purge" gate
    /// (ID-CRASH-0035) are PRODUCT decisions and stay in `TrashStore`
    /// — which is why this method takes the ids to delete and not a
    /// retention length. A backend that computed the expiry itself
    /// would give the policy two sources of truth.
    func purgeTrash(deleting itemIDs: Set<UUID>) throws
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
        throw StorageBackendError.unsupportedFeature("moveToTrash: items are one array here; trash is TrashStore's own UserDefaults key")
    }
    func restoreFromTrash(itemID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("restoreFromTrash: items are one array here; trash is TrashStore's own UserDefaults key")
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
    func loadTrashAll() throws -> [ClipboardItem] {
        throw StorageBackendError.unsupportedFeature("loadTrashAll: this backend has no trash dimension, the trash is managed by TrashStore")
    }
    func saveTrash(_ items: [ClipboardItem]) throws {
        throw StorageBackendError.unsupportedFeature("saveTrash: this backend has no trash dimension, the trash is managed by TrashStore")
    }
    func purgeTrash(deleting itemIDs: Set<UUID>) throws {
        throw StorageBackendError.unsupportedFeature("purgeTrash: this backend has no trash dimension, the trash is managed by TrashStore")
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

    /// A backend write failed at the storage layer (SQLite returned a
    /// non-OK code, a FK constraint was violated, a ROLLBACK failed, …).
    ///
    /// ID-CRASH-0022 (2026-10-15): the SQLite backend's `exec()` helpers
    /// used to swallow every failure — they only wrote a log line and
    /// returned normally — which made the many `throws` signatures in
    /// that backend a fiction. A FK violation (e.g. `attachTag` with a
    /// missing tag row) was silently ignored, and a failed `ROLLBACK`
    /// left writes committed. This case is the signal that makes those
    /// signatures honest.
    case storageFailure(sql: String, code: Int32, detail: String)

    /// ID-CRASH-0031 (2026-10-20): a test process tried to write one of
    /// the production data keys (`ClipboardItems` / `ClipboardTrashedItems`
    /// / `ClipMemoryTags`) in the real `com.clipmemory.app` domain.
    ///
    /// Background: `xcodebuild test` launches the app binary through
    /// LaunchServices, and a plain app launch has no
    /// `XCTestConfigurationFilePath`, so the per-service `xcTestDefaults`
    /// guard silently fell through to the PRODUCTION path. The launched
    /// app then loaded the user's real history + recycle bin and wrote
    /// its own snapshot back — including a retention purge that replaced
    /// 106 trashed entries with an empty array. This case makes that
    /// impossible: a test process can never write the user's data blobs.
    case productionWriteBlocked(storageKey: String)

    /// ID-REVIEW-1024 review (2026-10-23): the caller asked a backend to
    /// act on a scope it does not address — e.g. "save the recycle bin"
    /// to a backend that addresses the clipboard history.
    ///
    /// This is NOT a transient failure and NOT a storage failure: the
    /// backend is healthy, the request is simply out of scope. Retrying
    /// it would fail the same way, so `isRetryable` is false.
    ///
    /// It is deliberately a DIFFERENT case from `unsupportedFeature`,
    /// because the two are handled differently by `TrashStore`:
    /// `unsupportedFeature` means "this backend has no trash dimension —
    /// fall back to the array path", while a scope mismatch on a WRITE
    /// must NOT fall back: the array path of a history-scoped backend is
    /// the user's clipboard history, and saving the bin through it
    /// would replace the history with the bin.
    case scopeMismatch(String)

    /// Whether retrying the failed operation could plausibly succeed.
    ///
    /// ID-REVIEW-1024 (PR-D N.4, 2026-10-21): the schema migration
    /// takes a write lock (`BEGIN IMMEDIATE`), so it can lose a race
    /// with another process. That failure is TRANSIENT — the database
    /// is untouched and the next attempt can succeed. A constraint
    /// violation or a syntax error is PERMANENT — retrying it only
    /// makes the user wait for the same failure.
    ///
    /// The SQLite result code is already carried by `storageFailure`, so
    /// the distinction is machine-checkable instead of a judgement call
    /// repeated at every call site. A caller that wants a retry ladder
    /// asks this property; one that does not can ignore it.
    var isRetryable: Bool {
        switch self {
        case .storageFailure(_, let code, _):
            return code == SQLITE_BUSY || code == SQLITE_LOCKED
        case .unsupportedFeature, .productionWriteBlocked, .scopeMismatch:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedFeature(let detail):
            return "StorageBackend granular operation unsupported: \(detail)"
        case .storageFailure(let sql, let code, let detail):
            return "StorageBackend write failed (rc=\(code)): \(detail) — sql=\(sql.prefix(120))"
        case .productionWriteBlocked(let key):
            return "Refusing to write production UserDefaults key '\(key)' from a test process"
        case .scopeMismatch(let detail):
            return "StorageBackend scope mismatch: \(detail)"
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
    //
    // ID-REVIEW-1024 review (2026-10-23): the justification this comment
    // used to carry ("JSONEncoder is documented thread-safe for `.encode()`
    // since macOS 10.15") had no source and is not what the measurement
    // shows. What was MEASURED on this machine, on the same input:
    //
    // * `JSONEncoder` IS `Sendable` in this SDK — a Swift 6 `-typecheck`
    //   probe (`requiresSendable(JSONEncoder())`) compiles clean. So
    //   sharing one instance is not a concurrency violation.
    // * 8000 CONCURRENT encodes (4000 on this shared instance, 4000 on
    //   fresh per-call instances) produced ZERO decode failures and ZERO
    //   value mismatches: Foundation's encoder does not corrupt its
    //   output under concurrency.
    // * What is NOT stable is the BYTE SEQUENCE. The same input encoded
    //   200 times in a row on this shared instance produced 9 DIFFERENT
    //   byte sequences; fresh per-call instances produced 2 different
    //   sequences in 500 encodes; under concurrency 25–55; and two
    //   processes produced entirely different orders. JSON object key
    //   order is not a contract.
    //
    // Consequence for this file: NO statement about the stored bytes may
    // be made anywhere in the storage layer. The invariant that holds is
    // semantic — same key, same encoder configuration, same decoder ⇒ the
    // same decoded content.
    private static let itemsEncoder = JSONEncoder()
    private static let tagsEncoder = JSONEncoder()

    private let storageKey: String

    /// ID-REVIEW-1024 (PR-C, docs §11 open question 5): the scope this
    /// backend addresses.
    ///
    /// The recycle bin is a DIMENSION of the store, not a view of the
    /// main item list. The backend therefore has to say WHICH scope it
    /// is — the trash dimension of an ITEMS-scoped backend is the hole
    /// this closes:
    ///
    /// Before the scope existed, EVERY `FileStorageBackend` had a trash
    /// dimension and that dimension always addressed the bin's key. So
    /// `FileStorageBackend(storageKey: "ClipboardItems").saveTrash(...)`
    /// wrote `ClipboardTrashedItems` — an items-scoped backend could
    /// overwrite the user's recycle bin. There is no call site that does
    /// it today, but the protocol opened the door to exactly the 2026-10-20
    /// incident class: the bin replaced by an array it was never asked to
    /// hold.
    ///
    /// With the scope:
    /// * `.items` — the history. There is NO trash dimension: this
    ///   backend cannot read the bin and it cannot write it.
    /// * `.trash` — the recycle bin. The array-level scope IS the bin,
    ///   and the trash dimension reads and writes the same key. This is
    ///   the production trash backend (`ClipboardStore.init` wires
    ///   `FileStorageBackend(storageKey: TrashStore.trashedItemsStorageKey, scope: .trash)`),
    ///   so the production behaviour is unchanged: same key, same
    ///   encoder configuration, same decoder, same decoded content.
    enum Scope {
        /// The clipboard history.
        case items
        /// The recycle bin.
        case trash
    }

    private let scope: Scope

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
         scope: Scope = .items,
         defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.scope = scope
        self.defaults = defaults
    }

    /// ID-CRASH-0031 (2026-10-20): the write gate for the production data
    /// blobs.
    ///
    /// Background: `xcodebuild test` launches the app binary through
    /// LaunchServices. A plain app launch has no
    /// `XCTestConfigurationFilePath`, so the per-service `xcTestDefaults`
    /// guard fell through to the PRODUCTION path and the launched app read
    /// and wrote the user's real `com.clipmemory.app` domain — including a
    /// retention purge that replaced the recycle bin with an empty array.
    ///
    /// This gate makes that impossible from the inside: while the process
    /// is running tests, the production data keys (`ClipboardItems` /
    /// `ClipboardTrashedItems` / `ClipMemoryTags`) must never be written
    /// into `.standard`.
    ///
    /// Scope notes:
    /// - Only the three production DATA keys are blocked. Test fixtures
    ///   that use their own storage key in an isolated suite (and the
    ///   existing `prod.default.*` seam test) are untouched.
    /// - The check is on the storage key AND `.standard`; an isolated
    ///   suite that happens to use a production key name is a test
    ///   fixture, not the user's data.
    /// - The key is a PARAMETER because the trash dimension writes the
    ///   bin's own key, which is a production data key too — the gate
    ///   must cover it exactly like the items key. (A `.trash`-scoped
    ///   backend's array scope IS that key, so the same parameter
    ///   covers both.)
    private func assertWriteAllowed(_ key: String) throws {
        guard TestIsolation.mustRefuseProductionDataMutation(defaults),
              TestIsolation.productionDataKeys.contains(key) else {
            return
        }
        logger.error("ID-CRASH-0031: blocked a test process from writing the production data key '\(key, privacy: .public)'")
        throw StorageBackendError.productionWriteBlocked(storageKey: key)
    }

    func load() throws -> [ClipboardItem] {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([ClipboardItem].self, from: data)
    }

    func save(_ items: [ClipboardItem]) throws {
        try assertWriteAllowed(storageKey)
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
        try assertWriteAllowed(storageKey)
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
        try assertWriteAllowed(storageKey)
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

    // MARK: - Trash dimension (PR-C, array-level equivalent)

    /// ID-REVIEW-1024 (PR-C, docs §11 open question 5): the trash
    /// dimension of the UserDefaults backend.
    ///
    /// The trash is one JSON blob under its own key, so the array-level
    /// implementation is the whole story: read the blob, write the
    /// blob, and — for a purge — read, filter, write back. There is no
    /// row-level trash to speak of, and pretending otherwise would be
    /// a lie in the same way the granular overrides are.
    ///
    /// The write path mirrors `save(_:)` plus the read-back verification
    /// that `saveBlob` / `saveTags` already carry: `defaults.set` is
    /// Void-returning and silently drops the value when cfprefsd rejects
    /// the write, and `TrashStore.saveTrashedItems`'s three-leg catch
    /// (log + needsSave retry + `.clipboardSaveFailed`) is only reachable
    /// if the backend throws. Counting on JSONEncoder alone (which is the
    /// only thing that threw before) would leave the most common failure
    /// class — the silent write — permanently outside the gate.
    ///
    /// ID-REVIEW-1024 review (2026-10-23): this comment used to say the
    /// behaviour was "byte-for-byte what it was before the trash
    /// dimension existed". That was never true and is not true now —
    /// measured: the same array encoded twice in a row yields two
    /// different byte sequences (JSON key order is not stable, not even
    /// within one process). The byte sequence is NOT a contract; the
    /// decoded content is.
    ///
    /// ## The scope gate
    ///
    /// Only a `.trash`-scoped backend has a trash dimension. An
    /// `.items`-scoped backend answers the READ with
    /// `unsupportedFeature` — the protocol's "I don't have that
    /// dimension" signal, which `TrashStore` handles by falling back to
    /// the array path (a read, so nothing can be lost).
    ///
    /// The WRITE and the PURGE answer with `scopeMismatch` instead, and
    /// that asymmetry is deliberate: `TrashStore` falls back to the
    /// array path for `unsupportedFeature`, so an items-scoped backend
    /// would otherwise save the bin THROUGH THE HISTORY — replacing
    /// the user's clipboard history with the recycle bin. A loud
    /// failure (log + retry + notification, the three-leg contract)
    /// is the only acceptable outcome for a write.
    func loadTrashAll() throws -> [ClipboardItem] {
        guard scope == .trash else {
            throw StorageBackendError.unsupportedFeature(
                "loadTrashAll: this backend addresses the clipboard history, not the recycle bin"
            )
        }
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        return try JSONDecoder().decode([ClipboardItem].self, from: data)
    }

    func saveTrash(_ items: [ClipboardItem]) throws {
        guard scope == .trash else {
            throw StorageBackendError.scopeMismatch(
                "saveTrash: this backend addresses the clipboard history — refusing to write the recycle bin"
            )
        }
        try assertWriteAllowed(storageKey)
        let data = try Self.itemsEncoder.encode(items)
        defaults.set(data, forKey: storageKey)
        // Same read-back contract as saveBlob / saveTags: defaults.set
        // never throws, so without this the TrashStore catch gates are
        // dead code on the most common failure class (ID-REVIEW-1024
        // review, 2026-10-24). Async daemon flush failures and post-set
        // crashes remain outside what read-back can catch — see the
        // honesty block above saveBlob.
        defaults.synchronize()
        guard let readBack = defaults.data(forKey: storageKey),
              readBack == data else {
            logger.error("saveTrash failed read-back for key '\(self.storageKey)' (silent write failure)")
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func purgeTrash(deleting itemIDs: Set<UUID>) throws {
        guard scope == .trash else {
            throw StorageBackendError.scopeMismatch(
                "purgeTrash: this backend addresses the clipboard history — refusing to purge the recycle bin"
            )
        }
        guard !itemIDs.isEmpty else { return }
        let kept = try loadTrashAll().filter { !itemIDs.contains($0.id) }
        try saveTrash(kept)
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
        throw StorageBackendError.unsupportedFeature("moveToTrash: trash lives in TrashStore's own UserDefaults key; no per-row call here")
    }
    func restoreFromTrash(itemID: UUID) throws {
        throw StorageBackendError.unsupportedFeature("restoreFromTrash: trash lives in TrashStore's own UserDefaults key; no per-row call here")
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
    /// SQLiteStorageBackend (PR-B) writes to a real `trash_items` table
    /// with NO foreign key to `items` (ID-CRASH-0022: the old
    /// `REFERENCES items(id) ON DELETE CASCADE` made the §3.3 write
    /// order — INSERT trash, then DELETE item — delete the trash row it
    /// had just written); here in PR-A we mirror the same shape with two
    /// in-memory arrays.
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

    // MARK: - Trash dimension (PR-C, array-level equivalent)

    /// ID-REVIEW-1024 (PR-C, docs §11 open question 5): the trash
    /// dimension reads and writes `_trashItems` — the SAME array the
    /// granular `moveToTrash` / `restoreFromTrash` use. The trash is
    /// its own store here, exactly as it is in the SQLite backend's
    /// `trash_items` table, so the array-level path and the granular
    /// path cannot disagree about where the trash lives.
    func loadTrashAll() throws -> [ClipboardItem] {
        lock.lock(); defer { lock.unlock() }
        return _trashItems
    }

    func saveTrash(_ items: [ClipboardItem]) throws {
        lock.lock(); defer { lock.unlock() }
        _trashItems = items
    }

    func purgeTrash(deleting itemIDs: Set<UUID>) throws {
        lock.lock(); defer { lock.unlock() }
        guard !itemIDs.isEmpty else { return }
        _trashItems.removeAll { itemIDs.contains($0.id) }
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

// ID-REVIEW-1024 (PR-B): the SQLiteStorageBackend placeholder that PR-A
// declared in this file (every method threw `unsupportedFeature` so the
// caller fell back to the array-level path) has been replaced by the
// real SQLite-backed implementation in its own file:
//   Services/SQLiteStorageBackend.swift
// The placeholder class body was removed with PR-B; nothing in
// this file needs to change again for the SQLite backend.
