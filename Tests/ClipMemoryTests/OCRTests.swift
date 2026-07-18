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
