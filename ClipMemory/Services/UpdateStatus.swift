import Foundation
import Combine

/// Observable status exposed to the settings-page UI. Mutated only on
/// @MainActor (UpdateService publishes from main).
final class UpdateStatus: ObservableObject {
    @Published var currentSource: String = "github-release"
    @Published var lastCheck: Date?
    @Published var lastSwitchReason: String?
    @Published var lastSwitchAt: Date?
}
