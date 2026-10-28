import Foundation
import ServiceManagement

/// ID-REVIEW-1047 (2026-10-28): the **login item** ("Open at Login") gate.
///
/// ## 为什么它属于「测试基础设施污染用户真实环境」这一族
///
/// `SMAppService.mainApp` addresses the **app's own login-item registration**
/// in the macOS BackgroundTaskManagement database — i.e. **the user's real
/// "Open at Login" setting**. In the test host `Bundle.main` is
/// `ClipMemory.app`, so `SMAppService.mainApp` resolves to **the user's
/// registration**, exactly like `UserDefaults.standard` resolves to the
/// user's `com.clipmemory.app` domain.
///
/// Before this file existed, `GeneralSettingsView` touched it in four places
/// with **no test-process gate at all**:
///
/// * `:20` — `@State private var launchAtLoginEnabled: Bool =
///   SMAppService.mainApp.status == .enabled` ⇒ a **read** that runs when the
///   view struct is constructed ⇒ the snapshot test
///   `SettingsTabSnapshotTests.testGeneralSettingsTabDefault` (which builds
///   `GeneralSettingsView(hotKeyManager: nil)`) reached it **on every run**;
/// * `:55` — `try SMAppService.mainApp.register()` / `.unregister()` inside
///   the Toggle's binding setter ⇒ the **write** path ⇒ a test that ever
///   drove that switch would have **turned the user's "Open at Login" on or
///   off**.
///
/// ⇒ After the post-1047 sweep (which scanned the whole app tree for
/// user-global resource references), `SMAppService` was the **last** one
/// without a gate — every other one (pasteboard, keychain, hotkey, status
/// item, sentinel, Images, Keys, Backups, window frames, first-launch flag)
/// now has one.
///
/// ## 修法
///
/// Both the read and the write go through this type, and **both** are
/// production-only. In a test process:
/// * the read reports `false` (no login-item query at all ⇒ deterministic);
/// * the write is a **no-op** ⇒ the user's registration can never change.
///
/// ⚠️ The read's production half is byte-identical: `shouldApply(false)` is
/// `true` ⇒ the real `SMAppService.mainApp.status` is read exactly as
/// before.
enum LaunchAtLoginService {
    /// The **pure** decision — may this process touch the login item?
    ///
    /// Split out so the production half is assertable from a test (inside a
    /// test host `TestIsolation.isRunningTests` is always true ⇒ "production
    /// ⇒ touches it" is otherwise structurally unreachable — the
    /// ID-REVIEW-1045 shape).
    nonisolated static func shouldApply(isRunningTests: Bool) -> Bool {
        !isRunningTests
    }

    /// Whether the user currently has "Open at Login" enabled.
    ///
    /// Production ⇒ the real registration status. A test process ⇒ `false`,
    /// without querying the system at all.
    static func isEnabled() -> Bool {
        guard shouldApply(isRunningTests: TestIsolation.isRunningTests) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Turn the login item on or off.
    ///
    /// A test process ⇒ **no-op** (the user's registration is never
    /// touched). Production ⇒ exactly the previous behaviour, including the
    /// `throws` (the caller surfaces the failure to the user).
    ///
    /// ⚠️ ID-REVIEW-1047 (2026-10-28, independent verifier round 2): the
    /// `apply` parameter is a **test seam** — it is what lets the guard
    /// observe "did this process actually reach the system?" **without**
    /// touching the system and **without** querying the user's registration
    /// (a guard that reads the user's login item to prove it doesn't read it
    /// would defeat the very gate it is testing).
    ///
    /// ⇒ the guard injects a **recording** closure and asserts it was never
    /// called. That makes the gate **behaviourally** observable.
    static func setEnabled(
        _ enabled: Bool,
        apply: (Bool) throws -> Void = applyToSystem
    ) throws {
        guard shouldApply(isRunningTests: TestIsolation.isRunningTests) else { return }
        try apply(enabled)
    }

    /// The real thing: register / unregister the app's login item.
    ///
    /// ⚠️ Production only — `setEnabled` is the single caller and it gates
    /// this. A guard asserts that `SMAppService.mainApp` appears **only** in
    /// this file.
    private static func applyToSystem(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
