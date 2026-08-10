import SwiftUI
import AppKit

/// NEW: Unified close button (user round 8 — 2026-08-10).
/// Used in 3 places that all rendered `Image(systemName: "xmark.circle.fill")`
/// with `Button` + `.foregroundColor(.secondary)`. Three copies of the same
/// "X in a circle" affordance. Now there's one component, one shape, one
/// color, one size.
struct CloseButton: View {
    /// `action` is the tap handler. Standard for a Button — keep the same
    /// signature as `SwiftUI.Button` so this drops in as a near-1:1 replacement.
    let action: () -> Void

    /// Standard tooltip shown on hover (matches the existing inline buttons'
    /// `.help(...)` pattern; callers that need different copy can override
    /// via `.help(...)` modifier).
    var accessibilityLabel: String = "Close"

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
                .font(.system(size: sz(12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
