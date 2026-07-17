import XCTest
@testable import ClipMemory

/// Verify WindowManager keeps the main window and content view alive across
/// close/reopen so SwiftUI @State is preserved.
final class WindowManagerTests: XCTestCase {

    func testWindowWillCloseKeepsWindowAndContentView() {
        let manager = WindowManager()
        manager.showMainWindow()

        XCTAssertNotNil(manager.mainWindow, "showMainWindow should create mainWindow")
        XCTAssertNotNil(manager.mainContentView, "showMainWindow should create mainContentView")

        let windowBefore = manager.mainWindow

        manager.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(manager.mainWindow === windowBefore,
                      "windowWillClose must not nil out mainWindow; the same instance should be reused")
        XCTAssertNotNil(manager.mainContentView,
                        "windowWillClose must not nil out mainContentView; @State should survive")
    }

    func testShowMainWindowAfterCloseReusesSameWindow() {
        let manager = WindowManager()
        manager.showMainWindow()
        let firstWindow = manager.mainWindow

        manager.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        manager.showMainWindow()

        XCTAssertTrue(manager.mainWindow === firstWindow,
                      "Re-showing after close should reuse the existing window, not create a new one")
    }
}
