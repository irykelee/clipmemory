import XCTest
import AppKit
@testable import ClipMemory

/// OCR pipeline: model field compatibility, encrypted storage round-trip,
/// search matching, and a real Vision recognition smoke test.
final class OCRTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?
    private var testCrypto: CryptoService!

    override func setUp() {
        super.setUp()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
        testCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.crypto = testCrypto
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.crypto = originalCrypto }
        originalCrypto = nil
        testCrypto = nil
        store = nil
        backend = nil
        super.tearDown()
    }

    // MARK: - Model compatibility

    func testOldJSONWithoutOcrTextDecodesAsNil() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","content":"A.png","type":"image","createdAt":0,
          "isPinned":false,"isSensitive":false,"tagIds":[]}]
        """
        let items = try JSONDecoder().decode([ClipboardItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].ocrText, "old persisted data must decode with ocrText = nil")
    }

    func testCodableRoundTripPreservesOcrText() throws {
        let item = ClipboardItem(content: "A.png", type: .image, ocrText: "v2cipher")
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
        XCTAssertEqual(decoded.first?.ocrText, "v2cipher")
    }

    // MARK: - H-4 (2026-07-24 audit): encrypt-fail path must log + notify

    /// H-4: when OCR text encryption fails, the path used to silently return.
    /// Verify (a) `.encryptionFailed` is posted so AppDelegate can surface it,
    /// (b) the item's ocrText stays nil (no half-attached blob), and
    /// (c) ocrAttempted stays false so the backfill retry still works.
    func testAttachOCRText_encryptFailure_logsAndNotifies() {
        let item = ClipboardItem(content: "A.png", type: .image)
        store.addItem(item)
        // Swap in a crypto stub that returns nil from encrypt() — simulates
        // the rare "key unavailable" failure mode.
        let originalCrypto = ServiceContainer.crypto
        let failingCrypto = FailingEncryptCrypto()
        ServiceContainer.crypto = failingCrypto
        defer { ServiceContainer.crypto = originalCrypto }

        var notificationFired = false
        // nil queue = synchronous delivery on the posting thread. A .main
        // queue makes the assertion race the main runloop (test must yield
        // before the block runs) — flaky/hang-prone in CI environments.
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: nil
        ) { _ in notificationFired = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.attachOCRText(to: item.id, text: "截图里的文字")

        XCTAssertTrue(notificationFired, "Encrypt failure must post .encryptionFailed")
        let stored = store.items.first { $0.id == item.id }
        XCTAssertNil(stored?.ocrText, "OCR text must not be attached on encrypt failure")
        XCTAssertFalse(stored?.ocrAttempted ?? true,
                       "ocrAttempted must stay false so backfill retries")
    }

    /// H-4 (negative control): when the item was deleted between OCR start
    /// and finish, the path must NOT log/notif — that failure is normal
    /// race timing, not an encryption problem.
    func testAttachOCRText_itemMissing_doesNotNotify() {
        let deletedItemId = UUID()
        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: .main
        ) { _ in notificationFired = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.attachOCRText(to: deletedItemId, text: "no such item")

        XCTAssertFalse(notificationFired, "Item-missing path must not post .encryptionFailed")
    }

    // MARK: - H-3 (2026-07-24 audit): encrypt-fail in addItem must log + tag the notification

    /// H-3: when addItem fails to encrypt the content (rare — key
    /// unavailable, per H-2 / C-2), the path must (a) post .encryptionFailed
    /// and (b) tag it with `source = "addItem"` so observers can debounce /
    /// render context-aware alerts independently of HMAC / OCR / ImageStorage
    /// failures. The item must NOT be inserted (N2: storing plaintext when
    /// encryption fails is a security violation).
    func testAddItem_encryptFailure_logsAndTagsNotification() {
        let item = ClipboardItem(content: "secret note", type: .text)
        var capturedUserInfo: [AnyHashable: Any]?
        // nil queue = synchronous delivery on the posting thread (same
        // runloop-race rationale as the H-4 fixture above).
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: nil
        ) { note in capturedUserInfo = note.userInfo }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Swap in a crypto stub whose encrypt() returns nil — simulates
        // the rare "key unavailable" failure mode (same fixture as H-4).
        let originalCrypto = ServiceContainer.crypto
        let failingCrypto = FailingEncryptCrypto()
        ServiceContainer.crypto = failingCrypto
        defer { ServiceContainer.crypto = originalCrypto }

        store.addItem(item)

        XCTAssertNotNil(capturedUserInfo,
                        "Encrypt failure in addItem must post .encryptionFailed (H-3)")
        XCTAssertEqual(capturedUserInfo?["source"] as? String, "addItem",
                       "Notification must tag the source so observers can debounce")
        XCTAssertEqual(capturedUserInfo?["itemType"] as? String, "text",
                       "Notification must include itemType for context-aware alerts")
        XCTAssertTrue(store.items.isEmpty,
                      "Item must be discarded (NOT stored as plaintext) on encrypt failure (N2)")
    }

    // MARK: - Encrypted storage round-trip

    func testAttachOCRTextEncryptsAndDecrypts() {
        let item = ClipboardItem(content: "A.png", type: .image)
        store.addItem(item)

        store.attachOCRText(to: item.id, text: "截图里的文字")

        let stored = store.items.first
        XCTAssertNotNil(stored?.ocrText)
        XCTAssertNotEqual(stored?.ocrText, "截图里的文字", "must be encrypted at rest")
        XCTAssertEqual(store.getDecryptedOcrText(stored!), "截图里的文字")
    }

    func testGetDecryptedOcrTextNilForNonImage() {
        let item = ClipboardItem(content: "plain", type: .text)
        store.addItem(item)
        XCTAssertNil(store.getDecryptedOcrText(store.items[0]))
    }

    // MARK: - STOR-2: ocrText/ocrAttempted must survive member-wise rebuilds

    /// The `with(...)` helper is the anti-STOR-2 contract: overriding one
    /// field must keep every other field — especially ocrText/ocrAttempted,
    /// which six rebuild sites silently dropped before 2026-07-25.
    func testWithHelperPreservesOcrAndAllUntouchedFields() {
        let original = ClipboardItem(
            content: "A.png", type: .image,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: true, isSensitive: true,
            isEncrypted: true, contentHash: "hash",
            decryptionFailed: true, tagIds: [UUID()],
            deletedAt: Date(timeIntervalSince1970: 1_700_000_100),
            ocrText: "v2:ciphertext", ocrAttempted: true
        )
        let copy = original.with(isEncrypted: false)

        XCTAssertEqual(copy.id, original.id)
        XCTAssertEqual(copy.content, original.content)
        XCTAssertEqual(copy.type, original.type)
        XCTAssertEqual(copy.createdAt, original.createdAt)
        XCTAssertTrue(copy.isPinned)
        XCTAssertTrue(copy.isSensitive)
        XCTAssertEqual(copy.contentHash, "hash")
        XCTAssertTrue(copy.decryptionFailed)
        XCTAssertEqual(copy.tagIds, original.tagIds)
        XCTAssertEqual(copy.deletedAt, original.deletedAt)
        XCTAssertEqual(copy.ocrText, "v2:ciphertext", "STOR-2: ocrText must survive rebuild")
        XCTAssertTrue(copy.ocrAttempted, "STOR-2: ocrAttempted must survive rebuild")
        XCTAssertFalse(copy.isEncrypted, "the overridden field must actually change")
    }

    /// loadItems repairs legacy image items (isEncrypted/decryptionFailed were
    /// wrongly set by an old code path). The repair rebuild must not erase OCR
    /// data — previously it rebuilt the item member-by-member without ocrText.
    func testLoadItemsRepairPreservesOcrFields() throws {
        let legacy = ClipboardItem(
            content: "B.png", type: .image,
            isEncrypted: true,           // legacy broken flag — repair resets it
            decryptionFailed: true,      // ditto
            ocrText: "v2:encrypted-ocr", ocrAttempted: true
        )
        try backend.save([legacy])

        store.loadItems()

        XCTAssertEqual(store.items.count, 1)
        let repaired = store.items[0]
        XCTAssertFalse(repaired.isEncrypted, "repair must reset isEncrypted")
        XCTAssertFalse(repaired.decryptionFailed, "repair must reset decryptionFailed")
        XCTAssertEqual(repaired.ocrText, "v2:encrypted-ocr", "STOR-2: repair must keep ocrText")
        XCTAssertTrue(repaired.ocrAttempted, "STOR-2: repair must keep ocrAttempted")
    }

    // MARK: - Search matching

    func testImageItemMatchesByOcrText() {
        var item = ClipboardItem(content: "shot.png", type: .image)
        store.addItem(item)
        store.attachOCRText(to: item.id, text: "HELLO 世界")

        let matches = store.items.filter {
            ($0.type == .image ? (store.getDecryptedOcrText($0) ?? "") : "")
                .localizedCaseInsensitiveContains("hello")
        }
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - Real Vision smoke test

    func testVisionRecognizesRenderedText() {
        let image = Self.renderTextImage("HELLO")
        guard let tiff = image.tiffRepresentation else {
            XCTFail("cannot render test image")
            return
        }
        let expectation = expectation(description: "ocr")
        VisionOCRService.shared.recognizeText(in: tiff) { text in
            XCTAssertNotNil(text, "Vision should find text in the rendered image")
            if let text = text {
                XCTAssertTrue(text.contains("HELLO"), "expected HELLO in: \(text)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
    }

    // MARK: - Backfill self-healing

    /// Mock recognizer: returns fixed text for any image data.
    private struct MockOCR: OCRServiceProtocol {
        var result: String?
        func recognizeText(in imageData: Data, completion: @escaping (String?) -> Void) {
            completion(result)
        }
    }

    private func seedImageFile() -> String {
        let name = "\(UUID().uuidString).png"
        let url = ImageStorage.shared.imagesDirectoryURL.appendingPathComponent(name)
        let image = Self.renderTextImage("BACKFILL")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return name
        }
        try? pngData.write(to: url)
        return name
    }

    func testBackfillIsSelfHealingAndIdempotent() {
        let filename = seedImageFile()
        let item = ClipboardItem(content: filename, type: .image)
        store.addItem(item)

        // First pass: attaches text + marks attempted
        store.backfillOCRIfNeeded(using: MockOCR(result: "回填文字"), imageStorage: .shared)
        let exp1 = expectation(description: "backfill attach")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exp1.fulfill() }
        wait(for: [exp1], timeout: 10)

        let after = store.items.first(where: { $0.id == item.id })
        XCTAssertEqual(after?.ocrAttempted, true)
        XCTAssertEqual(after.flatMap { store.getDecryptedOcrText($0) }, "回填文字")

        // Second pass must be a no-op (already attempted)
        store.backfillOCRIfNeeded(using: MockOCR(result: "不应覆盖"), imageStorage: .shared)
        let exp2 = expectation(description: "second pass")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp2.fulfill() }
        wait(for: [exp2], timeout: 10)
        XCTAssertEqual(after.flatMap { store.getDecryptedOcrText($0) }, "回填文字")
    }

    func testBackfillDoesNotMarkMissingFiles() {
        let item = ClipboardItem(content: "\(UUID().uuidString).png", type: .image)
        store.addItem(item) // 无对应文件

        store.backfillOCRIfNeeded(using: MockOCR(result: "x"), imageStorage: .shared)
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 10)

        let after = store.items.first(where: { $0.id == item.id })
        XCTAssertEqual(after?.ocrAttempted, false,
                       "file-missing items must stay un-attempted so a later launch can retry")
    }

    private static func renderTextImage(_ text: String) -> NSImage {
        let size = NSSize(width: 400, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size.width, height: size.height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 30, y: 25), withAttributes: attributes)
        image.unlockFocus()
        return image
    }
}

// H-4 (2026-07-24 audit): test stub. Conforms to CryptoServiceProtocol so
// ServiceContainer.crypto can be swapped in tests. encrypt / encryptData
// always return nil to simulate the rare "key unavailable" failure mode
// (e.g. Keychain locked during launchd start, per C-2). Other methods
/// are not exercised by the H-4 path so they return harmless defaults.
private struct FailingEncryptCrypto: CryptoServiceProtocol {
    func encrypt(_ string: String) -> String? { nil }
    func decrypt(_ base64String: String) -> String? { nil }
    func encryptData(_ data: Data) -> Data? { nil }
    func decryptData(_ combined: Data) -> Data? { nil }
    func isOldFormat(_ base64String: String) -> Bool { false }
    func migrateToV2(_ base64String: String) -> String? { nil }
    func hmacHex(for string: String) -> String? { nil }
}
