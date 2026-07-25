import Foundation

/// Date-range filter for the history list (ContentView toolbar).
///
/// CLIP-10 (2026-07-24 review): this enum used to be nested inside
/// ContentView, which forced Services-layer code (UIObservability) to
/// reference `ContentView.DateFilter` — a Services→Views reverse
/// dependency. It's a plain String enum with no view dependencies, so it
/// lives in Models now; ContentView and UIObservability share this type.
enum DateFilter: String, CaseIterable {
    case all, today, yesterday, older
    var label: String {
        switch self { case .all: return L10n.dateFilterAll; case .today: return L10n.groupToday; case .yesterday: return L10n.groupYesterday; case .older: return L10n.groupOlder }
    }
}
