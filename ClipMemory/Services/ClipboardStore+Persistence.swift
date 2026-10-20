//
//  ClipboardStore+Persistence.swift
//  ClipMemory
//
//  ARCH-0002 PR #1 (2026-08-11): persistence methods extracted from
//  ClipboardStore.swift into a pure extension. Zero logic change — methods
//  are copied verbatim. State (`saveTimer`, `saveTimerQueue`, `needsSave`,
//  `saveRetryState`, `itemEncodingQueue`) stays in the main class body
//  because Swift extensions can't have stored properties.
//
//  Swift access-level caveat: `private` on a class member restricts access
//  to the SAME source file (including extensions in the same file). When
//  the extension moves to a different file, the cross-file access requires
//  loosening `private` → `internal` (default) on the state members. This
//  is a visibility change, not a logic change — call sites and semantics
//  are untouched. See commit for exact visibility diff.
//
//  Version bump: none (internal refactor; per user spec "version bump = patch
//  — non minor/major"). Ship via rebase-merge to main, do not single-release.

import Foundation

extension ClipboardStore {

    /// ID-CRASH-0044 (2026-09-28 code-review P3): canonical 500 ms save-
    /// debounce constant. Used by `ClipboardStore.saveDebounceInterval`
    /// + `TrashStore.saveDebounceInterval` (both kept as literals for
    /// grep convenience; cross-referenced via the ID-CRASH-0044
    /// comments at each site).
    enum Persistence {
        static let saveDebounce: DispatchTimeInterval = .milliseconds(500)
    }

    func saveItems() throws {
        // CLIP-2: the `.sync` hop is deliberate — only the encoding CPU
        // moves off the calling thread; the durability semantics are
        // preserved on the caller. Deadlock-free: saveItems() is main-thread
        // only and nothing else dispatches to this queue.
        //
        // P1-AUDIT-2026-09-22 (P2-13): the `.sync` hop is no longer the
        // capture path's contract — capture now routes through
        // `scheduleSave()` (500ms debounce), so the only callers that still
        // demand synchronous durability are:
        //   - `saveImmediately()` → `flushSave()` (used by `importBackupItems`
        //     — migration path; needs write-through so a crash mid-restore
        //     doesn't half-merge a backup)
        //   - `flushPendingSaves()` (deinit + `applicationWillTerminate` —
        //     terminate-path guarantee)
        // The capture path's durability now relies on the terminate-path
        // flush rather than per-capture write-through.
        //
        // ID-CRASH-0035 (2026-09-28 code-review P2-0c): dispatch the
        // backend `saveBlob` off `@MainActor`. The previous inline call
        // ran `defaults.synchronize()` + full-Data `readBack == data`
        // memcmp on the main thread — for a 10K-item library the data
        // blob is 10–50 MB, so the memcmp alone is a few ms to tens of
        // ms per call. The encode hop (above) was already off-main via
        // `itemEncodingQueue`; the backend hop now also leaves main via
        // `DispatchQueue.global(qos: .utility).sync`. Caller still
        // blocks for completion (preserving the throwing contract +
        // the ID-SILENT-0022 three-leg gate), but the bulk of the
        // synchronous cost is no longer on @MainActor. Sync from main
        // to a utility queue is deadlock-free (main is not the
        // utility queue's target).
        //
        // ID-SILENT-0021 (2026-08-08 audit): rethrows on backend failure so
        // `flushSave` can restore `needsSave = true` and post
        // `.clipboardSaveFailed` for UI surfacing. Previously the inner
        // catch only logged, leaving `needsSave = false`, so the next
        // debounce timer exited via the early `guard` — silent data loss.
        //
        // ID-REVIEW-1024 (PR-A, docs/design/storage-migration.md §3.2.1):
        // dispatch on backend type. SQLiteStorageBackend uses granular
        // methods (one row per item + delete-propagation via Set<UUID>
        // diff); FileStorageBackend / MemoryStorageBackend throw
        // `unsupportedFeature` and we fall back to the array-level
        // `save(_:)` / `saveTags(_:)` path.
        //
        // **Trade-off**: the fallback writes the WHOLE items array to
        // FileStorageBackend on every save — so the SQLite "granular
        // wins" only kicks in once SQLiteStorageBackend is the active
        // backend (PR-B). Until then, this function is identical to the
        // pre-PR-A `saveBlob`-only path — no perf regression for legacy
        // users, and a clear migration target once SQLiteStorageBackend
        // becomes active (PR-C atomic switch).
        let snapshot = items
        // The canonical tag catalog, captured HERE on the main actor.
        //
        // ID-CRASH-0022 (2026-10-20): the granular path below runs on a
        // background queue, so it must not read `self.tags` there — that
        // would be a data race on main-actor state. `Tag` is a struct
        // and `[UUID: Tag]` is a value type, so the copy is safe to hand
        // across. The granular path needs the catalog because it has to
        // write the REAL tag (name + colour) before attaching it — see
        // `granularSave`.
        let tagCatalog = tags
        let data = try itemEncodingQueue.sync {
            try itemsSaveEncoder.encode(snapshot)
        }
        try DispatchQueue.global(qos: .utility).sync {
            do {
                // Try granular first; SQLiteStorageBackend throws
                // `unsupportedFeature` until PR-B lands, which is the
                // signal to fall back to the array-level path below.
                if let sqliteBackend = backend as? SQLiteStorageBackend {
                    try granularSave(to: sqliteBackend, items: snapshot, tags: tagCatalog)
                } else {
                    throw StorageBackendError.unsupportedFeature("not a SQLite backend")
                }
            } catch let error as StorageBackendError {
                // Narrow catch: only `unsupportedFeature` triggers the
                // array-level fallback (this is the static capability
                // signal between backends). Any other error — disk-full,
                // FK violation, ENCRYPT — propagates UP unchanged so the
                // ID-SILENT-0022 three-leg gate (报错 / 重试 / 用户可见)
                // sees the real cause. PR-A below the fallback never
                // hits this branch beyond `unsupportedFeature` (because
                // every granular method throws that exact case); PR-B
                // onward will exercise the up-propagation path when
                // SQLite throws real errors.
                if case .unsupportedFeature = error {
                    // Fallback: legacy array-level path. FileStorageBackend
                    // uses its custom saveBlob override (read-back
                    // verification per ID-CRASH-0007); MemoryStorageBackend
                    // uses the default extension. Either way the whole
                    // items blob is rewritten atomically.
                    try backend.saveBlob(data)
                } else {
                    // Re-throw — this preserves the original error
                    // (disk-full, FK violation, etc.) up to the caller's
                    // error-handling chain, rather than masking it as a
                    // saveBlob error from FileStorageBackend/MemoryStorageBackend.
                    throw error
                }
            } catch {
                // Non-StorageBackendError from `granularSave` (e.g.
                // Swift runtime traps, programmer errors): re-throw
                // without conversion — those are real bugs, not a
                // "switch backends" signal.
                throw error
            }
        }
    }

