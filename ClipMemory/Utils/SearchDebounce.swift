import Foundation

/// ID-CRASH-0040 (2026-09-28 code-review P3): single source of truth for
/// the search-input debounce delay used by `ContentView`, `QuickBarView`,
/// and `HistoryCaptureSettingsView` (3 sites, all currently hard-coded
/// to `0.25`). The 250 ms value matches the perceptual threshold for
/// "feels instant but doesn't refilter on every keystroke" — three sites
/// independently choosing this value is coincidence-as-coupling; future
/// readers shouldn't have to grep to verify they're in sync.
///
/// The wrapper `schedule(_:)` centralises the
/// `DispatchQueue.main.asyncAfter(deadline: .now() + interval, …)`
/// pattern in addition to the delay literal so the 3 call sites no
/// longer duplicate the queue hop either (the audit flagged both).
enum SearchDebounce {
    /// 250 ms — perceptual threshold for "instant search feel" without
    /// re-filtering on every keystroke. Single source of truth.
    static let delay: TimeInterval = 0.25

    /// Dispatch `work` on `queue` (default main) after `interval`
    /// (default `delay`). Mirrors the previous inline
    /// `DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)`
    /// pattern verbatim; the call sites just swap the literal for the
    /// helper. Accepts `DispatchWorkItem` directly (the 3 call sites
    /// all cancel+reschedule an existing work item rather than fire a
    /// one-shot closure).
    static func schedule(
        after interval: TimeInterval = delay,
        on queue: DispatchQueue = .main,
        workItem: DispatchWorkItem
    ) {
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }
}