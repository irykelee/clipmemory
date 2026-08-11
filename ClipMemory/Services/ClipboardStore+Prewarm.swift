//
//  ClipboardStore+Prewarm.swift
//  ClipMemory
//
//  ARCH-0002 PR #2 (2026-08-11): prewarm methods extracted from
//  ClipboardStore.swift into a pure extension. Zero logic change — methods
//  are copied verbatim. State (`lastViewPrewarmTime`, `pendingPrewarmWorkItem`,
//  `prewarmStateLock`, `prewarmInFlight`, `prewarmPendingItems`,
//  `prewarmPendingCompletions`) stays in the main class body because Swift
//  extensions can't have stored properties.
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

    /// P0-3: background pre-warm of contentCache + rtfPlaintextCache.
    /// Iterates items on a utility queue, calling getDecryptedContent (and
    /// getRTFPlaintext for richText items) for each uncached item. The decrypt
    /// runs off the main thread; results are stored in NSCache (thread-safe).
    /// After completion, the search filter path reads from cache (fast path).
    ///
    /// Capped at `cap` items to avoid saturating the utility queue on large
    /// histories. Pass nil to prewarm all items. Call from updateDisplayedItemsCache
    /// (ContentView) / recomputeDisplayedItems (QuickBarView) after each filter pass.
    ///
    /// ID-PERF-0004 (2026-07-30 audit): concurrent decrypts gated by
    /// `prewarmMaxConcurrent` (DispatchSemaphore), matching the OCR backfill
    /// pattern. Mirroring backfillMaxConcurrentOCR's value so the codebase
    /// has one cap for "compute-bound per-item work".
    private static let prewarmMaxConcurrent = 4

    /// ID-PERF-0023 (2026-08-02 audit): view-driven prewarm entry with the
    /// same 5 s throttle as AppDelegate's activation prewarm
    /// (`lastPrewarmTime`, AppDelegate.swift:323). ID-VIEW-0012 made the two
    /// view call sites (ContentView / QuickBarView) feed the FULL item set
    /// after every debounced search / items change, so the main-thread
    /// uncached filter in prewarmDecryptionCache ran per keystroke. Both
    /// views now go through this shared wrapper — one timestamp for both,
    /// so ContentView and QuickBarView can't each trigger their own pass
    /// inside the same window. AppDelegate's observer prewarm, the
    /// new-capture single-item prewarm (:1347), and tests keep calling
    /// prewarmDecryptionCache directly (unthrottled).
    func prewarmDecryptionCacheThrottled(items: [ClipboardItem], interval: TimeInterval = 5) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastViewPrewarmTime)
        if elapsed >= interval {
            // Inside window — prewarm now and cancel any pending re-fire.
            lastViewPrewarmTime = now
            pendingPrewarmWorkItem?.cancel()
            pendingPrewarmWorkItem = nil
            prewarmDecryptionCache(items: items)
        } else {
            // ID-PERF-0024 (2026-08-03 audit): previous `return` lost these
            // items forever when no subsequent call landed after the window
            // (active-state scenario: QuickBar close→reopen <5s + stop).
            // Schedule a delayed re-fire that updates the timestamp and
            // re-enters prewarm with the dropped items. Latest-wins is
            // acceptable because view-driven callers (ContentView /
            // QuickBarView) feed the full item set per ID-VIEW-0012.
            pendingPrewarmWorkItem?.cancel()
            let delay = interval - elapsed
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingPrewarmWorkItem = nil
                self.lastViewPrewarmTime = Date()
                self.prewarmDecryptionCache(items: items)
            }
            pendingPrewarmWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func prewarmDecryptionCache(items: [ClipboardItem], cap: Int? = nil, completion: (() -> Void)? = nil) {
        let workingSet = cap.map { items.prefix($0) } ?? items.prefix(items.count)
        let uncached = workingSet.filter { item in
            guard !item.decryptionFailed else { return false }
            let key = item.id.uuidString as NSString
            let contentCold = contentCache.object(forKey: key) == nil
            let rtfCold = item.type == .richText && contentCold
            let ocrKey = (item.id.uuidString + ".ocr") as NSString
            let ocrCold = item.type == .image && item.ocrText != nil && contentCache.object(forKey: ocrKey) == nil
            return contentCold || rtfCold || ocrCold
        }
        guard !uncached.isEmpty else {
            completion?()
            return
        }
        // ID-PERF-0019: coalesce with a running batch instead of overlapping.
        prewarmStateLock.lock()
        if prewarmInFlight {
            prewarmPendingItems = Array(uncached)
            if let completion { prewarmPendingCompletions.append(completion) }
            prewarmStateLock.unlock()
            return
        }
        prewarmInFlight = true
        prewarmStateLock.unlock()

        // ID-PERF-0004 (2026-07-30 audit): cap concurrent decrypts via
        // DispatchSemaphore, mirroring the OCR backfill pattern (L-7). The
        // previous sequential for-loop on a single utility queue was 10-100s
        // for a 10K-item cold cache (e.g. wake-from-sleep); 4 concurrent
        // AES-GCM decrypts brings this to ~2-25s while still bounding memory.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                Task { @MainActor in completion?() }
                return
            }
            self.runPrewarmBatches(firstRound: Array(uncached), firstCompletion: completion)
        }
    }

    /// ID-PERF-0019 (2026-08-01 audit): one decrypt round, then an immediate
    /// follow-up round for any request coalesced while the round was running.
    /// Each round notifies its own completions exactly once on the main thread
    /// and sends objectWillChange (the round did real decrypt work), matching
    /// the pre-coalescing per-batch semantics.
    ///
    /// ID-SYNC-0003: nonisolated — the per-item calls hit only the nonisolated
    /// decrypt kernels (getDecryptedContent / getRTFPlaintext /
    /// getDecryptedOcrText), which touch thread-safe state exclusively.
    nonisolated private func runPrewarmBatches(firstRound: [ClipboardItem], firstCompletion: (() -> Void)?) {
        var round = firstRound
        var roundCompletions: [() -> Void] = firstCompletion.map { [$0] } ?? []
        while true {
            let semaphore = DispatchSemaphore(value: Self.prewarmMaxConcurrent)
            let group = DispatchGroup()
            for item in round {
                semaphore.wait()
                group.enter()
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    _ = self?.getDecryptedContent(item)
                    if item.type == .richText { _ = self?.getRTFPlaintext(item) }
                    if item.type == .image { _ = self?.getDecryptedOcrText(item) }
                    semaphore.signal()
                    group.leave()
                }
            }
            group.wait()
            // Notify this round's requesters, then check whether a newer
            // request was coalesced while the round was working.
            let finishedCompletions = roundCompletions
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                finishedCompletions.forEach { $0() }
            }
            prewarmStateLock.lock()
            if let pending = prewarmPendingItems {
                prewarmPendingItems = nil
                let pendingCompletions = prewarmPendingCompletions
                prewarmPendingCompletions = []
                prewarmStateLock.unlock()
                round = pending
                roundCompletions = pendingCompletions
            } else {
                prewarmInFlight = false
                prewarmStateLock.unlock()
                return
            }
        }
    }
}