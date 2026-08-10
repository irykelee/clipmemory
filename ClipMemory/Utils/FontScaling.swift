import Foundation
import SwiftUI

/// Font scaling utility that reads font scale factor from UserDefaults.
///
/// Each View retains its own `@AppStorage("fontScale")` to trigger SwiftUI
/// re-renders when the user changes the setting. This function reads the
/// current value at render time to keep the actual scaling in sync.
///
/// FONT-0001 (2026-08-10): the Settings UI exposes three explicit font-size
/// steps (1.0 / 1.2 / 1.4 in `GeneralSettingsView.swift:80-84`), but the
/// `scale < 4` upper bound below is wider than any user-facing step. The
/// difference is intentional — see the long-form note at the clamp.
func sz(_ base: CGFloat) -> CGFloat {
    let scale = UserDefaults.standard.double(forKey: "fontScale")
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
