import Foundation
import Sparkle

/// Singleton wrapper around Sparkle's updater so the rest of the app
/// (AppDelegate, settings UI) never touches SPU* types directly.
final class UpdateService {
    static let shared = UpdateService()

    private let updaterController: SPUStandardUpdaterController

    private init() {
        // Starting the updater immediately enables the scheduled (daily)
        // background check configured via SUEnableAutomaticChecks.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Mirrors Sparkle's own persisted setting (SUAutomaticallyChecksForUpdates).
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }

    /// User-initiated check from the settings pane. Sparkle shows its standard UI.
    func checkNow() {
        updaterController.checkForUpdates(nil)
    }
}
