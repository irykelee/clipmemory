import Foundation
import AppKit
import Sparkle

/// The user's persisted choice about the jsDelivr mirror feed (H1).
enum FeedConsent {
    case granted
    case denied
    case undecided
}

/// Supplies the fallback feed URL to Sparkle when the primary feed failed
/// the launch probe. Returning nil makes Sparkle use the Info.plist SUFeedURL.
private final class FeedURLProvider: NSObject, SPUUpdaterDelegate {
    var resolvedFeedString: String?

    func feedURLString(for updater: SPUUpdater) -> String? {
        resolvedFeedString
    }
}

/// Gentle update reminders for a dockless (LSUIElement) app. When Sparkle is
/// about to show an update alert, bring the app to the foreground so the alert
/// is actually visible; badge the Dock icon for scheduled (non-user-initiated)
/// updates; return to the menu bar when the session ends. Declaring support
/// also silences Sparkle's "does not implement gentle reminders" log warning.
/// Ref: https://sparkle-project.org/documentation/gentle-reminders/
private final class GentleUpdateReminder: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        if !state.userInitiated {
            NSApp.dockTile.badgeLabel = "1"
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.dockTile.badgeLabel = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.dockTile.badgeLabel = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Singleton wrapper around Sparkle's updater so the rest of the app
/// (AppDelegate, settings UI) never touches SPU* types directly.
final class UpdateService {
    static let shared = UpdateService()

    /// Secondary feed mirrored by jsDelivr from this repo's main branch.
    /// Used when the primary feed (GitHub release asset) is unreachable,
    /// e.g. GitHub connectivity problems on some networks. H1: switched to
    /// only with explicit user consent plus a staleness guard — never silently.
    static let fallbackFeedURL = URL(string: "https://cdn.jsdelivr.net/gh/irykelee/clipmemory@main/appcast.xml")!

    private static let fallbackConsentKey = "UpdateFallbackFeedConsent"
    private static let lastPrimaryItemDateKey = "LastPrimaryAppcastItemDate"

    private let feedProvider = FeedURLProvider()
    private let gentleReminder = GentleUpdateReminder()
    private let updaterController: SPUStandardUpdaterController

    private init() {
        // Start is deferred until the primary-feed probe finishes.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: feedProvider,
            userDriverDelegate: gentleReminder
        )
        Task { @MainActor in await startAfterFeedProbe() }
    }

    /// The user's recorded mirror-feed choice. nil = never asked (H1).
    static var fallbackFeedConsent: Bool? {
        get { UserDefaults.standard.object(forKey: fallbackConsentKey) as? Bool }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: fallbackConsentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: fallbackConsentKey)
            }
        }
    }

    /// Newest item date the primary feed last served. Basis of the H1
    /// max-timestamp guard against a stale jsDelivr cache.
    static var lastPrimaryItemDate: Date? {
        get { UserDefaults.standard.object(forKey: lastPrimaryItemDateKey) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: lastPrimaryItemDateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastPrimaryItemDateKey)
            }
        }
    }

    /// The feed Sparkle should use (H1): the primary unless it is unreachable
    /// AND the user has explicitly consented to the mirror AND the mirror is
    /// not stale. `.undecided` keeps the primary — the consent alert is
    /// shown by the caller.
    static func resolvedFeed(
        primary: URL,
        primaryReachable: Bool,
        consent: FeedConsent,
        mirrorStale: Bool = false,
        fallback: URL = fallbackFeedURL
    ) -> URL {
        guard !primaryReachable else { return primary }
        guard consent == .granted, !mirrorStale else { return primary }
        return fallback
    }

    /// Newest `<pubDate>` among appcast items, or nil when nothing parses.
    /// Pure for tests (H1 staleness guard).
    static func latestItemDate(inAppcastXML xml: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var latest: Date?
        var rest = xml[...]
        while let open = rest.range(of: "<pubDate>"),
              let close = rest.range(of: "</pubDate>", range: open.upperBound..<rest.endIndex) {
            let raw = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let date = formatter.date(from: raw), latest.map({ date > $0 }) ?? true {
                latest = date
            }
            rest = rest[close.upperBound...]
        }
        return latest
    }

    /// H1 max-timestamp guard: the mirror is stale when its newest item
    /// predates the newest item the primary last served (jsDelivr caches
    /// `@main` aggressively and can lag behind a fresh release).
    static func fallbackIsStale(fallbackXML: String, lastPrimaryItemDate: Date?) -> Bool {
        guard let lastPrimaryItemDate,
              let fallbackDate = latestItemDate(inAppcastXML: fallbackXML) else { return false }
        return fallbackDate < lastPrimaryItemDate
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

    /// Probe the primary feed; only with persisted (or freshly given) user
    /// consent fall back to the jsDelivr mirror, then start the updater.
    /// The network fetches run off the main thread; Sparkle calls stay on main.
    @MainActor
    private func startAfterFeedProbe() async {
        guard let primaryString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let primary = URL(string: primaryString) else {
            startUpdater()
            return
        }
        if let primaryXML = await fetch(url: primary) {
            if let date = Self.latestItemDate(inAppcastXML: primaryXML) {
                Self.lastPrimaryItemDate = date
            }
            startUpdater()
            return
        }
        // Primary unreachable. H1: no silent fallback — ask once, persist.
        let consent: FeedConsent
        if let stored = Self.fallbackFeedConsent {
            consent = stored ? .granted : .denied
        } else {
            consent = askFallbackConsent() ? .granted : .denied
            Self.fallbackFeedConsent = consent == .granted
        }
        var mirrorStale = false
        if consent == .granted, let fallbackXML = await fetch(url: Self.fallbackFeedURL),
           Self.fallbackIsStale(fallbackXML: fallbackXML, lastPrimaryItemDate: Self.lastPrimaryItemDate) {
            NSLog("ClipMemory: mirror update feed is older than the primary's last appcast; ignoring it")
            mirrorStale = true
        }
        let resolved = Self.resolvedFeed(
            primary: primary,
            primaryReachable: false,
            consent: consent,
            mirrorStale: mirrorStale
        )
        if resolved != primary {
            feedProvider.resolvedFeedString = resolved.absoluteString
        }
        startUpdater()
    }

    /// One-time consent alert for the mirror feed (H1). Runs at launch only
    /// when the primary is unreachable and no choice was persisted yet.
    @MainActor
    private func askFallbackConsent() -> Bool {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        let alert = NSAlert()
        alert.messageText = L10n.alertUpdateFallbackTitle
        alert.informativeText = L10n.alertUpdateFallbackMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.alertUpdateFallbackUseMirror)
        alert.addButton(withTitle: L10n.alertUpdateFallbackPrimaryOnly)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func startUpdater() {
        do {
            try updaterController.updater.start()
        } catch {
            NSLog("ClipMemory: Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }

    /// Cheap reachability fetch: the appcast is ~1 KB, so a plain GET with a
    /// short timeout is enough — no need for HEAD/Range cleverness. Returns
    /// the body on HTTP 200 so callers can inspect appcast dates.
    private func fetch(url: URL) async -> String? {
        do {
            let request = URLRequest(url: url, timeoutInterval: 5)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
