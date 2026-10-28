import Foundation
import os

/// P1-AUDIT-2026-09-22 (P1-5 audit): first-launch state moved from
/// `WelcomeView.FirstLaunchManager` direct `UserDefaults` access to a
/// dedicated service. The View (and `AppDelegate`) hold only thin
/// pass-through read/write handles; `UserDefaults` access is owned here.
///
/// ## ID-REVIEW-1047 (2026-10-28): the XCTest-isolated suite this class
/// **documented but never had**.
///
/// The pre-1047 header comment claimed:
///
/// > "Test seam: a `xcTestDefaults` suite name parallels the existing
/// > `ClipboardStore.xcTestDefaults` pattern, so XCTest can redirect
/// > `hasLaunchedBefore` reads/writes away from production
/// > `com.clipmemory.app`."
///
/// **That seam did not exist.** The class had exactly two initializers:
/// `init()` → `self.store = .standard` and `init(store:)` → the injected
/// store. There was no `xcTestDefaults` anywhere in the file ⇒ the
/// documented isolation was **a claim in a comment, not a fact in the
/// code** — the ID-REVIEW-1043 lesson verbatim ("代码里写着的不变量 ≠
/// 被强制的不变量": a comment asserting an isolation that is not enforced).
///
/// ### Why it matters to the user
///
/// `FirstLaunchManager.markLaunched()` is called from the **"Get Started"
/// button of the welcome window** (`WelcomeView.swift:24`) and from
/// `AppDelegate.showWelcomeWindow()`'s completion closure. Both funnel into
/// `ServiceContainer.firstLaunch`, whose backing instance was built with
/// `FirstLaunchService()` ⇒ `store = .standard` ⇒ **the user's real
/// `com.clipmemory.app` domain**.
///
/// ⇒ A test process that reaches that button (the welcome window IS
/// opened by the test host — `SettingsWindowTests` calls
/// `AppDelegate.showWelcomeView()`) would flip the user's first-launch
/// flag ⇒ **the user's real app would stop showing the welcome screen**
/// (or start showing it again, if the flag were cleared).
///
/// ⇒ Worse: `ZZZSuiteTeardownTests.appLifecycleKeys` lists
/// `hasLaunchedBefore`, i.e. the canary **tolerates a change** to that key
/// ⇒ such a flip would be **invisible**. Same shape as the
/// `ClipboardItems` / `ClipboardTrashedItems` removal in ID-REVIEW-1038:
/// *a canary that tolerates a change cannot see destruction*.
///
/// ### The fix
///
/// `init()` now resolves its store through a **pure, testable** seam
/// (`defaultsFor(isTestProcess:)`), so:
/// * production ⇒ `.standard` (**byte-identical** to the old behaviour);
/// * a test process ⇒ a dedicated isolated suite ⇒ the test host can no
///   longer reach the user's first-launch flag.
///
/// The judgement lives at the **convergence point** (`init()`), not at the
/// call sites — the ID-REVIEW-1043 rule ("在收敛点判定，不在调用点判定").
final class FirstLaunchService {
    // P1-AUDIT-2026-09-22 (P2-9): the raw literal was duplicated in
    // `WelcomeView.FirstLaunchManager.hasLaunchedKey`. Aliased through the
    // central `UserDefaultsKey` so both sites stay in sync.
    static let hasLaunchedKey = UserDefaultsKey.hasLaunchedBefore.rawValue

    private let logger = Logger(subsystem: "com.clipmemory.app", category: "FirstLaunch")

    /// ID-REVIEW-1047 (2026-10-28): the XCTest-isolated suite name.
    ///
    /// A **fixed** name (not a UUID) on purpose: the suite has to be
    /// addressable from a guard, and a per-run UUID would create a new
    /// preferences plist on every test process. Same shape as
    /// `ClipboardStore-XCTest-isolation` / `SafeModeService-XCTest-isolation`.
    nonisolated static let xcTestIsolationSuiteName = "FirstLaunchService-XCTest-isolation"

    /// ID-REVIEW-1047: the **pure** decision seam — which domain does a
    /// `FirstLaunchService` bind to?
    ///
    /// Split out so the PRODUCTION half is directly assertable: inside a test
    /// host `TestIsolation.isRunningTests` is always true, so "production ⇒
    /// `.standard`" could not be checked from a test without a seam (the
    /// ID-REVIEW-1045 shape).
    ///
    /// The fallback to `.standard` mirrors `ClipboardStore.xcTestDefaults`
    /// and `SafeModeService.xcTestDefaults`: `UserDefaults(suiteName:)`
    /// returns nil only for an invalid name, and the constant above is valid
    /// ⇒ unreachable in practice.
    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        guard isTestProcess else { return .standard }
        return UserDefaults(suiteName: xcTestIsolationSuiteName) ?? .standard
    }

    /// The store this service uses, resolved from the current process.
    nonisolated static var xcTestDefaults: UserDefaults {
        defaultsFor(isTestProcess: TestIsolation.isRunningTests)
    }

    /// The domain this service reads and writes.
    ///
    /// ID-REVIEW-1047: was `private let`. The regression guard needs to
    /// assert **which domain** the service binds to — and it must be able to
    /// do so **without writing anything** (a guard that writes to the
    /// production domain in order to prove it does not write to the
    /// production domain would BE the harm; see the ID-REVIEW-1042 lesson
    /// "验证工具本身不能成为它要消灭的那种伤害源").
    ///
    /// `@testable import` keeps this invisible outside the test target.
    let store: UserDefaults

    /// Production init: writes go to `UserDefaults.standard`.
    ///
    /// ID-REVIEW-1047: the store is now resolved through
    /// `Self.xcTestDefaults` instead of hard-coding `.standard`, so a test
    /// process gets the isolated suite and production keeps `.standard`
    /// (byte-identical behaviour).
    init() {
        self.store = Self.xcTestDefaults
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
