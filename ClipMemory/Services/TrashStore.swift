import Foundation
import os
import AppKit

/// HIGH-1 (2026-07-26 review): trash subsystem extracted from ClipboardStore
/// (was ~180 lines in the 1594-line god object). Owns the recycle bin, its
/// persistence, retention policy, and debounced save timer.
///
/// **F-1 phase 2 (2026-07-28)**: class is now `@MainActor`. The previously
/// implicit "callers must ensure main thread" contract on `@Published` writes
/// is now enforced by the type system. See 2026-07-28 F-2 audit closeout
/// for the F-2 sweep + future-marker notes.
@MainActor
final class TrashStore: ObservableObject {
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "Trash")

    /// Items moved to the recycle bin. Persisted separately from `items`.
    @Published var trashedItems: [ClipboardItem] = []

    /// Number of days trashed items are kept before automatic permanent deletion.
    @Published var trashRetentionDays: Int {
        // P1-AUDIT-2026-09-22 (P2-9): use the central `UserDefaultsKey` rawValue
        // — the prior `trashedItemsStorageKey + ".retentionDays"` concatenation
        // was a string-literal pattern that hides the actual key from static
        // auditing. UserDefaultsKey.trashedItemsRetentionDays has the same
        // `"ClipboardTrashedItems.retentionDays"` value, so existing data
        // survives.
        didSet { defaults.set(trashRetentionDays, forKey: UserDefaultsKey.trashedItemsRetentionDays.rawValue) }
    }

    // H-2 (2026-08-08): `var` not `let` so `replaceBackendForTesting`
    // (DEBUG-only seam) can swap in a fresh backend mid-test.
    // Production code never reassigns.
    private var backend: StorageBackend
    private let defaults: UserDefaults
    private let saveTimerQueue = DispatchQueue(label: "com.clipmemory.trashsave", qos: .utility)
    private var saveTimer: DispatchSourceTimer?
    private var needsSave = false
    // ID-CRASH-0044 (2026-09-28 code-review P3): single source of truth
    // for the 500 ms save-debounce. Matches `ClipboardStore.saveDebounceInterval`
    // at `ClipboardStore.swift:760` so a single tuning knob (the H-1
    // retry contract's flush timing) propagates to both stores.
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(500)

    /// Shared storage key, retained for migration compatibility.
    /// F-1 phase 2 (2026-07-28): `nonisolated` so callers (incl. @MainActor
    /// ClipboardStore init) can read this static let from any isolation domain.
    /// P1-AUDIT-2026-09-22 (P2-9): aliased through `UserDefaultsKey` so the
    /// raw string lives in exactly one place. Tests still reference this
    /// constant (`ClipboardStoreTrashTests.swift:686, 698, 733`).
    nonisolated static let trashedItemsStorageKey = UserDefaultsKey.trashedItems.rawValue

    /// H-2 (2026-08-08): persistent sentinel that survives across launches.
    /// Set to `true` when `quarantineCorruptBlob` removes the original
    /// blob; cleared on the next successful `loadTrashedItems()`. The
    /// in-memory `lastLoadFailed` flag is reset every launch, so without
    /// this sentinel the second launch would `load()` the now-missing
    /// key (returns `[]` silently), set `lastLoadFailed = false`, and
    /// `cleanupOrphanedImages` would proceed to delete trash images as
    /// "orphans" — irrecoverable data loss. Reading the sentinel in
    /// `loadTrashedItems` closes that one-launch-delay gap.
    /// P1-AUDIT-2026-09-22 (audit finding P1-1): the legacy comment claimed
    /// "cleared on the next successful loadTrashedItems()", but the
    /// implementation only flipped an in-memory flag. The persistent
    /// sentinel was never removed, so once it was set, every future launch
    /// short-circuited to the empty + `lastLoadFailed=true` path even after
    /// a healthy blob was saved. Survives across launches to prevent the
    /// second-launch trap where a freshly-saved blob would be silently
    /// emptied + orphan-image cleanup would delete trash images. Cleared
    /// (via `removeObject`) by `loadTrashedItems` once a healthy
    /// `backend.load()` succeeds.
    /// P1-AUDIT-2026-09-22 (P2-9): the previous expression
    /// `trashedItemsStorageKey + ".loadFailed"` hid the raw key from static
    /// auditing and could silently rename if `trashedItemsStorageKey` ever
    /// changed. Promoted to its own `UserDefaultsKey` case.
    nonisolated static let loadFailedSentinelKey = UserDefaultsKey.trashedItemsLoadFailedSentinel.rawValue

    /// Reference to the content cache and RTF cache from ClipboardStore, set
    /// after init so evictCaches can drop stale entries.
    var contentCache: NSCache<NSString, NSString>?
    var rtfPlaintextCache: NSCache<NSString, NSString>?

    /// Observer for `NSApplication.willTerminateNotification`. Registered in
    /// `init` so the cleanup logic (cancel timer + flush pending save) runs
    /// on `.main` and can safely touch `@MainActor`-isolated state. `deinit`
    /// only removes this opaque token (no isolated access).
    ///
    /// Invariant: this observer must fire BEFORE `deinit`. The TrashStore
    /// lives as long as NSApp (held via `ClipboardStore.shared` singleton),
    /// so willTerminate always fires first under normal termination.
    /// SIGKILL / power-loss paths are out of scope (no write-through
    /// guarantee). See 2026-07-28 F-1 phase 2 spec §4.
    private var willTerminateObserver: NSObjectProtocol?

    /// M13 (2026-08-03): `defaults` injectable so tests use an isolated suite.
    /// Production callers pass the defaulted `.standard` — no call-site change.
    init(backend: StorageBackend, defaults: UserDefaults = .standard) {
        // H-2 (2026-08-08): `backend` is `var` (not `let`) so the
        // `replaceBackendForTesting` test seam can swap in a fresh
        // backend mid-test to exercise the post-failure recovery path.
        // Production code never reassigns `backend` — the seam is
        // wrapped in `#if DEBUG`.
        self.backend = backend
        self.defaults = defaults
        let retentionKey = UserDefaultsKey.trashedItemsRetentionDays.rawValue
        let saved = defaults.integer(forKey: retentionKey)
        let valid = [3, 7, 14, 30]
        if valid.contains(saved) {
            trashRetentionDays = saved
        } else {
            // ID-STORE-0008 (2026-08-03): removed persist-on-absent write.
            // Gap 2 (v4 plan): the unconditional set() here caused fresh-CI
            // environments to write production defaults on every test run.
            // New users get the in-memory default (7) — the settings UI's
            // @Published binding reads trashRetentionDays directly.
            trashRetentionDays = 7
        }
        loadTrashedItems()
        purgeExpiredTrash()
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Runs on .main queue → safe to access isolated state.
            // Delegate to `handleWillTerminate()` (NOT inline duplicate) so
            // the production path is exactly what tests exercise; any future
            // bugfix in handleWillTerminate automatically applies here.
            self?.handleWillTerminate()
        }
    }

    /// Internal: the actual willTerminate handler body. Extracted so tests
    /// can pin the contract without `NotificationCenter.post` global side
    /// effects (which would fire NSApp + AppDelegate observers).
    func handleWillTerminate() {
        saveTimer?.cancel()
        if needsSave { saveTrashedItems() }
    }

    deinit {
        // Nonisolated deinit reads opaque token (no isolated state touched).
        // All cleanup that touches `@MainActor` state lives in the
        // willTerminate handler registered above.
        if let observer = willTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // ID-LIFE-0001 (2026-07-30 audit): cancel saveTimer in deinit.
        // In tests (no NSApplication.willTerminate), the store deallocates
        // before the timer fires; DispatchSourceTimer + queue + closure stay
        // retained until next fire (500 ms). DispatchSourceTimer.cancel()
        // is Sendable so this is safe from a nonisolated deinit. Mirrors
        // the ClipboardStore.deinit pattern (line 491).
        saveTimer?.cancel()
    }

    // MARK: - Persistence

    // MARK: - The trash dimension (ID-REVIEW-1024, PR-C)

    /// Reads the recycle bin through the backend's TRASH dimension.
    ///
    /// The protocol grew a trash dimension (docs §11 open question 5):
    /// before it, the trash was read through the array-level `load()`,
    /// which in a row-based backend means "read the MAIN ITEMS as if
    /// they were the recycle bin". A backend without a trash dimension
    /// throws `unsupportedFeature` and falls back to the array-level
    /// path. The production `FileStorageBackend` implements the
    /// dimension, so the production behaviour is unchanged.
    private func loadTrashAllWithFallback() throws -> [ClipboardItem] {
        do {
            return try backend.loadTrashAll()
        } catch StorageBackendError.unsupportedFeature {
            return try backend.load()
        }
    }

    /// Writes the recycle bin through the backend's TRASH dimension,
    /// with the same fallback as the read path.
    ///
    /// The fallback keeps the OLD semantics for a backend that has no
    /// trash dimension: its array-level `save(_:)` IS the trash store
    /// (the production wiring hands `TrashStore` a backend whose key
    /// is the trash key).
    private func saveTrashWithFallback(_ items: [ClipboardItem]) throws {
        do {
            try backend.saveTrash(items)
        } catch StorageBackendError.unsupportedFeature {
            try backend.save(items)
        }
    }

    /// Deletes the given ids from the recycle bin, through the
    /// backend's trash dimension.
    ///
    /// The retention DECISION is made here (`expiredTrashEntries`) —
    /// the backend only deletes the ids it is handed, so the policy
    /// (the window, and the "ask before a large purge" gate of
    /// ID-CRASH-0035) has exactly one home.
    ///
    /// A backend without a trash dimension needs no purge call: its
    /// array-level save rewrites the whole collection, which the
    /// debounced save below does anyway. A REAL failure is logged
    /// loudly — the rows stay in the store until that debounced save
    /// removes them, and that save carries the three-leg error
    /// contract (log + retry + user-visible notification).
    /// Returns whether the deletion is durably recorded. `true` when the
    /// backend purged the rows, `true` on `unsupportedFeature` (the
    /// array-level save covers it), `false` when the backend write failed —
    /// callers use it to decide whether the image files may be physically
    /// deleted yet (see the ordering note on `deletePermanently`).
    @discardableResult
    private func purgeTrashWithFallback(_ itemIDs: Set<UUID>) -> Bool {
        guard !itemIDs.isEmpty else { return true }
        // ID-REVIEW-1025 (2026-10-24): the backend's purge is a
        // read-modify-write on the PERSISTED blob
        // (`FileStorageBackend.purgeTrash` loads the stored array, drops
        // the given ids, writes the rest back). If the persisted blob is
        // STALE relative to `trashedItems`, that rewrite resurrects
        // whatever the stale blob still holds:
        //
        //   * the user restores an entry → it leaves `trashedItems`, but
        //     the 500 ms debounce has not flushed yet → the blob still
        //     has it → the purge writes it back → the entry is in the
        //     bin AGAIN on the next launch, and also in the history;
        //   * the user trashes an entry → it is in `trashedItems` but not
        //     yet in the blob → the purge rewrites the blob without it
        //     → the entry is missing from the bin on the next launch.
        //
        // Both are silent, and both are fixed by making the blob
        // CURRENT before the read-modify-write. `flushPendingSave()`
        // writes `trashedItems` — which every caller has already
        // updated to the post-purge state (see `deletePermanently`,
        // `emptyTrash`, `deleteExpiredEntries`) — and is a no-op when
        // nothing is pending, so the common path pays nothing.
        //
        // The flush keeps the three-leg contract intact: a failed write
        // re-sets `needsSave`, schedules the retry, and posts
        // `.clipboardSaveFailed` (see `saveTrashedItems`).
        flushPendingSave()
        if needsSave || (lastLoadFailed && trashedItems.isEmpty) {
            // The authoritative write did not happen: either it FAILED
            // (the catch in `saveTrashedItems` re-set the flag and
            // posted the alert) or it was REFUSED (the load-failed
            // guard — the store's content is unknown, so an empty
            // collection must not replace it). Running the backend's
            // read-modify-write now would rewrite the STALE blob and
            // resurrect what it still holds — so the purge is refused
            // instead. `false` also means the image files are NOT
            // deleted (the ordering contract on `deletePermanently`).
            return false
        }
        do {
            try backend.purgeTrash(deleting: itemIDs)
            return true
        } catch StorageBackendError.unsupportedFeature {
            // No trash dimension — the array-level save covers it.
            return true
        } catch {
            logger.error(
                "ID-REVIEW-1024: purging \(itemIDs.count) trashed item(s) failed: \(error.localizedDescription)"
            )
            // Three-piece gate third leg (ID-REVIEW-1024, 2026-10-24):
            // this catch used to be log-only. The retry leg is
            // scheduleSave()'s blob rewrite, but that only alerts on ITS
            // OWN failure — post here too, with the same source bucket as
            // saveTrashedItems, so "the bin can't be persisted" shows the
            // user one throttled alert no matter which leg caught it.
            NotificationCenter.default.post(
                name: .clipboardSaveFailed,
                object: self,
                userInfo: ["source": "trashSaveFailed"]
            )
            return false
        }
    }

    func loadTrashedItems() {
        let sentinelKey = Self.loadFailedSentinelKey
        let hadPriorFailure = defaults.bool(forKey: sentinelKey)

        // H-2 (2026-08-08): persistent-failure shortcut. If a previous
        // launch's `quarantineCorruptBlob` already removed the blob, the
        // next launch's `backend.load()` returns `[]` (StorageBackend
        // `:54-57` `guard let data = ... else { return [] }`) — the call
        // succeeds, `lastLoadFailed` would be cleared, and the orphan
        // sweep would proceed and delete the trash images. Detect the
        // sentinel here BEFORE calling `backend.load()` so the failure
        // signal survives across launches.
        if hadPriorFailure {
            // P1-AUDIT-2026-09-22 (audit finding P1-1): the persistent-failure
            // sentinel's only purpose was to keep cleanupOrphanedImages from
            // deleting trash images while the blob was quarantined. We must still
            // allow RECOVERY — if backend.load() returns non-empty items, the user
            // has saved healthier content and we clear the sentinel.
            do {
                let recovered = try loadTrashAllWithFallback()
                if !recovered.isEmpty {
                    trashedItems = recovered
                    lastLoadFailed = false
                    defaults.removeObject(forKey: Self.loadFailedSentinelKey)
                    return
                }
            } catch {
                // load() still throws — fall through to persistent-failure path.
            }
            trashedItems = []
            lastLoadFailed = true
            // swiftlint:disable:next line_length
            logger.error("Trash load failure persisted from prior launch (sentinel '\(sentinelKey)' present). Quarantined blob retained under '\(Self.trashedItemsStorageKey).corrupt-*'. Image cleanup skipped to avoid data loss.")
            postTrashLoadFailed(userInfo: [
                "persistent": true,
                // ID-CRASH-0022 (2026-10-20): tag the source so the
                // AppDelegate Throttler can bucket trash failures
                // independently from save / encryption failures.
                "source": "trashLoadFailed"
            ])
            return
        }

        do {
            trashedItems = try loadTrashAllWithFallback()
            lastLoadFailed = false
            // P1-AUDIT-2026-09-22: clear the sentinel once a healthy load
            // completes; covers the first-clean-launch path so the next
            // launch never starts with a stale flag.
            defaults.removeObject(forKey: Self.loadFailedSentinelKey)
        } catch {
            quarantineCorruptBlob(error: error)
            trashedItems = []
            lastLoadFailed = true
            // H-2: persist the failure across launches so the next
            // launch also skips the orphan-image sweep (see above).
            defaults.set(true, forKey: sentinelKey)
            logger.error("Trash blob corrupt; quarantined + sentinel written: \(error.localizedDescription)")
            postTrashLoadFailed(userInfo: [
                "persistent": false,
                "error": error.localizedDescription,
                // ID-CRASH-0022 (2026-10-20): tag the source so the
                // AppDelegate Throttler can bucket trash failures
                // independently from save / encryption failures.
                "source": "trashLoadFailed"
            ])
        }
    }

    /// Post `.trashLoadFailed` **asynchronously**.
    ///
    /// ID-CRASH-0022 (2026-10-20): the load happens inside
    /// `TrashStore.init`, i.e. while `ClipboardStore.shared` is being
    /// constructed — which happens in `applicationDidFinishLaunching`
    /// BEFORE the AppDelegate registers its observers. A synchronous
    /// post is therefore delivered to nobody: the alert the observer
    /// exists to show never appeared. Posting after the current
    /// main-queue block lets the launch sequence finish first
    /// (observers included) and keeps the modal alert out of the
    /// middle of app startup.
    private func postTrashLoadFailed(userInfo: [String: Any]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .trashLoadFailed,
                object: self,
                userInfo: userInfo
            )
        }
    }

    /// H-2 (2026-08-08): `true` after `loadTrashedItems()` swallowed a
    /// backend.load() throw. `ClipboardStore.loadItems()` reads this and
    /// skips `ImageStorage.cleanupOrphanedImages(keptItems:)` while it
    /// is true to avoid irrecoverable orphan-image deletion when the
    /// trash blob itself is the corrupt artifact.
    private(set) var lastLoadFailed: Bool = false

    #if DEBUG
    /// H-2 test seam: swap the backend mid-test so the post-failure
    /// recovery path can be exercised. Production code never calls this.
    func replaceBackendForTesting(_ newBackend: StorageBackend) {
        backend = newBackend
    }
    #endif

    // ID-PERF-0009 (2026-07-30 audit): same fix as ClipboardStore —
    // share a static `ISO8601DateFormatter` instead of allocating one
    // per quarantine call (~1 ms init each).
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func quarantineCorruptBlob(error: Error) {
        let key = Self.trashedItemsStorageKey
        guard let blob = defaults.data(forKey: key) else { return }
        // ID-CRASH-0031 (2026-10-20): the quarantine MOVES the blob — it
        // writes a `.corrupt-*` copy and REMOVES the original key. The
        // removal is more destructive than a write, so it needs the same
        // production-domain guard the write path has.
        guard !TestIsolation.mustRefuseProductionDataMutation(defaults) else {
            logger.error("ID-CRASH-0031: refusing to quarantine the production trash blob from a test process")
            return
        }
        let timestamp = Self.iso8601Formatter.string(from: Date())
        let quarantineKey = "\(key).corrupt-\(timestamp)"
        defaults.set(blob, forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        logger.error("Corrupt trash blob quarantined to \(quarantineKey): \(error.localizedDescription)")
    }

    /// ID-STORE-0019 (MEDIUM-15 audit fix, 2026-08-15) + P1-AUDIT-2026-09-22
    /// (audit finding P1-3, retry leg was dead code until needsSave was
    /// flipped back to true in the catch branch — see saveTrashedItems).
    /// The three legs of the data-persistence gate now apply to the trash
    /// path too — previously only the loud-log leg was present. On save
    /// failure:
    ///   1. 报错 — loud log (existing line).
    ///   2. 重试 — reschedule the existing `saveTimer` at a longer
    ///      interval so the next attempt happens without waiting for
    ///      the next user mutation (the same fix pattern as ClipboardStore's
    ///      flushSave retry on `.saveFlush` source).
    ///   3. 用户可见 — post `.clipboardSaveFailed` with source
    ///      `"trashSaveFailed"` so the existing AppDelegate throttler
    ///      surfaces an NSAlert in the same bucket scheme as `saveFlush`
    ///      (separate bucket, 60s window — no mutual suppression).
    /// The data itself is in-memory only after the failed write (trashed
    /// items live in `self.trashedItems`), so the risk is "next launch
    /// has no trash" — recoverable but user-visible only on quit.
    func saveTrashedItems() {
        // ID-CRASH-0022 (2026-10-20): refuse to write an EMPTY collection
        // while the trash load is in a FAILED state.
        //
        // ID-CRASH-0022 (2026-10-20, corrected later the same day): the
        // original version of this guard refused EVERY write while
        // `lastLoadFailed` was true, on the theory that the in-memory
        // collection does not represent the store, so a whole-array
        // replace would destroy it. That theory was wrong, and a probe
        // proved it:
        //
        //   * A failed load means `quarantineCorruptBlob` already ran.
        //     It MOVES the blob to a `.corrupt-*` key and REMOVES the
        //     main key — so after the failure the main key is EMPTY.
        //     There is no store content left for a write to destroy.
        //   * The quarantined copy lives under a different key; a write
        //     to the main key cannot touch it. The probe read it back
        //     after a write: byte-identical.
        //
        // So the guard protected nothing, while its cost was real: an
        // item the user trashed during a degraded launch stayed in
        // memory only (lost on quit), and the app could never leave the
        // degraded state — the sentinel path only clears itself when the
        // blob comes back non-empty.
        //
        // The rule below is the narrow one that is actually meaningful:
        // an EMPTY write while the load failed is refused (it would
        // replace a store we know nothing about with a known-empty
        // collection); a NON-EMPTY write is allowed, because its content
        // can only be items the user has just trashed, and it lets the
        // next launch recover (the sentinel path sees a non-empty blob
        // and clears the failed state).
        if lastLoadFailed && trashedItems.isEmpty {
            logger.error(
                // swiftlint:disable:next line_length
                "ID-CRASH-0022: refusing to write an empty collection while the trash load is in a failed state — the store's content is unknown, and an empty write would replace it with a known-empty collection"
            )
            NotificationCenter.default.post(
                name: .clipboardSaveFailed,
                object: self,
                userInfo: ["source": "trashSaveFailed"]
            )
            return
        }
        do {
            try saveTrashWithFallback(trashedItems)
        } catch {
            // 1. loud log
            logger.error("ID-STORE-0019: Failed to save trashed items: \(error.localizedDescription)")

            // P1-AUDIT-2026-09-22 (audit finding P1-3): flip needsSave back
            // to true BEFORE calling scheduleSaveRetry. flushSave sets it to
            // false at line 376 before invoking saveTrashedItems, so the
            // legacy retry guard `guard needsSave else { return }` was
            // instant-dead-code — same anti-pattern as ClipboardStore's
            // pre-H-1 needsSave race (commit 2026-08-09). The retry timer
            // will only re-enter via flushSave's guard when needsSave stays
            // true.
            needsSave = true

            // 2. retry — schedule another save via the existing saveTimer,
            //    with a longer deadline so we don't tight-loop if the
            //    backend is in a transient bad state.
            scheduleSaveRetry()

            // 3. user-visible — post .clipboardSaveFailed with the
            //    trash-specific source. The existing AppDelegate
            //    observer (line 487) reads `note.userInfo["source"]`
            //    and routes to `saveAlertThrottler.recordFailure`,
            //    which buckets by source — "trashSaveFailed" is its
            //    own 60s window, independent of "saveFlush".
            NotificationCenter.default.post(
                name: .clipboardSaveFailed,
                object: self,
                userInfo: ["source": "trashSaveFailed"]
            )
        }
    }

    /// ID-STORE-0019: schedule a retry save via the existing saveTimer
    /// at a 5s deadline. Uses a longer interval than the 500ms debounce
    /// (line ?) to avoid tight-looping on a transient bad state; the
    /// existing scheduleSave() debounce pattern handles coalescing.
    private func scheduleSaveRetry() {
        guard needsSave else { return }
        if saveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: saveTimerQueue)
            timer.setEventHandler { [weak self] in
                DispatchQueue.main.async { self?.flushSave() }
            }
            timer.resume()
            saveTimer = timer
        }
        saveTimer?.schedule(deadline: .now() + 5)
    }

    // MARK: - Operations

    /// Move a single item to the recycle bin.
    func moveToTrash(_ item: ClipboardItem, evictCaches: (ClipboardItem) -> Void, didMove: () -> Void) {
        // ID-STORE-0003 (2026-07-31 audit): idempotent by id — a double
        // moveToTrash (batch + single delete race, restore-then-retrash)
        // used to insert a duplicate trashed entry, skewing export/import
        // counts and the trash UI. Skip when the id is already in the bin.
        guard !trashedItems.contains(where: { $0.id == item.id }) else { return }
        evictCaches(item)
        var trashed = item
        trashed.deletedAt = Date()
        trashedItems.insert(trashed, at: 0)
        didMove()
        scheduleSave()
    }

    /// Move multiple items to the recycle bin (shared timestamp, L-5).
    func moveToTrash(_ itemsToMove: [ClipboardItem], evictCaches: (ClipboardItem) -> Void, didMove: () -> Void) {
        let now = Date()
        // ID-STORE-0003: idempotent by id — skip items already in the bin
        // (and duplicates within the batch itself) so no duplicate trashed
        // entries can be created. Nothing moved → no didMove/save.
        var seen = Set(trashedItems.map { $0.id })
        var movedAny = false
        for item in itemsToMove {
            guard seen.insert(item.id).inserted else { continue }
            evictCaches(item)
            var trashed = item
            trashed.deletedAt = now
            // ID-PERF-0005 (2026-07-30 audit): append + sort at end instead
            // of insert(at: 0) per item. For K items into an empty array the
            // old path was O(K^2); the new path is O(K log K) and matches
            // the per-item moveToTrash's eventual order (most-recent first).
            trashedItems.append(trashed)
            movedAny = true
        }
        guard movedAny else { return }
        trashedItems.sort { $0.deletedAt ?? .distantPast > $1.deletedAt ?? .distantPast }
        didMove()
        scheduleSave()
    }

    func restoreFromTrash(_ item: ClipboardItem, didRestore: (ClipboardItem) -> Void) {
        guard let index = trashedItems.firstIndex(where: { $0.id == item.id }) else { return }
        var restored = trashedItems.remove(at: index)
        restored.deletedAt = nil
        didRestore(restored)
        scheduleSave()
    }

    /// Ordering contract for every delete path: remove the rows from the
    /// bin and persist that FIRST, delete the image files LAST. If the
    /// process dies in between, the worst outcome is an orphan image file
    /// (reaped by cleanupOrphanedImages); the opposite order leaves a live
    /// trash row pointing at a file that no longer exists — an
    /// unrecoverable broken entry. And when the backend purge itself
    /// failed, the files are NOT deleted: the row is still in the bin, so
    /// the image must stay reachable behind it.
    func deletePermanently(_ item: ClipboardItem) {
        trashedItems.removeAll { $0.id == item.id }
        let persisted = purgeTrashWithFallback([item.id])
        scheduleSave()
        if persisted, item.type == .image {
            ImageStorage.shared.deleteImage(filename: item.content)
        }
    }

    func emptyTrash() {
        let imageContents = trashedItems.filter { $0.type == .image }.map { $0.content }
        let purgedIDs = Set(trashedItems.map { $0.id })
        trashedItems.removeAll()
        let persisted = purgeTrashWithFallback(purgedIDs)
        scheduleSave()
        guard persisted else { return }
        for content in imageContents {
            ImageStorage.shared.deleteImage(filename: content)
        }
    }

    /// ID-CRASH-0035 (2026-10-21): how many expired entries an automatic
    /// retention purge may delete before it has to ask the user first.
    ///
    /// Below the threshold the purge is routine housekeeping and stays
    /// silent. At or above it the purge **waits for the user's
    /// confirmation**: the entries stay in the bin until the user
    /// decides. The trade-off is deliberate — the retention window stops
    /// being a hard upper bound, but a big batch can never disappear
    /// without a decision.
    ///
    /// 20 is the cut-off. The 2026-10-20 incident deleted 106 entries in
    /// a single launch; a normal day's expiry stays far below 20.
    static let expiredPurgeConfirmationThreshold = 20

    /// ID-CRASH-0035: how many entries are currently waiting for the
    /// user's confirmation. It is the SIZE of `pendingExpiredPurgeIDs`
    /// — a convenience mirror for the UI, never the marker itself.
    private(set) var pendingExpiredPurgeCount: Int = 0

    /// ID-REVIEW-1025 (2026-10-24): the **identity** of the pending set.
    ///
    /// The count alone is not a usable "already asked" marker: the same
    /// count can describe a completely different set of entries later on
    /// (25 entries expire today, the user never answers, 25 *different*
    /// entries expire tomorrow). Keyed on the count alone, the second
    /// batch is silently skipped — the purge stops working for one size
    /// class and the bin grows with no user-visible signal, which is the
    /// exact failure ID-CRASH-0035 was raised to prevent.
    ///
    /// The marker is therefore the set of entry ids, and it is cleared
    /// whenever the pending state is resolved by ANY path (see
    /// `clearPendingPurgeState()`).
    private var pendingExpiredPurgeIDs: Set<UUID> = []

    /// The pending state is over: whatever the notice referred to has
    /// been deleted, restored, or has expired out of the set. A stale
    /// marker must never survive, because it would suppress the notice
    /// for the NEXT batch.
    private func clearPendingPurgeState() {
        pendingExpiredPurgeIDs = []
        pendingExpiredPurgeCount = 0
    }

    /// Posts the "N entries are waiting for your decision" notice.
    ///
    /// `count == 0` is the RESOLVED signal: the entries the notice
    /// referred to have left the bin (restored, or deleted one by one),
    /// so there is nothing left to decide and the UI must drop the
    /// badge. Without that signal the AppDelegate keeps a stale count,
    /// and the badge gates the QuickBar — the app would look stuck.
    private func postPurgePendingNotice(count: Int, retentionDays: Int) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .trashPurgePending,
                object: self,
                userInfo: [
                    "count": count,
                    "retentionDays": retentionDays
                ]
            )
        }
    }

    /// Remove every item whose `deletedAt` is older than the retention
    /// window.
    ///
    /// ID-CRASH-0022 (2026-10-20): this is a DELETE, and it used to run
    /// with **no user-visible signal at all**. The 2026-10-20 incident
    /// was exactly this: 106 items, every one of them past the 7-day
    /// window, removed in one launch, and the recycle bin rewritten as
    /// `[]` — with nothing said to the user. The data was still in the
    /// daily backup, but the user had no way to know the bin had been
    /// emptied.
    ///
    /// The purge itself is a product decision (the retention window is
    /// the user's setting), so it stays. What was missing is the third
    /// leg of the data-deletion gate: the user must be told. The count
    /// and the window are posted so the UI can say how many items went
    /// and how long they were kept.
    ///
    /// ID-CRASH-0035 (2026-10-21): the third leg is now a two-step gate.
    /// A purge of at least `expiredPurgeConfirmationThreshold` entries
    /// does NOT delete anything — it posts `.trashPurgePending` and the
    /// UI asks the user to confirm. Only `confirmExpiredPurge()` (the
    /// user's answer) deletes. Below the threshold the purge stays
    /// silent: a handful of expired entries is housekeeping, not an event.
    func purgeExpiredTrash() {
        let expired = expiredTrashEntries()
        let expiredIDs = Set(expired.map { $0.id })
        let retentionDays = trashRetentionDays

        // ID-REVIEW-1025 (2026-10-24, independent review P1+P2): an
        // OUTSTANDING QUESTION takes priority over everything else.
        //
        // The user was told a batch is waiting for their decision. While
        // that question is open, NOTHING may be deleted automatically —
        // not even a batch that has fallen below the threshold:
        //
        //   25 entries expire → the user is asked (badge: 25);
        //   the user restores 6 of them → 19 are left;
        //   the next tick sees 19 < 20 → the ROUTINE branch used to
        //   delete them, with no decision at all.
        //
        // That broke the promise the badge makes ("a big batch can never
        // disappear without a decision"). The gate is now: a question
        // that has been asked stays open until the user answers it.
        if !pendingExpiredPurgeIDs.isEmpty {
            let stillPending = pendingExpiredPurgeIDs.intersection(expiredIDs)
            if stillPending.isEmpty {
                // Every entry the question referred to has left the bin
                // (restored, or deleted one by one) → the question is
                // moot. Resolve it AND tell the UI: the badge gates the
                // QuickBar, so a stale count would leave the app
                // unreachable until it is restarted.
                clearPendingPurgeState()
                postPurgePendingNotice(count: 0, retentionDays: retentionDays)
                return
            }
            if stillPending != pendingExpiredPurgeIDs {
                // The user restored some of the pending entries → the
                // count on the badge must follow, and the set is
                // re-asked with the new membership.
                pendingExpiredPurgeIDs = stillPending
                pendingExpiredPurgeCount = stillPending.count
                postPurgePendingNotice(count: stillPending.count, retentionDays: retentionDays)
            }
            return
        }

        guard !expired.isEmpty else { return }
        let removedCount = expired.count

        if removedCount >= Self.expiredPurgeConfirmationThreshold {
            // The notice is posted asynchronously for the same reason as
            // the one below: `purgeExpiredTrash()` runs from
            // `TrashStore.init`, i.e. while `ClipboardStore.shared` is
            // still being constructed and the AppDelegate has not
            // registered its observers yet.
            //
            // ID-REVIEW-1025: the "already asked" marker is the IDENTITY
            // of the pending set, not its size. The 60 s cleanup tick
            // re-runs this method with the same entries and must stay
            // quiet; a DIFFERENT set of entries — even one of the same
            // size — must ask again.
            pendingExpiredPurgeIDs = expiredIDs
            pendingExpiredPurgeCount = removedCount
            postPurgePendingNotice(count: removedCount, retentionDays: retentionDays)
            return
        }

        // Below the threshold the purge is routine: it asks nothing and
        // deletes right away. There is no outstanding question at this
        // point (the branch above returned early if there were one), so
        // there is no pending state to clear.
        deleteExpiredEntries(expired)
        postExpiredNotice(count: removedCount, retentionDays: retentionDays)
    }

    /// ID-CRASH-0035 (2026-10-21): the user confirmed the pending
    /// retention purge. Deletes the entries that are past the window now
    /// and reports what went.
    ///
    /// ID-REVIEW-1025 (2026-10-24, independent review P2): it deletes
    /// EXACTLY the set the user was shown. The confirmation dialog
    /// carries the count that was on the badge, so the number in the
    /// dialog and the number deleted have to be the same number —
    /// recomputing "everything expired right now" would silently add
    /// entries that expired while the dialog was open.
    func confirmExpiredPurge() {
        let expired = expiredTrashEntries()
        let expiredIDs = Set(expired.map { $0.id })
        let retentionDays = trashRetentionDays
        let target = pendingExpiredPurgeIDs.isEmpty
            ? expiredIDs
            : pendingExpiredPurgeIDs.intersection(expiredIDs)
        clearPendingPurgeState()
        guard !target.isEmpty else {
            // Nothing left to delete — the question is resolved, and the
            // UI must drop the badge (see `postPurgePendingNotice`).
            postPurgePendingNotice(count: 0, retentionDays: retentionDays)
            return
        }
        let entries = expired.filter { target.contains($0.id) }
        let removedCount = entries.count
        deleteExpiredEntries(entries)
        postExpiredNotice(count: removedCount, retentionDays: retentionDays)
    }

    /// ID-REVIEW-1025 (2026-10-24, independent review P2): the user
    /// DECLINED the pending purge ("取消" in the confirmation dialog).
    ///
    /// Nothing is deleted — the entries stay in the bin. What is
    /// forgotten is the QUESTION: the pending set is cleared and the UI
    /// is told, so the badge goes away.
    ///
    /// The old behaviour kept both, and the badge's count gates the
    /// QuickBar (`AppDelegate.statusItemClicked`) — so every later click
    /// on the menu bar icon opened the same modal again and the QuickBar
    /// could not be reached at all. The user was trapped in a
    /// destructive-or-nothing loop.
    ///
    /// The next 60 s tick asks again (the batch is still in the bin, so
    /// the question comes back as a fresh badge — not as a trap).
    func declineExpiredPurge() {
        let retentionDays = trashRetentionDays
        clearPendingPurgeState()
        postPurgePendingNotice(count: 0, retentionDays: retentionDays)
    }

    /// The entries that are past the retention window right now.
    ///
    /// The criterion is `deletedAt != nil && deletedAt < now - retention`.
    /// It is the ONLY expiry rule in the product: the backend stores
    /// the deletion moment (`deleted_at`) and the window is the user's
    /// setting, so nothing else may decide what is expired.
    ///
    /// ID-REVIEW-1024 (PR-C, 2026-10-23): internal rather than private
    /// so the criterion itself can be TESTED (see
    /// `SQLiteTrashDimensionTests`) instead of being re-implemented in
    /// the test — a re-implemented criterion would happily keep passing
    /// after the production one changes.
    func expiredTrashEntries() -> [ClipboardItem] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(trashRetentionDays * 24 * 60 * 60))
        return trashedItems.filter { item in
            guard let deletedAt = item.deletedAt else { return false }
            return deletedAt < cutoff
        }
    }

    /// Removes the given entries from the bin; image files go last (see
    /// the ordering contract on `deletePermanently`).
    private func deleteExpiredEntries(_ entries: [ClipboardItem]) {
        let imageContents = entries.filter { $0.type == .image }.map { $0.content }
        let expiredIds = Set(entries.map { $0.id })
        trashedItems.removeAll { expiredIds.contains($0.id) }
        let persisted = purgeTrashWithFallback(expiredIds)
        scheduleSave()
        guard persisted else { return }
        for content in imageContents {
            ImageStorage.shared.deleteImage(filename: content)
        }
    }

    /// Posts the "the purge happened" notice.
    ///
    /// The post is asynchronous on purpose: the purge runs from
    /// `TrashStore.init`, i.e. while `ClipboardStore.shared` is being
    /// constructed — which happens in `applicationDidFinishLaunching`
    /// BEFORE the AppDelegate registers its observers. A synchronous post
    /// would be delivered to nobody, and the user would again see the bin
    /// empty with no explanation. Posting after the current main-queue
    /// block lets the launch sequence finish first (observers included).
    private func postExpiredNotice(count: Int, retentionDays: Int) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .trashItemsExpired,
                object: self,
                userInfo: [
                    "count": count,
                    "retentionDays": retentionDays
                ]
            )
        }
    }

    // MARK: - Debounced save

    private func scheduleSave() {
        needsSave = true
        if saveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: saveTimerQueue)
            timer.setEventHandler { [weak self] in
                DispatchQueue.main.async { self?.flushSave() }
            }
            timer.resume()
            saveTimer = timer
        }
        saveTimer?.schedule(deadline: .now() + saveDebounceInterval)
    }

    private func flushSave() {
        guard needsSave else { return }
        needsSave = false
        // ID-LIFE-0023 (2026-07-31): no cancel() here — a cancelled
        // DispatchSource silently ignores later schedule() calls, which
        // used to kill every debounced trash save after the first flush.
        // deinit/handleWillTerminate cancel the source for real.
        saveTrashedItems()
    }

    func flushPendingSave() {
        guard needsSave else { return }
        // Clear the flag BEFORE saving, mirroring flushSave. The catch in
        // saveTrashedItems re-sets needsSave and schedules the retry timer;
        // clearing the flag after the call would erase that retry leg and
        // the 5s re-flush would guard-exit forever (ID-REVIEW-1024,
        // 2026-10-24 — same dead-gate shape that P1-AUDIT-2026-09-22 P1-3
        // fixed elsewhere).
        needsSave = false
        saveTrashedItems()
    }

    /// Trigger a debounced save — for callers that batch-modify trashedItems directly.
    func scheduleSavePublic() { scheduleSave() }
}
