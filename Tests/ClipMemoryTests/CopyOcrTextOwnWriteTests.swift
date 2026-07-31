import XCTest
import AppKit
@testable import ClipMemory

/// CLIP-2 (2026-07-24 audit): ClipboardItemRow.copyOcrText wrote the OCR
/// text straight to NSPasteboard.general WITHOUT calling
/// recordOwnWrite() first — unlike every other copy path. The monitor's
/// next poll saw the changeCount bump with no skip flag set and re-captured
/// our own OCR text as a brand-new history entry (duplicate loop).
///
/// MED-5 (2026-07-26 review): tests updated to use `onRecordOwnWrite` closure
/// instead of the removed `clipboardMonitor` bidirectional reference.
@MainActor final class CopyOcrTextOwnWriteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NSPasteboard.general.clearContents()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    func testWriteOcrText_recordsOwnWriteSoMonitorSkipsRecapture() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let monitor = ClipboardMonitor()
        store.onRecordOwnWrite = { monitor.recordOwnWrite() }
        monitor.skipNextCapture = false

        ClipboardItemRow.writeOcrTextToPasteboard("识别出的文字", store: store)

        XCTAssertTrue(monitor.skipNextCapture,
                      "OCR copy must call recordOwnWrite() before writing the pasteboard (CLIP-2)")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "识别出的文字",
                       "OCR text must still land on the pasteboard")
    }

    func testWriteOcrText_writesTextToPasteboard() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let monitor = ClipboardMonitor()
        store.onRecordOwnWrite = { monitor.recordOwnWrite() }

        ClipboardItemRow.writeOcrTextToPasteboard("ocr result", store: store)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ocr result")
    }

    /// No monitor wired (onRecordOwnWrite == nil): must not crash and must
    /// still write — recordOwnWrite is best-effort.
    func testWriteOcrText_withoutMonitor_stillWritesPasteboard() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        XCTAssertNil(store.onRecordOwnWrite, "premise: no closure wired")

        ClipboardItemRow.writeOcrTextToPasteboard("no monitor text", store: store)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "no monitor text")
    }

    /// ID-SECURITY-0003 (2026-07-31 audit): OCR plaintext of a SENSITIVE item
    /// must carry the `org.nspasteboard.ConcealedType` marker so well-behaved
    /// pasteboard readers (incl. our own ClipboardMonitor read path) suppress
    /// capture — same convention as 1Password / Bitwarden writes.
    func testWriteOcrText_sensitiveItem_marksConcealedType() {
        let store = ClipboardStore(backend: MemoryStorageBackend())

        ClipboardItemRow.writeOcrTextToPasteboard("sensitive ocr text", store: store, isSensitive: true)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "sensitive ocr text")
        XCTAssertNotNil(
            NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
            "sensitive OCR copy must stamp org.nspasteboard.ConcealedType (ID-SECURITY-0003)")
    }

    /// Non-sensitive items must NOT be marked — the marker tells every
    /// clipboard reader to suppress the entry, which would break normal
    /// paste behavior for ordinary OCR text.
    func testWriteOcrText_nonSensitiveItem_noConcealedType() {
        let store = ClipboardStore(backend: MemoryStorageBackend())

        ClipboardItemRow.writeOcrTextToPasteboard("plain ocr text", store: store)

        XCTAssertNil(
            NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
            "non-sensitive OCR copy must not carry the concealed marker")
    }
}
