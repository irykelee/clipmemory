import XCTest
@testable import ClipMemory

/// P0-2 T5: DecryptionDiagnostics state machine + buffer→async-merge (F4 anti-view-body-publish)
@MainActor
final class ClipboardStoreDiagnosticsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        // N7: reset shared diagnostics so test state doesn't leak across tests.
        ClipboardStore.shared.diagnostics = .init()
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        ClipboardStore.shared.diagnostics = .init()
        super.tearDown()
    }

    func testDiagnosticsInitialEmpty() {
        let store = ClipboardStore.shared
        XCTAssertFalse(store.diagnostics.keyUnavailable)
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 0)
    }

    func testKeyUnavailableAggregatedToBool() {
        let store = ClipboardStore.shared
        store.testAddPendingDiagnostic(.keyUnavailable)
        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait diagnostics merge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(store.diagnostics.keyUnavailable)
    }

    func testDataCorruptedCounted() {
        let store = ClipboardStore.shared
        store.testAddPendingDiagnostic(.dataCorrupted)
        store.testAddPendingDiagnostic(.dataCorrupted)
        store.testAddPendingDiagnostic(.internalError)
        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 2)
        XCTAssertEqual(store.diagnostics.internalErrorCount, 1)
    }

    func testDismissedFlagToggles() {
        let store = ClipboardStore.shared
        store.diagnostics.dismissed = true
        XCTAssertTrue(store.diagnostics.dismissed)
    }

    func testMergeIsAsyncNotBlocking() {
        let store = ClipboardStore.shared
        store.testAddPendingDiagnostic(.keyUnavailable)
        let beforeMerge = store.diagnostics.keyUnavailable
        store.mergePendingDiagnostics()
        XCTAssertEqual(beforeMerge, store.diagnostics.keyUnavailable,
                       "mergePendingDiagnostics must async-update @Published, not sync-publish")
    }

    func testEmptySnapshotSetsZeroState() {
        // N4: without the empty-early-return, even an empty snapshot must SET zero state
        let store = ClipboardStore.shared
        store.diagnostics = .init(keyUnavailable: true, dataCorruptedCount: 5, internalErrorCount: 0, dismissed: false)
        // pendingDiagnostics is empty by default
        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait zero state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(store.diagnostics.keyUnavailable, "empty snapshot must SET zero state")
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 0)
    }

    // MARK: - P0-2 T5: OCR path diagnostic tracking

    /// P0-2 T5: OCR path (.keyUnavailable) appends diagnostic without marking
    /// decryptionFailed on the item (N10).
    func testOcrPathKeyUnavailableAppendsDiagnostic() {
        let store = ClipboardStore.shared
        // Ensure items are clean before this test
        store.items.removeAll()
        store.diagnostics = .init()

        // Add an image item and attach OCR text using real crypto
        let item = ClipboardItem(content: "ocr-test.png", type: .image)
        store.addItem(item)
        guard let stored = store.items.first else { XCTFail("item not added"); return }
        store.attachOCRText(to: stored.id, text: "diagnostic test text")

        // Simulate key unavailable
        CryptoService.simulateKeyLoadAttemptedForTesting()

        // Call the OCR decrypt path
        let result = store.getDecryptedOcrText(store.items.first!)
        XCTAssertNil(result, "key unavailable must return nil")

        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait ocr keyUnavailable merge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(store.diagnostics.keyUnavailable, "OCR keyUnavailable must set diagnostic flag")

        // N10: OCR path must NEVER mark decryptionFailed
        XCTAssertFalse(store.items.first?.decryptionFailed ?? true,
                       "N10: OCR keyUnavailable must NOT mark decryptionFailed")
    }

    /// P0-2 T5: OCR path data corruption is tracked as diagnostic.
    func testOcrPathDataCorruptedAppendsDiagnostic() {
        let store = ClipboardStore.shared
        store.items.removeAll()
        store.diagnostics = .init()

        // Add image item + attach OCR text with real crypto
        let item = ClipboardItem(content: "ocr-corr.png", type: .image)
        store.addItem(item)
        guard let stored = store.items.first else { XCTFail("item not added"); return }
        store.attachOCRText(to: stored.id, text: "will be corrupted")

        // Swap to a mock that returns .dataCorrupted for decryptWithReason
        let mock = OCRCorruptCrypto()
        let originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(mock)
        defer { ServiceContainer.setCryptoForTesting(originalCrypto) }

        // Clear content cache so we bypass the cached success from attachOCRText
        store.contentCache.removeAllObjects()

        let result = store.getDecryptedOcrText(store.items.first!)
        XCTAssertNil(result, "data corrupted must return nil")

        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait ocr dataCorrupted merge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 1, "OCR dataCorrupted must be counted")
    }

    // MARK: - P0-2 T5: RTF path diagnostic tracking

    /// P0-2 T5: RTF path (.keyUnavailable) appends diagnostic and does NOT
    /// cache the fallback label — retry after key becomes available must succeed.
    func testRtfPathKeyUnavailableNotCached() {
        let store = ClipboardStore.shared
        store.items.removeAll()
        store.diagnostics = .init()

        // Real RTF data: base64-encoded minimal RTF so RichTextParser succeeds.
        let rtfString = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Times;}}\n\\f0 Hello RTF\n}"
        guard let rtfData = rtfString.data(using: .utf8) else {
            XCTFail("failed to encode RTF string")
            return
        }
        let rtfBase64 = rtfData.base64EncodedString()
        let item = ClipboardItem(content: rtfBase64, type: .richText)
        store.addItem(item)
        guard store.items.first?.isEncrypted == true else {
            XCTFail("item must be encrypted after addItem")
            return
        }

        // Simulate key unavailable
        CryptoService.simulateKeyLoadAttemptedForTesting()

        let fallback = store.getRTFPlaintext(store.items.first!)
        XCTAssertFalse(fallback.isEmpty, "must return fallback label even when key unavailable")
        // The fallback is L10n.itemRichText, not the RTF content
        XCTAssertNotEqual(fallback, "Hello RTF",
                          "must not return plaintext when key unavailable")

        store.mergePendingDiagnostics()
        let exp1 = expectation(description: "wait rtf keyUnavailable merge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)
        XCTAssertTrue(store.diagnostics.keyUnavailable, "RTF keyUnavailable must set diagnostic flag")

        // Now make the key available again
        CryptoService.resetForTesting()

        // Retry — must succeed now. getRTFPlaintext does NOT cache the
        // fallback for .keyUnavailable (N10), so the retry reaches
        // decryptWithReason and succeeds with the live key.
        let retry = store.getRTFPlaintext(store.items.first!)
        XCTAssertEqual(retry, "Hello RTF",
                       "retry after key available must decrypt and parse RTF correctly")
        // The retry should NOT return the old fallback label
        XCTAssertNotEqual(retry, fallback,
                          "retry must not return cached fallback after key becomes available")
    }

    /// P0-2 T5: RTF path data corruption is tracked as diagnostic and marks
    /// decryptionFailed on the item.
    func testRtfPathDataCorruptedAppendsDiagnostic() {
        let store = ClipboardStore.shared
        store.items.removeAll()
        store.diagnostics = .init()

        // Add a rich-text item (real crypto)
        let item = ClipboardItem(content: "rtf data corr test", type: .richText)
        store.addItem(item)
        guard store.items.first?.isEncrypted == true else {
            XCTFail("item must be encrypted after addItem")
            return
        }

        // Swap to a mock that returns .dataCorrupted
        let mock = OCRCorruptCrypto()
        let originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(mock)
        defer { ServiceContainer.setCryptoForTesting(originalCrypto) }

        let result = store.getRTFPlaintext(store.items.first!)
        XCTAssertFalse(result.isEmpty, "must return fallback on corruption")

        store.mergePendingDiagnostics()
        let exp = expectation(description: "wait rtf dataCorrupted merge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 1, "RTF dataCorrupted must be counted")
    }
}

// MARK: - P0-2 T5: mock CryptoServiceProtocol for OCR/RTF diagnostic tests

/// Returns .dataCorrupted from decryptWithReason while leaving encrypt functional
/// (so addItem can still add items to the store before the decrypt test).
private struct OCRCorruptCrypto: CryptoServiceProtocol {
    func encrypt(_ string: String) -> String? { CryptoService.shared.encrypt(string) }
    func decrypt(_ base64String: String) -> String? { nil }
    func encryptData(_ data: Data) -> Data? { CryptoService.shared.encryptData(data) }
    func decryptData(_ combined: Data) -> Data? { nil }
    func isOldFormat(_ base64String: String) -> Bool { false }
    func migrateToV2(_ base64String: String) -> String? { nil }
    func hmacHex(for string: String) -> String? { CryptoService.shared.hmacHex(for: string) }
    func decryptWithReason(_ base64String: String, itemID: UUID) -> DecryptResult { .dataCorrupted }
}
