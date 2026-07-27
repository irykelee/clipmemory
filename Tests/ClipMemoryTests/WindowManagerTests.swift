import XCTest
import AppKit
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

    // MARK: - B-6 (2026-07-27): secondary-window registration

    /// Closing the main window while a registered secondary window is still
    /// visible must NOT sink the activation policy to `.accessory`. The user
    /// keeps the Dock icon and ⌘Tab listing, and the secondary window stays
    /// the active front window. Before the fix, the main-window-close path
    /// always called `setActivationPolicy(.accessory)`, stranding the
    /// settings / welcome window with no app-activation.
    @MainActor
    func testWindowWillCloseKeepsAccessoryPolicyWithVisibleSecondaryWindow() {
        let manager = WindowManager()
        let secondary = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        secondary.title = "TestSecondary"
        secondary.isReleasedWhenClosed = false
        secondary.makeKeyAndOrderFront(nil)
        manager.registerSecondaryWindow(secondary)
        defer {
            manager.unregisterSecondaryWindow(secondary)
            secondary.close()
        }

        // Force the policy to .regular to simulate "we just had a regular
        // window open". The B-6 fix must preserve this on close because a
        // registered secondary is still visible.
        NSApp.setActivationPolicy(.regular)
        let policyBefore = NSApp.activationPolicy()
        XCTAssertEqual(policyBefore, .regular, "precondition: policy must be .regular for the test to be meaningful")

        manager.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(
            NSApp.activationPolicy(),
            .regular,
            "B-6: windowWillClose must NOT sink to .accessory while a registered secondary window is visible"
        )
    }

    /// No secondary windows visible → sink to .accessory as before. This
    /// pins the original menu-bar-only-on-close behavior so we don't
    /// regress the common case.
    @MainActor
    func testWindowWillCloseSinksToAccessoryWhenNoSecondaryVisible() {
        let manager = WindowManager()
        manager.showMainWindow()
        defer { manager.mainWindow?.close() }

        NSApp.setActivationPolicy(.regular)

        manager.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(
            NSApp.activationPolicy(),
            .accessory,
            "windowWillClose must sink to .accessory when no registered secondary is visible (regression guard)"
        )
    }

    /// Unregistering a secondary window that is then closed must let the
    /// main-window-close path sink to .accessory. Catches "registered
    /// window stays in the table forever" leaks.
    @MainActor
    func testUnregisteringClosedSecondaryAllowsAccessorySink() {
        let manager = WindowManager()
        let secondary = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        secondary.isReleasedWhenClosed = false
        manager.registerSecondaryWindow(secondary)
        secondary.close()
        manager.unregisterSecondaryWindow(secondary)

        NSApp.setActivationPolicy(.regular)
        manager.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(
            NSApp.activationPolicy(),
            .accessory,
            "After unregistering the secondary, main-window-close must sink to .accessory"
        )
    }
}
