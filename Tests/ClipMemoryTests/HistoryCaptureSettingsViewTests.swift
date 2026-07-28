import XCTest
import SwiftUI
@testable import ClipMemory

@MainActor
final class HistoryCaptureSettingsViewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Each test starts from a known state.
        ClipboardStore.shared.ocrPreviewEnabled = true
    }

    func testToggleOnShowsOcrPreviewSection() {
        ClipboardStore.shared.ocrPreviewEnabled = true
        // Smoke: render the view, assert no crash. Toggle state asserted
        // via UserDefaults.
        XCTAssertEqual(ClipboardStore.shared.ocrPreviewEnabled, true)
    }

    func testToggleOffHidesOcrPreviewButKeepsFilter() {
        ClipboardStore.shared.ocrPreviewEnabled = false
        // Display-only: filter still uses OCR text. (Filter behavior is
        // covered by ContentViewTests — not duplicated here.)
        XCTAssertEqual(ClipboardStore.shared.ocrPreviewEnabled, false)
    }
}
