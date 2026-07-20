import Foundation
import SwiftUI

/// Font scaling utility that reads font scale factor from UserDefaults.
///
/// Each View retains its own `@AppStorage("fontScale")` to trigger SwiftUI
/// re-renders when the user changes the setting. This function reads the
/// current value at render time to keep the actual scaling in sync.
func sz(_ base: CGFloat) -> CGFloat {
    let scale = UserDefaults.standard.double(forKey: "fontScale")
    // M-5 fix (2026-07-20 audit): UserDefaults can store any IEEE-754 bit
    // pattern including `.infinity` / `NaN` (decimal plist round-trip
    // preserves them). The previous guard only checked `scale > 0`, which
    // passes for `.infinity` and produces `base * .infinity = .infinity`,
    // then `Text().font(.system(size: .infinity))` collapses the layout.
    // Reject NaN/Inf and clamp to a sane upper bound (4× is plenty for any
    // assistive case and bounds future bugs).
    guard scale.isFinite, scale > 0, scale < 4 else { return base }
    return base * scale
}
