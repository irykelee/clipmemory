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
        // NSApp.windows can retain closed windows left over from earlier
        // tests for a runloop — count only visible ones (same reasoning as
        // testShowSettingsWindowTwiceDoesNotStack below).
        let visible = NSApp.windows.filter { $0.title == L10n.settingsWindowTitle && $0.isVisible }
        XCTAssertEqual(visible.count, 1, "expected exactly one visible settings window after open")
        visible.first?.close()
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

    // MARK: - ID-LIFE-0020 / ID-LIFE-0021 (2026-07-31): close-observer token lifecycle

    /// ID-LIFE-0021: the settings willClose observer token must be stored on
    /// open and removed when the window closes — a discarded token leaked one
    /// permanent observer (plus its captured window graph) per reopen.
    @MainActor
    func testSettingsCloseObserverTokenRemovedOnWindowClose() {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            XCTFail("AppDelegate not available in test host")
            return
        }
        delegate.showSettingsWindow()
        XCTAssertNotNil(delegate.settingsCloseObserver,
                        "ID-LIFE-0021: observer token must be retained while the window is open")
        delegate.showSettingsWindow() // reopen — old token must be replaced, not accumulated
        let token = delegate.settingsCloseObserver
        XCTAssertNotNil(token)

        let win = NSApp.windows.first { $0.title == L10n.settingsWindowTitle && $0.isVisible }
        win?.close()
        // The willClose handler is delivered on the main queue — spin the
        // run loop so it runs before we assert.
        let deadline = Date().addingTimeInterval(2.0)
        while delegate.settingsCloseObserver != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(delegate.settingsCloseObserver,
                     "ID-LIFE-0021: observer token must be removed when the window closes")
    }

    /// ID-LIFE-0020: same lifecycle for the welcome window observer token.
    @MainActor
    func testWelcomeCloseObserverTokenRemovedOnWindowClose() {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            XCTFail("AppDelegate not available in test host")
            return
        }
        // The welcome window's title (L10n.appName) is shared with the main
        // window — locate it as the window newly added by the calls above.
        let preExisting = Set(NSApp.windows)
        delegate.showWelcomeView()
        XCTAssertNotNil(delegate.welcomeCloseObserver,
                        "ID-LIFE-0020: observer token must be retained while the window is open")
        delegate.showWelcomeView() // reopen — old token must be replaced, not accumulated
        XCTAssertNotNil(delegate.welcomeCloseObserver)

        let win = NSApp.windows.first { !preExisting.contains($0) && $0.isVisible }
        win?.close()
        let deadline = Date().addingTimeInterval(2.0)
        while delegate.welcomeCloseObserver != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(delegate.welcomeCloseObserver,
                     "ID-LIFE-0020: observer token must be removed when the window closes")
    }

    // MARK: - ID-MON-0002 (2026-08-01): no live clipboard monitor under XCTest

    /// ID-MON-0002: the test bundle is injected into the real app — a live
    /// monitor in the test host captures real pasteboard writes (including
    /// writes from other tests) into the production UserDefaults store,
    /// encrypted with the XCTest fixture key, which production then reports
    /// as corrupted. `setupClipboardMonitor()` must skip the monitor under
    /// XCTest; tests that exercise ClipboardMonitor build their own instance.
    @MainActor
    func testClipboardMonitorNotStartedUnderXCTest() {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            XCTFail("AppDelegate not available in test host")
            return
        }
        XCTAssertNil(delegate.clipboardMonitor,
                     "ID-MON-0002: live monitor in test host pollutes the production store")
    }
}
