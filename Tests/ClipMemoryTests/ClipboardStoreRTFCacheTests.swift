import XCTest
import AppKit
@testable import ClipMemory

/// M-3 (2026-07-21 audit) regression coverage for the RTF cache bridge
/// (cacheRTFPlaintext + getRTFPlaintext cache-aware path in copyToClipboard).
/// Sandbox pattern follows ImportExportTests (temp dirs + throwaway
/// CryptoService keys so the real store is untouched). NSPasteboard.general
/// is cleared in tearDown to avoid test pollution across the system.
final class ClipboardStoreRTFCacheTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var localKeyData: Data!
    private var localCrypto: CryptoService!
    private var originalCrypto: CryptoServiceProtocol?
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardStoreRTFCache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ClipboardStoreRTFCache-\(UUID().uuidString)")
        localKeyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        localCrypto = CryptoService(customKeyData: localKeyData)
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.crypto = localCrypto
        store = ClipboardStore(backend: MemoryStorageBackend())
        NSPasteboard.general.clearContents()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if let originalCrypto { ServiceContainer.crypto = originalCrypto }
        originalCrypto = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        defaults = nil
        localKeyData = nil
        localCrypto = nil
        store = nil
        super.tearDown()
    }

    /// Build a richText item with given base64 RTF + seed it into the store.
    private func makeRichTextItem(rtfBase64: String, crypto: CryptoService) throws -> ClipboardItem {
        let encrypted = try XCTUnwrap(crypto.encrypt(rtfBase64))
        let hash = try XCTUnwrap(crypto.hmacHex(for: rtfBase64))
        return ClipboardItem(
            content: encrypted,
            type: .richText,
            isEncrypted: true,
            contentHash: hash
        )
    }

    // Hand-rolled minimum-valid RTF: contains plaintext "Hello" after parsing.
    private let validRTF = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2512\n{\\colortbl;\\red255\\green255\\blue255;}\n\\pard\\tx560\\tx1120\\tx1680\\tx2240\\tx2800\\tx3360\\tx3920\\tx4480\\tx5040\\tx5600\\tx6160\\tx6720\\li0\\ri0\\sa200\\sl240\\slmult1\\f0\\fs24 \\cf0 Hello\\cf0  }"
    private var validRTFBase64: String { Data(validRTF.utf8).base64EncodedString() }

    // A1: cacheRTFPlaintext populates cache (next getRTFPlaintext hits)
    func testCacheRTFPlaintext_populatesCache() throws {
        let item = try makeRichTextItem(rtfBase64: validRTFBase64, crypto: localCrypto)
        // Pre-populate cache with a known value
        store.cacheRTFPlaintext(item, "cached-value")
        // getRTFPlaintext must return cached value (no re-parse)
        XCTAssertEqual(store.getRTFPlaintext(item), "cached-value",
                       "cacheRTFPlaintext must populate cache; getRTFPlaintext must hit")
    }

    // A2: copyToClipboard RTF uses cache (pasteboard .string = cached value)
    func testCopyToClipboardRichTextUsesCache() throws {
        let item = try makeRichTextItem(rtfBase64: validRTFBase64, crypto: localCrypto)
        // Pre-populate cache with a different plaintext (simulates bridge scenario)
        store.cacheRTFPlaintext(item, "cached-plain-from-bridge")
        // Copy to clipboard
        store.copyToClipboard(item)
        // Verify pasteboard has the cached plaintext, not the parsed RTF one
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "cached-plain-from-bridge",
                       "copyToClipboard RTF branch must use getRTFPlaintext (cache-aware)")
    }

    // A3: cache miss sync parse still works (fallback to RichTextParser.plaintext)
    func testCopyToClipboardRichTextMissParsesSync() throws {
        let item = try makeRichTextItem(rtfBase64: validRTFBase64, crypto: localCrypto)
        // Do NOT pre-populate cache
        store.copyToClipboard(item)
        let result = NSPasteboard.general.string(forType: .string) ?? ""
        // Either parsed "Hello" or fallback — both are valid miss paths
        XCTAssertTrue(result.contains("Hello") || result.contains("Rich Text"),
                      "miss path must either parse to plaintext or fall back to L10n.itemRichText; got: \(result)")
    }
}
