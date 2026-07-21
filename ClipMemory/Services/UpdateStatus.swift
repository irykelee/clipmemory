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
}
