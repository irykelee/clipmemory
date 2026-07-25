import XCTest
@testable import ClipMemory

/// Tests for the independent settings window (2026-07-25 refactor).
///
/// The settings window replaced the sidebar-embedded Settings tab. These
/// tests lock in the two window-management invariants:
/// 1. `showSettingsWindow()` actually puts a titled window on screen.
/// 2. Repeated invocations replace the window instead of stacking copies
///    (the same dedupe pattern `showWelcomeView` uses).
final class SettingsWindowTests: XCTestCase {

    @MainActor
    func testShowSettingsWindowCreatesWindow() {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            XCTFail("AppDelegate not available in test host")
            return
        }
        delegate.showSettingsWindow()
        let matches = NSApp.windows.filter { $0.title == L10n.settingsWindowTitle }
        XCTAssertEqual(matches.count, 1, "expected exactly one settings window after open")
        matches.first?.close()
    }

    @MainActor
    func testShowSettingsWindowTwiceDoesNotStack() {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            XCTFail("AppDelegate not available in test host")
            return
        }
        delegate.showSettingsWindow()
        let firstWindow = NSApp.windows.first { $0.title == L10n.settingsWindowTitle }
        XCTAssertNotNil(firstWindow)

        delegate.showSettingsWindow()
        // NSApp.windows may lag a runloop behind close(), but isVisible
        // flips synchronously — assert on visibility instead of membership.
        XCTAssertEqual(firstWindow?.isVisible, false, "reopen must close the previous window")
        let visible = NSApp.windows.filter { $0.title == L10n.settingsWindowTitle && $0.isVisible }
        XCTAssertEqual(visible.count, 1, "exactly one visible settings window after reopen")
        visible.first?.close()
    }
}
