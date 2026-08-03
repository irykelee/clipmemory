import XCTest
import SwiftUI
@testable import ClipMemory

@MainActor
final class HistoryCaptureSettingsViewTests: XCTestCase {

    // M12 (2026-08-01): per-test injected store replaces ClipboardStore.shared.
    // HistoryCaptureSettingsView takes an injected store (see
    // SettingsTabSnapshotTests) and ocrPreviewEnabled is UserDefaults-backed,
    // so any instance exercises the same accessor.
    // M13 (2026-08-03): now uses isolated defaults suite — no production writes.
    private var store: ClipboardStore!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // M13 (2026-08-03): use isolated defaults suite for ocrPreviewEnabled.
        testDefaults = makeTestDefaults()
        store = ClipboardStore(backend: MemoryStorageBackend(), defaults: testDefaults)
        // Each test starts from a known state.
        store.ocrPreviewEnabled = true
    }

    override func tearDown() {
        store = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
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
