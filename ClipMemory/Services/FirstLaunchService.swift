import Foundation
import os

/// P1-AUDIT-2026-09-22 (P1-5 audit): first-launch state moved from
/// `WelcomeView.FirstLaunchManager` direct `UserDefaults` access to a
/// dedicated service. The View (and `AppDelegate`) hold only thin
/// pass-through read/write handles; `UserDefaults` access is owned here.
///
/// Test seam: a `xcTestDefaults` suite name parallels the existing
/// `ClipboardStore.xcTestDefaults` pattern, so XCTest can redirect
/// `hasLaunchedBefore` reads/writes away from production `com.clipmemory.app`.
/// Production keeps `.standard` so existing keys persist.
final class FirstLaunchService {
    static let hasLaunchedKey = "hasLaunchedBefore"

    private let logger = Logger(subsystem: "com.clipmemory.app", category: "FirstLaunch")
    private let store: UserDefaults

    /// Production init: writes go to `UserDefaults.standard`.
    init() {
        self.store = .standard
    }

    /// Test seam: callers (XCTest suites, production callers wanting
    /// isolation) can inject a different `UserDefaults` instance.
    init(store: UserDefaults) {
        self.store = store
    }

    /// True if the user has never launched the app before.
    /// Used by `AppDelegate.applicationDidFinishLaunching` to decide whether
    /// to show the welcome window.
    var hasLaunched: Bool {
        store.bool(forKey: Self.hasLaunchedKey)
    }

    /// Mark the first-launch state complete (called from the welcome sheet's
    /// "Get Started" button via `FirstLaunchManager.markLaunched`).
    func markLaunched() {
        store.set(true, forKey: Self.hasLaunchedKey)
    }
}
