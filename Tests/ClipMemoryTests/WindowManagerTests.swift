import XCTest
import AppKit
@testable import ClipMemory

/// Verify WindowManager keeps the main window and content view alive across
/// close/reopen so SwiftUI @State is preserved.
final class WindowManagerTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // M13 (2026-08-03): WindowManager uses a static defaults seam.
        // Redirect to isolated suite so savedWindowFrame writes never touch
        // production UserDefaults.
        testDefaults = makeTestDefaults()
        WindowManager.defaults = testDefaults
    }

    override func tearDown() {
        WindowManager.defaults = .standard
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

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

    // MARK: - QuickBar reopen (2026-07-24 fix at QuickBarView:197-198 + WindowManager:108-112)
    //
    // The QuickBar reopen fix is two lines at QuickBarView.swift:197-198
    // (`onTap` calls `onDismiss()` then `showMainWindow()`) plus the
    // hosting-controller reuse at WindowManager.swift:108-112. Both
    // private properties (`quickBarPopover`, `quickBarHostingController`,
    // `statusItem`) are unreachable from `@testable import`, and XCTest's
    // headless context can't display an NSPopover to assert the visual
    // reopen path. A meaningful regression test would require either
    // (a) refactoring WindowManager to expose a thin observer hook for
    // "hosting controller reused", or (b) a UI test bundle (XCUITest)
    // that drives the actual popover show/hide cycle.
    //
    // Both are out of proportion for the bug class — a 2-line fix whose
    // correctness is verifiable by inspection of the closure body. The
    // gap is documented here so a future maintainer can decide whether
    // the regression risk warrants the refactor or the UI test bundle.

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
