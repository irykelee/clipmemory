import Foundation
import Sparkle

/// Supplies the fallback feed URL to Sparkle when the primary feed failed
/// the launch probe. Returning nil makes Sparkle use the Info.plist SUFeedURL.
private final class FeedURLProvider: NSObject, SPUUpdaterDelegate {
    var resolvedFeedString: String?

    func feedURLString(for updater: SPUUpdater) -> String? {
        resolvedFeedString
    }
}

/// Singleton wrapper around Sparkle's updater so the rest of the app
/// (AppDelegate, settings UI) never touches SPU* types directly.
final class UpdateService {
    static let shared = UpdateService()

    /// Secondary feed mirrored by jsDelivr from this repo's main branch.
    /// Used when the primary feed (GitHub release asset) is unreachable,
    /// e.g. GitHub connectivity problems on some networks.
    static let fallbackFeedURL = URL(string: "https://cdn.jsdelivr.net/gh/irykelee/clipmemory@main/appcast.xml")!

    private let feedProvider = FeedURLProvider()
    private let updaterController: SPUStandardUpdaterController

    private init() {
        // Start is deferred until the primary-feed probe finishes.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: feedProvider,
            userDriverDelegate: nil
        )
        Task { @MainActor in await startAfterFeedProbe() }
    }

    /// The feed Sparkle should use: the primary unless it is unreachable.
    static func resolvedFeedURL(primary: URL, primaryReachable: Bool, fallback: URL = fallbackFeedURL) -> URL {
        primaryReachable ? primary : fallback
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

    // MARK: - Feed probe & deferred start

    /// Probe the primary feed with a short timeout; fall back to the jsDelivr
    /// mirror when it is unreachable, then start the updater. The network
    /// probe runs off the main thread; Sparkle calls stay on main.
    @MainActor
    private func startAfterFeedProbe() async {
        guard let primaryString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let primary = URL(string: primaryString) else {
            startUpdater()
            return
        }
        let reachable = await probe(url: primary)
        let resolved = Self.resolvedFeedURL(primary: primary, primaryReachable: reachable)
        if resolved != primary {
            feedProvider.resolvedFeedString = resolved.absoluteString
        }
        startUpdater()
    }

    @MainActor
    private func startUpdater() {
        do {
            try updaterController.updater.start()
        } catch {
            NSLog("ClipMemory: Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }

    /// Cheap reachability check: the appcast is ~1 KB, so a plain GET with a
    /// short timeout is enough — no need for HEAD/Range cleverness.
    private func probe(url: URL) async -> Bool {
        do {
            let request = URLRequest(url: url, timeoutInterval: 5)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
