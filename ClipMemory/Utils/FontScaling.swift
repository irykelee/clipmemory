import Foundation
import SwiftUI

/// Font scaling utility that reads font scale factor from UserDefaults.
///
/// Each View retains its own `@AppStorage("fontScale")` to trigger SwiftUI
/// re-renders when the user changes the setting. This function reads the
/// current value at render time to keep the actual scaling in sync.
func sz(_ base: CGFloat) -> CGFloat {
    let scale = UserDefaults.standard.double(forKey: "fontScale")
    return base * (scale > 0 ? scale : 1.0)
}
