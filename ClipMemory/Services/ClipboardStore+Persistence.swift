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
        // ID-SILENT-0021 (2026-08-08 audit): rethrows on backend failure so
        // `flushSave` can restore `needsSave = true` and post
        // `.clipboardSaveFailed` for UI surfacing. Previously the inner
        // catch only logged, leaving `needsSave = false`, so the next
        // debounce timer exited via the early `guard` — silent data loss.
        let snapshot = items
        let data = try itemEncodingQueue.sync {
            try itemsSaveEncoder.encode(snapshot)
        }
        try backend.saveBlob(data)
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
        // state if decode doesn't complete). In XCTest, init's auto-wait
        // already flipped `firstLoadCompleted` so this is a no-op for tests.
        if !firstLoadCompleted {
            if !waitForFirstLoadSync(timeout: 5.0) {
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