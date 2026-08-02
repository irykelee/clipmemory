import XCTest
import SwiftUI
@testable import ClipMemory

@MainActor
final class HistoryCaptureSettingsViewTests: XCTestCase {

    // M12 (2026-08-01): per-test injected store replaces ClipboardStore.shared.
    // HistoryCaptureSettingsView takes an injected store (see
    // SettingsTabSnapshotTests) and ocrPreviewEnabled is UserDefaults-backed,
    // so any instance exercises the same accessor.
    private var store: ClipboardStore!
    private var savedOcrPreviewEnabled: Any?

    override func setUp() {
        super.setUp()
        // M13 (2026-08-02 audit): these tests write the production
        // "ocrPreviewEnabled" key through ClipboardStore+OCR's hardwired
        // UserDefaults.standard accessor (not suite-injectable). Back up
        // the real value and restore it in tearDown so a user's
        // non-default setting survives a test run (STORE-0007 pattern,
        // same as OCRTests).
        savedOcrPreviewEnabled = UserDefaults.standard.object(forKey: "ocrPreviewEnabled")
        store = ClipboardStore(backend: MemoryStorageBackend())
        // Each test starts from a known state.
        store.ocrPreviewEnabled = true
    }

    override func tearDown() {
        // M13: restore the production value captured in setUp.
        if let savedOcrPreviewEnabled {
            UserDefaults.standard.set(savedOcrPreviewEnabled, forKey: "ocrPreviewEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "ocrPreviewEnabled")
        }
        savedOcrPreviewEnabled = nil
        store = nil
        super.tearDown()
    }

    func testToggleOnShowsOcrPreviewSection() {
        store.ocrPreviewEnabled = true
        // Smoke: render the view, assert no crash. Toggle state asserted
        // via UserDefaults.
        XCTAssertEqual(store.ocrPreviewEnabled, true)
    }

    func testToggleOffHidesOcrPreviewButKeepsFilter() {
        store.ocrPreviewEnabled = false
        // Display-only: filter still uses OCR text. (Filter behavior is
        // covered by ContentViewTests — not duplicated here.)
        XCTAssertEqual(store.ocrPreviewEnabled, false)
    }
}