    /// PR-A granular save path. Currently unreachable because
    /// SQLiteStorageBackend is a placeholder (every method throws
    /// `unsupportedFeature`); exists so PR-B has a concrete call site
    /// to point the real implementation at.
    ///
    /// ID-CRASH-0022 (2026-10-20): `nonisolated` because the caller
    /// invokes this from a background queue. The method therefore takes
    /// everything it needs as parameters and touches NO main-actor
    /// state — the tag catalog is captured on the main actor by
    /// `saveItems()` and handed in.
    private nonisolated func granularSave(
        to backend: SQLiteStorageBackend,
        items: [ClipboardItem],
        tags: [UUID: Tag]
    ) throws {
        // upsertTag before attachTag — attachTag has FK on tags(id)
        // (PR-B schema), so the parent row must exist first. Wrap in
        // a transaction so partial failure rolls back cleanly. For the
        // placeholder, every backend method throws so the catch in the
        // caller falls back to saveBlob. Once PR-B replaces the body
        // methods, this becomes the granular fast-path.
        try backend.beginTransaction()
        do {
            // Pull the unique tag set from the items array. SQLite
            // upserts tags idempotently on PK collision.
            //
            // ID-CRASH-0022 (2026-10-20): the tag written here must be
            // the REAL one. `upsertTag` does
            // `ON CONFLICT(id) DO UPDATE SET name = excluded.name,
            // color_hex = excluded.color_hex`, so upserting a
            // placeholder (name: "", colorHex: "") OVERWROTE the
            // catalog's stored name and colour — the first granular save
            // would blank every tag in the store. The canonical catalog
            // is `ClipboardStore.tags` (keyed by UUID), so the real tag
            // is available right here.
            //
            // A tag id the catalog does NOT carry is left alone: the
            // item_tags row then fails its foreign key inside
            // `upsertItem`, which is the loud failure we want — a broken
            // reference must not be papered over with a nameless tag
            // (the same stance `ensureTagPlaceholders` documents). The
            // app never creates such a reference: `deleteTag` strips the
            // id from every item's tagIds.
            var seen = Set<UUID>()
            var tagsToUpsert: [Tag] = []
            for item in items {
                for tagID in item.tagIds where !seen.contains(tagID) {
                    seen.insert(tagID)
                    if let tag = tags[tagID] {
                        tagsToUpsert.append(tag)
                    }
                }
            }
            for tag in tagsToUpsert {
                try backend.upsertTag(tag)
            }
            // Per-item upsert + tag attachment. Per docs §3.2.1, the
            // singular attachTag is looped over each tag id (Set<UUID>).
            for item in items {
                try backend.upsertItem(item)
                for tagID in item.tagIds {
                    try backend.attachTag(itemID: item.id, tagID: tagID)
                }
            }
            // Delete-propagation (P2 from auto-review): items present
            // in DB but absent from the new array must be removed.
            let currentIDs = Set(items.map(\.id))
            let dbIDs = try backend.loadAllIDs()
            for staleID in dbIDs.subtracting(currentIDs) {
                try backend.hardDeleteItem(id: staleID)
            }
        } catch {
            // ID-CRASH-0022 (2026-10-20): the rollback must never
            // REPLACE the original error. The backend's exec helpers
            // now throw, so `rollbackTransaction()` can itself throw
            // (e.g. "cannot rollback - no transaction is active"), and
            // a throw from here would hide the real cause (a FK
            // violation, a disk-full) behind a misleading rollback
            // error. Log the rollback failure; re-throw the original.
            do {
                try backend.rollbackTransaction()
            } catch {
                logger.error(
                    "granularSave rollback failed: \(error.localizedDescription, privacy: .public) — re-throwing the original save error"
                )
            }
            throw error
        }
        try backend.commitTransaction()
    }

