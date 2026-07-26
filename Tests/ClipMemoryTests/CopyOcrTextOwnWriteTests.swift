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
final class CopyOcrTextOwnWriteTests: XCTestCase {

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
}
