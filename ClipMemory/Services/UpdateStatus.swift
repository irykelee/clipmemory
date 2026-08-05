import Foundation
import Combine

/// Observable status exposed to the settings-page UI. @MainActor on
/// the class (BUG-033 2026-07-21) makes the compiler enforce that
/// @Published mutations only happen on main — previously only the
/// runtime happened to be main, with no compile-time guard.
@MainActor
final class UpdateStatus: ObservableObject {
    @Published var currentSource: String = "github-release"
    @Published var lastCheck: Date?
    @Published var lastSwitchReason: String?
    @Published var lastSwitchAt: Date?

    /// C2 (v2.7.9): newest `<sparkle:shortVersionString>` extracted from the
    /// primary appcast body on the last successful probe. nil when no probe
    /// has run yet, the body could not be fetched, or parsing returned empty.
    /// View layer (UpdateAboutSettingsView) treats nil as a neutral state:
    /// only the current version is shown, with no "up to date" claim, so
    /// users never see a green check that isn't backed by a real check.
    @Published var latestAvailableVersion: String?
}
