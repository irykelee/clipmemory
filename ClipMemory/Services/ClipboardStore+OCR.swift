import Foundation
import os

/// OCR-related ClipboardStore extension (kept out of the main file per the
/// project's small-file guideline). See OCRService.swift for recognition.
extension ClipboardStore {
    private static let ocrEnabledKey = "ocrEnabled"

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
    func attachOCRText(to itemId: UUID, text: String) {
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
            guard let index = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.items[index].ocrText = encrypted
            self.items[index].ocrAttempted = true
            // H-1 (2026-07-25 audit): OCR text is derived metadata. Using
            // saveImmediately() here caused every backfilled image to trigger a
            // full JSON encode of all items on the main thread; with hundreds
            // of images this froze the UI on first launch. Debounce through
            // scheduleSave() so concurrent OCR results coalesce into one write.
            self.scheduleSave()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
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
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Decrypts the stored OCR text of an image item (nil when not recognized).
    func getDecryptedOcrText(_ item: ClipboardItem) -> String? {
        guard item.type == .image, let ciphertext = item.ocrText else { return nil }
        let key = (item.id.uuidString + ".ocr") as NSString
        if let cached = contentCache.object(forKey: key) {
            return cached as String
        }
        guard let plaintext = ServiceContainer.crypto.decrypt(ciphertext) else { return nil }
        contentCache.setObject(plaintext as NSString, forKey: key)
        return plaintext
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
                        Self.logger.error("OCR backfill failed for \(item.id): \(error.localizedDescription, privacy: .public)")
                        self?.markOCRAttempted(itemId: item.id)
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
