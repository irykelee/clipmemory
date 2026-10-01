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
    /// ID-REVIEW-1006 (code-review-2026-10-01 P1 0-6): default to the
    /// localized `L10n.buttonClose` instead of the English literal `"Close"`.
    /// The 4 callers (ContentView / SidebarView / QuickBarView /
    /// DiagnosticsBanner) all omit an explicit label and rely on the
    /// default — non-English locales (日/韩 VoiceOver users in particular)
    /// were hearing English "Close" on every close button. Callers that
    /// need a different a11y label can still override via the parameter.
    var accessibilityLabel: String = L10n.buttonClose

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
