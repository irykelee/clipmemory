import XCTest
import AppKit
@testable import ClipMemory

/// CLIP-2 (2026-07-24 audit): ClipboardItemRow.copyOcrText wrote the OCR
/// text straight to NSPasteboard.general WITHOUT calling
/// `clipboardMonitor?.recordOwnWrite()` first — unlike every other copy
/// path (ClipboardStore.copyToClipboard, M-4). The monitor's next poll saw
/// the changeCount bump with no skip flag set and re-captured our own OCR
/// text as a brand-new history entry (duplicate loop).
///
/// The fix routes the write through `ClipboardItemRow.writeOcrTextToPasteboard`,
/// which calls recordOwnWrite() BEFORE clearContents() (M-4 ordering) and is
/// static + store-injected so it can be tested against a MemoryStorageBackend
/// store without touching ClipboardStore.shared.
///
/// NSPasteboard.general is cleared in setUp/tearDown to avoid test pollution
/// across the system (same pattern as ClipboardStoreRTFCacheTests).
/// No UserDefaults writes, no crypto, no UI — no NSAlert risk.
final class CopyOcrTextOwnWriteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NSPasteboard.general.clearContents()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    /// The regression: writing OCR text must set the monitor's skip flag so
    /// the write is not re-captured as a new history entry.
    func testWriteOcrText_recordsOwnWriteSoMonitorSkipsRecapture() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let monitor = ClipboardMonitor()
        store.clipboardMonitor = monitor
        monitor.skipNextCapture = false

        ClipboardItemRow.writeOcrTextToPasteboard("识别出的文字", store: store)

        XCTAssertTrue(monitor.skipNextCapture,
                      "OCR copy must call recordOwnWrite() before writing the pasteboard (CLIP-2)")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "识别出的文字",
                       "OCR text must still land on the pasteboard")
    }

    /// The pasteboard write must still happen end-to-end (flag assertions
    /// alone would pass even if the write was dropped).
    func testWriteOcrText_writesTextToPasteboard() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        let monitor = ClipboardMonitor()
        store.clipboardMonitor = monitor

        ClipboardItemRow.writeOcrTextToPasteboard("ocr result", store: store)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ocr result")
    }

    /// No monitor wired (clipboardMonitor == nil, e.g. monitoring disabled):
    /// must not crash and must still write — recordOwnWrite is best-effort.
    func testWriteOcrText_withoutMonitor_stillWritesPasteboard() {
        let store = ClipboardStore(backend: MemoryStorageBackend())
        XCTAssertNil(store.clipboardMonitor, "premise: no monitor injected")

        ClipboardItemRow.writeOcrTextToPasteboard("no monitor text", store: store)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "no monitor text")
    }
}
