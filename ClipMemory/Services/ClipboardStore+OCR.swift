import Foundation
import os

/// OCR-related ClipboardStore extension (kept out of the main file per the
/// project's small-file guideline). See OCRService.swift for recognition.
extension ClipboardStore {
    private static let ocrEnabledKey = "ocrEnabled"

    private static let ocrPreviewEnabledKey = "ocrPreviewEnabled"

    /// Whether image search results show OCR text snippet + highlight under the
    /// thumbnail. Display-only — filter still uses OCR text even when off. Default on.
    var ocrPreviewEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.ocrPreviewEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.ocrPreviewEnabledKey) }
    }

    // H-4 (2026-07-24 audit): logger for OCR-specific failures. Mirrors the
    // category pattern used elsewhere (e.g. ImageStorage uses subsystem
    // "com.clipmemory.app" with its own category).
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "OCR")

    /// Whether on-device OCR runs for newly captured images. Default on.
    var ocrEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.ocrEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.ocrEnabledKey) }
    }

    /// Attaches OCR-recognized plaintext (encrypted at rest) to an image item.
    /// Called from background OCR pipelines; hops to main for the @Published write.
    ///
    /// ID-OCR-0004 (2026-07-30 audit): `contentHash` is the HMAC of the
    /// original image bytes. When the original item UUID was deduped away
    /// by `addItem`'s hash-matches-existing branch (the existing item was
    /// promoted to the top of the list and the new UUID was discarded),
    /// the direct `firstIndex(where: { $0.id == itemId })` lookup fails
    /// and the OCR result for the new UUID is silently dropped. With
    /// `contentHash`, the fallback path walks `items` for an
    /// `image`-typed entry whose `contentHash` matches and attaches the
    /// OCR text to that surviving entry — preserving the OCR work and,
    /// critically, allowing a previously-failed OCR to be retried simply
    /// by re-copying the image.
    func attachOCRText(to itemId: UUID, text: String, contentHash: String? = nil) {
        let apply = { [weak self] in
            guard let self = self else { return }
            // H-4 (2026-07-24 audit): split the combined guard so encrypt
            // failure logs + posts .encryptionFailed. Previously the chained
            // guard made "encrypt failed" indistinguishable from "item
            // missing", so OCR text silently disappeared with no diagnostic
            // trail (the user saw "no text recognized" for every image).
            // Item-missing (race after delete) is NOT a crypto failure —
            // don't notify in that case.
            guard let encrypted = ServiceContainer.crypto.encrypt(text) else {
                Self.logger.error("OCR text encryption failed; dropping OCR result")
                NotificationCenter.default.post(name: .encryptionFailed, object: nil)
                return
            }
            // ID-OCR-0004: prefer the direct id lookup; fall back to
            // contentHash when the original UUID was deduped away.
            let directIndex = self.items.firstIndex(where: { $0.id == itemId })
            let index: Int?
            if let directIndex = directIndex {
                index = directIndex
            } else if let contentHash = contentHash {
                index = self.items.firstIndex(where: { $0.type == .image && $0.contentHash == contentHash })
                if index != nil {
                    Self.logger.error("OCR result routed via contentHash fallback (id \(itemId, privacy: .public) was deduped away); attaching to surviving item")
                }
            } else {
                index = nil
            }
            guard let index = index else { return }
            self.items[index].ocrText = encrypted
            self.items[index].ocrAttempted = true
            // H-1 (2026-07-25 audit): OCR text is derived metadata. Using
            // saveImmediately() here caused every backfilled image to trigger a
            // full JSON encode of all items on the main thread; with hundreds
            // of images this froze the UI on first launch. Debounce through
            // scheduleSave() so concurrent OCR results coalesce into one write.
            self.scheduleSave()
        }
        // v2.7.0 hotfix (2026-07-28): reverted from `Task { @MainActor in
        // apply() }` back to `DispatchQueue.main.async` after a production
        // deadlock was discovered. Root cause: Vision's
        // `runSuccessReportingBlockSynchronously` calls the OCR success block
        // via GCD main queue (`dispatch_sync(main_queue, block)`), and the
        // success block writes `self.items[index]` + `scheduleSave()` which
        // synchronously modifies a `DispatchSourceTimer`. Swift Concurrency
        // `Task { @MainActor in ... }` is dispatched via Swift's main actor
        // executor, NOT the GCD main queue — so Vision's GCD sync never sees
        // the Task run, the main thread stays inside the Vision success block,
        // and `DispatchSourceTimer.cancel()` in `scheduleSave()` deadlocks
        // waiting for the same main thread to drain the timer queue.
        // The v2.5.10 GCD async pattern survives because Vision's sync invoke
        // routes through the GCD main queue the same way the original
        // `apply()` did, and the main runloop drains the block before Vision
        // returns to its caller.
        // See lldb captures: thread #10 stuck in
        // `[VNDetector runSuccessReportingBlockSynchronously:]_block_invoke`
        // waiting on `dispatch_block_sync_invoke`; thread #11 in
        // `VNRecognizeTextRequestRevision3` waiting on a semaphore that
        // thread #10 holds.
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Marks an item as OCR-attempted without a result (no text recognized).
    /// Items whose image file is missing are deliberately NOT marked — a later
    /// launch (or the restored file) can still be backfilled.
    func markOCRAttempted(itemId: UUID) {
        let apply = { [weak self] in
            guard let self = self,
                  let index = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            guard !self.items[index].ocrAttempted else { return }
            self.items[index].ocrAttempted = true
            self.scheduleSave()
        }
        // v2.7.0 hotfix (2026-07-28): see attachOCRText comment above for the
        // full deadlock analysis. Same GCD-async pattern keeps Vision happy.
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Decrypts the stored OCR text of an image item (nil when not recognized).
    /// P0-2 T5: switched from blind `decrypt` to `decryptWithReason` so OCR-path
    /// failures feed into DecryptionDiagnostics. Per N10, `.keyUnavailable` is
    /// transient — never marks `decryptionFailed`. Data corruption here also
    /// does NOT mark `decryptionFailed` on the item because that flag controls
    /// the search path's retry of `item.content`, not OCR text.
    /// ID-SYNC-0003 (2026-08-01 audit): nonisolated decrypt kernel — touches
    /// only contentCache (NSCache), ServiceContainer.crypto (internally
    /// locked), and recordPendingDiagnostic (NSLock). Callable off-main.
    nonisolated func getDecryptedOcrText(_ item: ClipboardItem) -> String? {
        guard item.type == .image, let ciphertext = item.ocrText else { return nil }
        let key = (item.id.uuidString + ".ocr") as NSString
        if let cached = contentCache.object(forKey: key) {
            return cached as String
        }
        let outcome = ServiceContainer.crypto.decryptWithReason(ciphertext, itemID: item.id)
        switch outcome {
        case .success(let plaintext):
            contentCache.setObject(plaintext as NSString, forKey: key)
            return plaintext
        case .keyUnavailable:
            // N10: transient — do NOT mark decryptionFailed
            recordPendingDiagnostic(.keyUnavailable)
            return nil
        case .dataCorrupted:
            recordPendingDiagnostic(.dataCorrupted)
            return nil
        case .internalError:
            recordPendingDiagnostic(.internalError)
            return nil
        }
    }

    /// NEW-B (2026-07-27 review): search filter (ContentView) and OCR snippet
    /// (ClipboardItemRow) used to disagree on what counts as "the OCR text" —
    /// filter tested raw text via `localizedCaseInsensitiveContains`, while
    /// the snippet path sanitized (dropped ZWJ / combining marks / control
    /// chars) before matching. A search term spanning a stripped character
    /// would mark the row as a match while the snippet rendered empty — the
    /// "found but not highlighted" UX bug.
    ///
    /// Both paths now consume the same sanitized OCR text. If a caller still
    /// wants raw text (tests, live-reveal path), use `getDecryptedOcrText`
    /// directly.
    func getSanitizedDecryptedOcrText(_ item: ClipboardItem) -> String? {
        guard let raw = getDecryptedOcrText(item) else { return nil }
        return Self.sanitizeOCR(raw)
    }

    /// NEW-B: shared sanitization for OCR text. Drops control chars,
    /// combining marks, format chars, and ZWJ / variation selectors that
    /// Vision occasionally emits. Whitespace (including newlines) is
    /// preserved so multi-line OCR output renders cleanly.
    private static func sanitizeOCR(_ s: String) -> String {
        s.filter { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0.isWhitespace }
    }

    /// Self-healing backfill: OCR every image item not yet attempted. Runs on a
    /// serial background queue on each launch; per-item `ocrAttempted` marking
    /// (instead of a global one-shot flag) means a quit mid-run, a later import,
    /// or a test-host launch can never permanently poison the backfill.
    ///
    /// L-7 (2026-07-24 audit): cap concurrent in-flight OCR jobs to prevent
    /// hundreds of concurrent Vision invocations when a large library is
    /// backfilled in one burst — Vision is compute-bound and unbounded
    /// concurrency causes UI freezes + memory spikes on first launch.
    /// Behavior is otherwise unchanged; this only adds backpressure.
    ///
    /// ID-OCR-0003 (2026-07-30 audit): the *Vision* execution is bounded at
    /// 1 by the serial `com.clipmemory.ocr` queue inside VisionOCRService
    /// (regardless of this cap's value), so the comment's "Vision
    /// concurrency" rationale is misleading. The cap's actual role is to
    /// bound the number of *decrypted image Data buffers* held in memory
    /// while waiting for the serial queue to drain — a 6K HEIC image is
    /// ~50 MB decrypted, and 4 parallel buffers = ~200 MB resident during
    /// a backfill burst. Raising the cap trades memory for backfill
    /// throughput; lowering it does the opposite. Keep at 4 to match the
    /// prewarmMaxConcurrent cap (clipboard prewarm) so the codebase has
    /// one global "buffer-bound concurrency" knob.
    ///
    /// MED-3 (2026-07-26 review): added `onComplete` callback fired when all
    /// candidates have been processed, so tests can wait deterministically
    /// instead of relying on asyncAfter + timeout.
    func backfillOCRIfNeeded(using ocr: OCRServiceProtocol = VisionOCRService.shared,
                             imageStorage: ImageStorage = .shared,
                             onComplete: (() -> Void)? = nil) {
        guard ocrEnabled else { onComplete?(); return }
        let candidates = items.filter { $0.type == .image && $0.ocrText == nil && !$0.ocrAttempted }
        guard !candidates.isEmpty else { onComplete?(); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let semaphore = DispatchSemaphore(value: Self.backfillMaxConcurrentOCR)
            let group = DispatchGroup()
            for item in candidates {
                semaphore.wait()  // backpressure: blocks when N OCRs are in flight
                guard let data = imageStorage.loadImage(filename: item.content) else {
                    semaphore.signal()
                    continue
                }
                group.enter()
                ocr.recognizeText(in: data) { [weak self] outcome in
                    // BUG-010 (2026-07-21): do NOT mark ocrAttempted before
                    // OCR completes. If `attachOCRText`'s encrypt() failed
                    // (e.g. CryptoService unavailable), ocrAttempted was
                    // already true → item permanently lost OCR retry.
                    // Now: only mark on no-result; successful attach sets
                    // ocrAttempted=true internally (L22).
                    switch outcome {
                    case .text(let text) where !text.isEmpty:
                        self?.attachOCRText(to: item.id, text: text)
                    case .text, .noText:
                        self?.markOCRAttempted(itemId: item.id)
                    case .failure(let error):
                        // ID-OCR-0008 (2026-07-31 audit): do NOT mark
                        // ocrAttempted on failure. Vision throws, the 15 s
                        // watchdog timeout (ID-OCR-0006), and load-induced
                        // cancels are all transient — marking made those
                        // images permanently lose OCR with no signal.
                        // Leaving ocrAttempted=false lets the next launch's
                        // backfill retry automatically — the same
                        // self-healing contract as the missing-file path
                        // and BUG-010's encrypt-failure path above.
                        Self.logger.error("OCR backfill failed for \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public); ocrAttempted stays false so a later backfill retries")
                    }
                    semaphore.signal()  // release slot only after OCR result lands
                    group.leave()
                }
            }
            group.notify(queue: .main) { onComplete?() }
        }
    }

    /// L-7 (2026-07-24 audit): max concurrent OCR jobs during backfill.
    /// Picked at 4 to keep Vision (CPU + GPU bound) under control without
    /// serializing the whole backfill — a 200-image library finishes roughly
    /// twice as fast as fully serial but doesn't trigger the OS-level Vision
    /// throttle that comes in at ~8+ simultaneous requests.
    private static let backfillMaxConcurrentOCR = 4
}
