import Foundation

/// OCR-related ClipboardStore extension (kept out of the main file per the
/// project's small-file guideline). See OCRService.swift for recognition.
extension ClipboardStore {
    private static let ocrEnabledKey = "ocrEnabled"

    /// Whether on-device OCR runs for newly captured images. Default on.
    var ocrEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.ocrEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.ocrEnabledKey) }
    }

    /// Attaches OCR-recognized plaintext (encrypted at rest) to an image item.
    /// Called from background OCR pipelines; hops to main for the @Published write.
    func attachOCRText(to itemId: UUID, text: String) {
        let apply = { [weak self] in
            guard let self = self,
                  let encrypted = ServiceContainer.crypto.encrypt(text),
                  let index = self.items.firstIndex(where: { $0.id == itemId }) else { return }
            self.items[index].ocrText = encrypted
            self.items[index].ocrAttempted = true
            self.saveImmediately()
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
    func backfillOCRIfNeeded(using ocr: OCRServiceProtocol = VisionOCRService.shared, imageStorage: ImageStorage = .shared) {
        guard ocrEnabled else { return }
        let candidates = items.filter { $0.type == .image && $0.ocrText == nil && !$0.ocrAttempted }
        guard !candidates.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for item in candidates {
                guard let data = imageStorage.loadImage(filename: item.content) else { continue }
                ocr.recognizeText(in: data) { [weak self] text in
                    // BUG-010 (2026-07-21): do NOT mark ocrAttempted before
                    // OCR completes. If `attachOCRText`'s encrypt() failed
                    // (e.g. CryptoService unavailable), ocrAttempted was
                    // already true → item permanently lost OCR retry.
                    // Now: only mark on no-result; successful attach sets
                    // ocrAttempted=true internally (L22).
                    if let text = text, !text.isEmpty {
                        self?.attachOCRText(to: item.id, text: text)
                    } else {
                        self?.markOCRAttempted(itemId: item.id)
                    }
                }
            }
        }
    }
}
