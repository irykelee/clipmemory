import Foundation

/// P0-2: search-path decryption failure diagnostics aggregation.
/// @Published exposed to ContentView / QuickBarView for diagnostic banners.
/// N9: display text lives in DiagnosticsBanner (Task 7), not here — avoids
/// early L10n dependency and stringsdict plural mismatch.
struct DecryptionDiagnostics: Equatable {
    var keyUnavailable: Bool = false
    var dataCorruptedCount: Int = 0
    var internalErrorCount: Int = 0  // user-invisible, folded into corrupted count for display
    var dismissed: Bool = false

    var totalCorruptedCount: Int {
        dataCorruptedCount + internalErrorCount
    }
}
