import Foundation
import SwiftUI

/// Font scaling utility that reads font scale factor from UserDefaults.
///
/// Each View retains its own `@AppStorage("fontScale", store: AppStorageDefaults.shared)`
/// to trigger SwiftUI re-renders when the user changes the setting. This
/// function reads the current value at render time to keep the actual scaling
/// in sync.
///
/// ID-REVIEW-1039 (2026-10-27): the store both the `@AppStorage` wrapper and
/// this function resolve against is now `AppStorageDefaults.shared` — a
/// dedicated appearance seam — instead of `UserDefaults.standard` spelled
/// out twice.
///
/// Why that matters: the test bundle is injected into the APP binary
/// (`TEST_HOST`), so inside a test process `UserDefaults.standard` IS the
/// user's real `com.clipmemory.app` domain. The snapshot tests therefore had
/// to plant their baseline (`fontScale = 1.0`) into the production domain to
/// make the render deterministic, and a host abort between the write and the
/// restore left the user's real font scale permanently changed (the same
/// failure mode as ID-REVIEW-1038, on the read side of the same key).
///
/// With the seam, production behaviour is byte-identical
/// (`AppStorageDefaults.shared` IS `UserDefaults.standard` outside XCTest),
/// and a test can point the appearance reads at an isolated store without
/// touching the app's service seam — so the baseline becomes deterministic
/// **without writing anything**.
///
/// ⚠️ The seam is deliberately NOT `TestIsolation.defaults` and owns its own
/// storage. Swapping the canonical service seam invalidates
/// `LanguageManager.shared`'s **instance-identity** cache, so the next read
/// of `shared` re-creates the manager and binds it to whatever the service
/// seam holds at that moment; the next `selectedLanguage` assignment then
/// writes `appLanguage` + `AppleLanguages` into THAT store — which, when it
/// is the baseline suite, made the ZZZ canary go red and blame four
/// unrelated test classes. (`LanguageManager.init` itself writes nothing:
/// `didSet` does not fire during `init`.) See `AppStorageDefaults.swift`
/// for the full, measured account.
///
/// FONT-0001 (2026-08-10): the Settings UI exposes three explicit font-size
/// steps (1.0 / 1.2 / 1.4 in `GeneralSettingsView.swift:80-84`), but the
/// `scale < 4` upper bound below is wider than any user-facing step. The
/// difference is intentional — see the long-form note at the clamp.
func sz(_ base: CGFloat) -> CGFloat {
    sz(base, defaults: AppStorageDefaults.shared)
}

/// The clamp, reading the scale from an injectable store.
///
/// ID-REVIEW-1038 (2026-10-26): the scale used to be read inline from
/// `UserDefaults.standard` and the clamp was inlined with it, so the ONLY
/// way to exercise the clamp was to write a bad value into
/// `UserDefaults.standard` — the PRODUCTION domain. The test host runs
/// INSIDE the app process (`TEST_HOST` = the app binary, and
/// `Bundle.main.bundleIdentifier` measures as `com.clipmemory.app` inside
/// the test host), so `UserDefaults.standard` in a test IS the user's real
/// `com.clipmemory.app` domain. The write was undone by a `defer`, and a
/// `defer` does NOT run when the test host aborts — and this repo has
/// already proven the host aborts (CI run 40186263416, ID-REVIEW-1034).
/// Measured on 2026-10-26: a trap between the write and the restore left
/// `fontScale = 3.7` in the user's production plist, permanently.
///
/// Taking the store as a parameter lets the tests pin the whole
/// read-then-clamp path against a per-test suite: the write side of the
/// risk disappears instead of being made "usually safe".
func sz(_ base: CGFloat, defaults: UserDefaults) -> CGFloat {
    // P1-AUDIT-2026-09-22 (P2-9): central `UserDefaultsKey` rawValue —
    // `"fontScale"` was an inline literal here.
    let scale = defaults.double(forKey: UserDefaultsKey.fontScale.rawValue)
    // M-5 fix (2026-07-20 audit): UserDefaults can store any IEEE-754 bit
    // pattern including `.infinity` / `NaN` (decimal plist round-trip
    // preserves them). The previous guard only checked `scale > 0`, which
    // passes for `.infinity` and produces `base * .infinity = .infinity`,
    // then `Text().font(.system(size: .infinity))` collapses the layout.
    // Reject NaN/Inf and clamp to a sane upper bound.
    //
    // FONT-0001 (2026-08-10) — why the upper bound is `4`, not `1.4`:
    //   - The Settings Picker (GeneralSettingsView.swift:80-84) only lets
    //     the user pick from {1.0, 1.2, 1.4} — three deliberate visual
    //     steps that the design team tuned for the existing layouts.
    //   - The clamp `< 4` is a defensive ceiling for non-user-supplied
    //     values that might land in UserDefaults:
    //       1. `defaults write com.clipmemory.app fontScale 2.5` from the
    //          terminal (support / debugging workflow).
    //       2. A future Settings step the team adds — they bump the Picker
    //          tags but the clamp stays a safety net until they remember
    //          to bump it too.
    //       3. A migration script that imports a scale from another app.
    //     In all three cases the user can recover by re-selecting a value
    //     in the Picker, but the layout still renders coherently while
    //     the bad value sits in UserDefaults — better than collapsing to
    //     base size (the `else` branch) for a transient mismatch.
    //   - 4× is well past any plausible user step (2.5-3× is already
    //     huge for accessibility) and bounds future bugs where a missing
    //     tag in the Picker falls through to `0` or `.infinity`.
    guard scale.isFinite, scale > 0, scale < 4 else { return base }
    return base * scale
}
