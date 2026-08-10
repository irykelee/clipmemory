import SwiftUI
import AppKit

/// NEW: Unified checkbox component (user round 8 — 2026-08-10).
/// Replaces 2 distinct ad-hoc checkmark usages that drifted apart
/// (TagPickerSheet:284 used `circle` shape + default ~16pt;
///  ItemListView:331 used `square` shape + sz(12)). Now there's one
/// source of truth — `Shape` and `size` are not arbitrary knobs, they're
/// intentional enum cases that callers pick from. Adding a new usage site
/// is `.foregroundColor(state == .selected ? .accentColor : .secondary)`
/// style; can't accidentally pick a wrong size or wrong shape.
///
/// Two shapes:
/// - `.circle` — used for per-row attachment / toggle (TagPickerSheet)
/// - `.square` (with tri-state: `.empty`/`.mixed`/`.checked`) — used for
///   batch selection master checkbox (ItemListView trash)
enum SelectCheckboxShape {
    case circle    // checkmark.circle.fill / circle
    case square    // checkmark.square.fill / square / minus.square
}

enum SelectCheckboxState {
    case unselected
    case mixed        // only meaningful for .square (tri-state)
    case selected
}

struct SelectCheckbox: View {
    let shape: SelectCheckboxShape
    let state: SelectCheckboxState

    /// Standard accent-color when selected, secondary when not. Caller can
    /// override via `.foregroundColor(...)` modifier if needed.
    var body: some View {
        Image(systemName: symbolName)
            .foregroundColor(state == .selected ? .accentColor : .secondary)
            .font(.system(size: sz(12)))
    }

    private var symbolName: String {
        switch (shape, state) {
        case (.circle, .unselected): return "circle"
        case (.circle, .mixed):       return "circle"  // mixed has no circle equivalent
        case (.circle, .selected):   return "checkmark.circle.fill"
        case (.square, .unselected): return "square"
        case (.square, .mixed):       return "minus.square"
        case (.square, .selected):   return "checkmark.square.fill"
        }
    }
}