    /// Schedules a debounced save — coalesces multiple rapid mutations into a single disk write.
    /// The actual write happens after `saveDebounceInterval` seconds of inactivity.
    func scheduleSave() {
        needsSave = true
        // M-2 (2026-07-25 audit): lazily create and reuse the timer source.
        // Repeated scheduleSave() calls previously allocated a new DispatchQueue
        // + DispatchSource on every keystroke / tag change, which showed up in
        // Instruments as allocation churn. `schedule(deadline:)` restarts the
        // existing source's fire time.
        if saveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: saveTimerQueue)
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.flushSave()
                }
            }
            timer.resume()
            saveTimer = timer
        }
        saveTimer?.schedule(deadline: .now() + saveDebounceInterval)
    }

    /// Write-through save used by `importBackupItems` (migration path) —
    /// a crash mid-restore must not half-merge a backup, so the restore
    /// path bypasses the 500ms debounce and forces an immediate flush.
    ///
    /// P1-AUDIT-2026-09-22 (P2-13): capture path no longer calls this.
    /// Clipboard ingestion (`addItem`) now routes through `scheduleSave()`;
    /// durability at capture time relies on the `applicationWillTerminate`
    /// flush path. Metadata mutations (pin/tag/delete/trash) also use the
    /// debounced path — they're restorable from the live item cache if
    /// a kill -9 / power loss lands inside the debounce window.
    func saveImmediately() {
        needsSave = true
        flushSave()
    }

    /// Flushes pending item, tag, and trash saves to disk immediately. Called by the debounce timer,
    /// on deinit, or from AppDelegate.applicationWillTerminate to prevent data loss on quit.
    func flushPendingSaves() {
        // P2-14 round-2 self-review fix [P1-2]: synchronous first-load
        // barrier before encoding `items` to disk.
        //
        // Root cause: applicationShouldTerminate's drain (AppDelegate.swift:209)
        // and applicationWillTerminate (AppDelegate.swift:258) both call this.
        // A user who captures text during the load window and then Cmd+Qs
        // before decode completes would otherwise have the in-memory truncated
        // snapshot (post-addItem, pre-applyLoadResult) written to disk,
        // overwriting the on-disk full history — exactly the data-loss class
        // the batch-7 round-1 placeholder guard had, with a different exit
        // vector. f801c64's conditional `!existingNotInLoaded.isEmpty`
        // scheduleSave only saves when decode lands before the user's next
        // action; the terminate path bypasses that gate entirely.
        //
        // Wait synchronously up to 5s (matches `applicationShouldTerminate`
        // drain's existing watchdog budget — falls through to write truncated
        // state if decode doesn't complete). ID-CRASH-0057: the XCTest init
        // auto-wait was removed (once-reentrancy crash), so this barrier now
        // also services tests that flush before the background load lands —
        // the pump runs OUTSIDE any dispatch_once critical section, which is
        // what made the init variant fatal.
        if !firstLoadCompleted {
            if !waitForFirstLoadSync(timeout: 5.0) {
                // swiftlint:disable:next line_length
                logger.error("P2-14: flushPendingSaves called before firstLoadCompleted (5s timeout) — encoding current items snapshot; on-disk history may be incomplete if load was racing")
            }
        }
        flushSave()
        flushTagSave()
        trashStore.flushPendingSave()
    }

    /// Internal: the actual willTerminate handler body. Extracted so tests
    /// can pin the contract without `NotificationCenter.post` global side
    /// effects (which would fire NSApp + AppDelegate observers).
    func handleWillTerminate() {
        flushPendingSaves()
    }

    // Internal (not private) so tests can pin the failure-recovery contract
    // without driving the public debounce timer. Production call sites remain
    // inside this class: `flushPendingSaves`, `saveImmediately`,
    // `handleWillTerminate`, and the debounce timer's event handler.
    func flushSave() {
        guard needsSave else { return }
        needsSave = false
        // ID-LIFE-0023 (2026-07-31): do NOT cancel() the timer source here.
        // DispatchSource.cancel() is irreversible — a cancelled source
        // silently ignores later schedule() calls, so the old "cancel but
        // keep for reuse" pattern killed every debounced save after the
        // first flush. A fired one-shot source stays reusable via
        // schedule(deadline:); deinit/willTerminate cancel it for real.
        do {
            try saveItems()
            // H-1 (2026-08-08 audit): reset the retry counter on success
            // so a recovered-then-broken-again disk walks the backoff
            // ladder from the base again.
            saveRetryState.recordSuccess()
        } catch {
            // H-1 fix: three legs of the data-persistence gate.
            // 1. 报错 — loud log with attempt count.
            // 2. 重试 — autonomous exponential backoff via the same
            //    saveTimer (reuse, not create a parallel retry queue).
            // 3. 用户可见 — post .clipboardSaveFailed with sourceKey
            //    "saveFlush" so the AppDelegate Throttler can bucket
            //    this independently from .encryptionFailed sources.
            // ID-CRASH-0031 (2026-10-20): `productionWriteBlocked` is
            // PERMANENT — a test process must never write the production
            // domain, and no retry can change that. Retrying it would
            // re-post `.clipboardSaveFailed` every backoff step and pop
            // an alert roughly every 60 s for the life of the process.
            // Fail once, loudly, then stop.
            if let backendError = error as? StorageBackendError,
               case .productionWriteBlocked = backendError {
                needsSave = false
                logger.error("ID-CRASH-0031: production write refused, not retrying (permanent): \(error)")
                NotificationCenter.default.post(
                    name: .clipboardSaveFailed,
                    object: self,
                    userInfo: ["source": "saveFlush"]
                )
                return
            }
            needsSave = true
            saveRetryState.recordFailure()
            let backoff = saveRetryState.nextBackoffSeconds
            logger.error("H-1: saveItems failed (attempt \(self.saveRetryState.consecutiveFailures)): \(error) — auto-retry in \(backoff)s")
            scheduleSaveRetry(after: backoff)
            NotificationCenter.default.post(
                name: .clipboardSaveFailed,
                object: self,
                userInfo: ["source": "saveFlush"]
            )
        }
    }

    /// H-1 (2026-08-08 audit): reschedule `saveTimer` to fire after
    /// `interval` seconds for an autonomous retry. Lazy-creates the timer
    /// source if needed (matches `scheduleSave()`'s reuse pattern).
    private func scheduleSaveRetry(after interval: TimeInterval) {
        let ms = Int(interval * 1000)
        if saveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: saveTimerQueue)
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.flushSave()
                }
            }
            timer.resume()
            saveTimer = timer
        }
        saveTimer?.schedule(deadline: .now() + .milliseconds(ms))
    }
}
