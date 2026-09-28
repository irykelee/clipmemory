import Foundation

/// P0-2: search-path decryption failure diagnostics aggregation.
/// @Published exposed to ContentView / QuickBarView for diagnostic banners.
/// N9: display text lives in DiagnosticsBanner (Task 7), not here — avoids
/// early L10n dependency and stringsdict plural mismatch.
struct DecryptionDiagnostics: Equatable {
    var keyUnavailable: Bool = false
    var dataCorruptedCount: Int = 0
    var internalErrorCount: Int = 0  // user-invisible, folded into corrupted count for display
    // ID-CRASH-0008 (2026-09-28 code-review P1-3): wired to
    // `.tagBackendCorrupted` (posted by `ClipboardStore.loadTags()`
    // on persistence failure). Was a "dead notification" before
    // ID-CRASH-0008 — posted in catch but no observer consumed it,
    // so the user's tag sidebar emptied with zero signal and they
    // had no way to discover the data was lost. Now surfaces via
    // `DiagnosticsBanner` (the same UI path that handles
    // `keyUnavailable` and `dataCorruptedCount`).
    var tagsLoadFailed: Bool = false
    var dismissed: Bool = false

    var totalCorruptedCount: Int {
        dataCorruptedCount + internalErrorCount
    }
}
