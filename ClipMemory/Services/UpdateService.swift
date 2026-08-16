import Foundation
import AppKit
import Sparkle
import os

// ID-MISC-0002 (2026-07-31 audit): the `FeedConsent` enum and
// `UpdateService.resolvedFeed` / `fallbackIsStale` were deleted as dead code
// (no production callers; the live decision path is FeedProbeEngine's
// resolve(policy:lastKnownDate:channels:timeout:) + its built-in stale guard).

/// Supplies the fallback feed URL to Sparkle when the primary feed failed
/// the launch probe. Returning nil makes Sparkle use the Info.plist SUFeedURL.
private final class FeedURLProvider: NSObject, SPUUpdaterDelegate {
    // BUG-031 (2026-07-21): wrap in NSLock — Sparkle's feedURLString(for:)
    // delegate callback can run on any thread, while the setter is invoked
    // on @MainActor. String? is not atomic across threads; lock fixes the
    // data race. Originally OSAllocatedUnfairLock but C-1 (2026-07-24
    // audit) flagged it as macOS 14+ only; write-once read-sparse pattern
    // means NSLock has no measurable cost.
    private let resolvedFeedLock = NSLock()
    private var resolvedFeedStringBacking: String?
    var resolvedFeedString: String? {
        get {
            resolvedFeedLock.lock()
            defer { resolvedFeedLock.unlock() }
            return resolvedFeedStringBacking
        }
        set {
            resolvedFeedLock.lock()
            defer { resolvedFeedLock.unlock() }
            resolvedFeedStringBacking = newValue
        }
    }

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
        // ID-LIFE-0005 (2026-07-30 audit): only drop to .accessory if no
        // windows are visible. Otherwise the user sees the window stuck on
        // screen with no Dock/⌘Tab presence, matching the orphan-window
        // pattern fixed by ID-LIFE-0003 for the welcome window.
        let anyVisible = NSApp.windows.contains { $0.isVisible }
        if !anyVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// NEW-3 (2026-08-07 Session 4): production-side no-op probe engine.
/// `UpdateService._sharedDefault` returns an instance wired with this engine
/// (and `autoStart: false`) when `isRunningTests` is true, so any test that
/// accidentally touches `UpdateService.shared` without setting
/// `injectedForTest` still gets a hermetic stub — no real appcast probe,
/// no Sparkle `SPUStandardUpdaterController` startup.
///
/// Companion to `Tests/ClipMemoryTests/UpdateServiceStubProbeEngine.swift`
/// (the public-tests version used by snapshot tests). This one lives in
/// production so the lazy `_sharedDefault` can reference it directly;
/// the test-only version is kept for tests that want to type-explicit
/// reference without going through the type-checked seam.
///
/// ID-STORE-0021 (audit MEDIUM-14 foundation, 2026-08-16): explicit
/// `@unchecked Sendable` rationale for the Swift 6 migration plan
/// (`docs/SWIFT6_MIGRATION.md` §4 per-module table). This type is a
/// type-level no-op — the minimal `FeedProbeEngine` protocol
/// implementation used when Sparkle is bypassed. All methods return
/// static values; the compiler has verified no stored properties
/// exist. `@unchecked Sendable` is therefore sound: there is no
/// mutable state to guard.
private final class NoOpFeedProbeEngine: FeedProbeEngine, @unchecked Sendable {
    func resolve(
        policy: UpdateFeedPolicy,
        lastKnownDate: Date?,
        channels: [FeedChannel],
        timeout: TimeInterval?
    ) async -> FeedProbeDecision? {
        return nil
    }
}

/// Singleton wrapper around Sparkle's updater so the rest of the app
/// (AppDelegate, settings UI) never touches SPU* types directly.
final class UpdateService {
    // BUG-033 (2026-07-21): @MainActor so the singleton init can call
    // @MainActor init() of UpdateStatus. First access (always on main)
    // creates the instance; thread-safe via Swift's lazy static init.
    //
    // NEW-2 (2026-08-06 review): return `injectedForTest` when set so
    // snapshot tests can render UpdateAboutSettingsView without firing
    // the production init's side-effects (Sparkle updater, network probe,
    // defaults migration). The injected instance is always a test-only
    // construction with `autoStart: false`.
    @MainActor
    static var shared: UpdateService {
        if let injected = injectedForTest { return injected }
        return _sharedDefault
    }

    /// NEW-3 (2026-08-07 Session 4): XCTest detection, same idiom as
    /// `CryptoService.isRunningTests` (line 240) and `ImageStorage.isRunningTests`
    /// (line 14). Defined here too because `isRunningTests` is a per-file
    /// `private static` in each service that needs it; we haven't (yet) hoisted
    /// it to a shared utility. If a third service needs the same check,
    /// consider extracting to `ServiceTestEnvironment.isRunningTests`.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @MainActor
    private static let _sharedDefault: UpdateService = {
        // NEW-3 (2026-08-07 Session 4): gate the production singleton to a
        // hermetic stub when running under XCTest. This catches any test
        // that triggers `UpdateService.shared` (directly or transitively
        // through view rendering) without first setting `injectedForTest`.
        // Without this guard, the first access lazily constructs a real
        // UpdateService which kicks off a real appcast HTTP probe and
        // starts Sparkle's `SPUStandardUpdaterController`, polluting the
        // production UserDefaults domain with `LastPrimaryAppcastItemDate`,
        // `UpdateFeedPolicy`, and three `SU*` keys (NEW-3 evidence).
        //
        // Tests that want richer probe behavior (e.g. `StubProbeEngine`
        // with decision enqueueing in UpdateServiceTests) still set
        // `injectedForTest` in setUp — that path is checked first in
        // `shared` (line 111) and bypasses this guard entirely.
        //
        // ID-SYNC-0006 (2026-08-08 audit): guard is unconditional (no
        // `#if DEBUG`) because XCTest sets `XCTestConfigurationFilePath`
        // regardless of build config — wrapping in `#if DEBUG` would let
        // release-config XCTest runs bypass the hermetic stub and
        // re-trigger NEW-3 pollution. See NoOpFeedProbeEngine comment
        // above for the symmetric rationale.
        if isRunningTests {
            return UpdateService(probeEngine: NoOpFeedProbeEngine(), autoStart: false)
        }
        return UpdateService()
    }()

    /// Secondary feed mirrored by jsDelivr from this repo's main branch.
    /// Used when the primary feed (GitHub release asset) is unreachable,
    /// e.g. GitHub connectivity problems on some networks. H1: switched to
    /// only with explicit user consent plus a staleness guard — never silently.
    /// LOW-6 (2026-07-26 review): guard-let instead of force-unwrap. The URL
    /// is a compile-time literal — if it's ever invalid we want a clear crash
    /// at startup rather than a mysterious no-op mid-flight.
    static let fallbackFeedURL: URL = {
        guard let url = URL(string: "https://cdn.jsdelivr.net/gh/irykelee/clipmemory@main/appcast.xml") else {
            fatalError("Invalid fallback feed URL — compile-time constant, should never happen")
        }
        return url
    }()

    private static let fallbackConsentKey = "UpdateFallbackFeedConsent"
    private static let lastPrimaryItemDateKey = "LastPrimaryAppcastItemDate"
    private static let feedPolicyKey = "UpdateFeedPolicy"

    /// M13 (2026-08-03): test seam — static injectable UserDefaults suite.
    /// `nonisolated(unsafe)` because the static properties that use it are
    /// nonisolated; the same justification as `ClipboardStore.contentCache`.
    /// Swift 6: first candidate for removal once all nonisolated(unsafe)
    /// statics are eliminated from the service layer.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// NEW-2 (2026-08-06 review): test seam for swapped singleton. When the
    /// injected service is non-nil, `shared` returns that instance instead of
    /// the lazily-initialized production singleton. This lets settings
    /// snapshot tests render the real `UpdateAboutSettingsView` body without
    /// triggering the production side-effects (Sparkle updater, network
    /// probe, defaults migration) that previously wrote 6 production keys.
    ///
    /// **Production code must never set this.** Tests reset it to nil in
    /// `tearDown`. Like `defaults`, it's `nonisolated(unsafe)` for the same
    /// reason — Swift 6 cleanup batch.
    nonisolated(unsafe) static var injectedForTest: UpdateService?

    private let feedProvider = FeedURLProvider()
    private let gentleReminder = GentleUpdateReminder()
    private let updaterController: SPUStandardUpdaterController
    private let probeEngine: FeedProbeEngine
    // BUG-033 (2026-07-21) + M-18 (2026-07-24 audit): lazy var with @MainActor
    // annotation. The @MainActor attribute moves the main-thread guarantee
    // from a runtime `assumeIsolated` check to a compile-time one — Swift
    // rejects any access from a non-main context. SettingsView
    // (`UpdateService.shared.status`) reads from a SwiftUI view body, which
    // is implicitly @MainActor, so the access compiles unchanged.
    @MainActor
    lazy var status: UpdateStatus = UpdateStatus()

    /// Monotonic token for in-flight probes. Incrementing on every
    /// `triggerProbe()` cancels the prior probe's write-back so a slower
    /// earlier probe can't clobber a faster later one.
    private var probeGeneration: Int = 0
    private var currentProbeTask: Task<Void, Never>?

    // BUG-033 (2026-07-21): @MainActor init so UpdateStatus() (now @MainActor)
    // can be constructed inline. All callers (AppDelegate boot, tests) already
    // run on main.
    @MainActor
    init(
        probeEngine: FeedProbeEngine = DefaultFeedProbeEngine(),
        autoStart: Bool = true
    ) {
        Self.migrateFeedConsentIfNeeded()
        self.probeEngine = probeEngine
        // Start is deferred until the primary-feed probe finishes.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: feedProvider,
            userDriverDelegate: gentleReminder
        )
        if autoStart {
            currentProbeTask = Task { @MainActor in await startAfterFeedProbe() }
        }
    }

    /// The user's recorded mirror-feed choice. nil = never asked (H1).
    static var fallbackFeedConsent: Bool? {
        get { Self.defaults.object(forKey: fallbackConsentKey) as? Bool }
        set {
            if let newValue {
                Self.defaults.set(newValue, forKey: fallbackConsentKey)
            } else {
                Self.defaults.removeObject(forKey: fallbackConsentKey)
            }
        }
    }

    /// The user's current update-source policy. Single source of truth.
    static var feedPolicy: UpdateFeedPolicy {
        get {
            guard let raw = Self.defaults.string(forKey: feedPolicyKey),
                  let policy = UpdateFeedPolicy(rawValue: raw) else {
                return .automatic
            }
            return policy
        }
        set {
            Self.defaults.set(newValue.rawValue, forKey: feedPolicyKey)
        }
    }

    /// One-shot migration from legacy `UpdateFallbackFeedConsent` Bool to
    /// `UpdateFeedPolicy` enum. Idempotent — safe to call from init() every launch.
    /// Spec §3.1 migration block.
    static func migrateFeedConsentIfNeeded() {
        guard Self.defaults.object(forKey: feedPolicyKey) == nil else { return }
        if let legacy = fallbackFeedConsent {
            feedPolicy = legacy ? .automatic : .primary
            Self.defaults.removeObject(forKey: fallbackConsentKey)
        } else {
            feedPolicy = .automatic
        }
    }

    /// Newest item date the primary feed last served. Basis of the H1
    /// max-timestamp guard against a stale jsDelivr cache.
    static var lastPrimaryItemDate: Date? {
        get { Self.defaults.object(forKey: lastPrimaryItemDateKey) as? Date }
        set {
            if let newValue {
                Self.defaults.set(newValue, forKey: lastPrimaryItemDateKey)
            } else {
                Self.defaults.removeObject(forKey: lastPrimaryItemDateKey)
            }
        }
    }

    /// M-17 (2026-07-24 audit): DateFormatter instantiation is expensive
    /// (~5–10 ms cold, ~1 ms warm) and was rebuilt on every `latestItemDate`
    /// call. The format string and POSIX locale are constants for the
    /// lifetime of the process — instantiate once.
    private static let appcastDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    /// UPD-4 (2026-07-24 review): the numeric-offset formatter above is
    /// narrower than RFC 822, which also permits NAMED timezones ("GMT",
    /// "PST", ...). A pubDate like "..., 24 Jul 2026 10:00:00 GMT" used to
    /// parse as nil — and the H1 stale guard treats nil as "not stale"
    /// (fail-open), so a stale mirror could slip through. Retry with the
    /// `zzz` (named timezone) pattern before giving up.
    private static let appcastDateFormatterNamedTZ: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// Newest `<pubDate>` among appcast items, or nil when nothing parses.
    /// Pure for tests; production uses it via DefaultFeedProbeEngine's
    /// `parseLatestDate` for the H1 staleness guard.
    static func latestItemDate(inAppcastXML xml: String) -> Date? {
        let formatter = appcastDateFormatter
        var latest: Date?
        var rest = xml[...]
        while let open = rest.range(of: "<pubDate>"),
              let close = rest.range(of: "</pubDate>", range: open.upperBound..<rest.endIndex) {
            let raw = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let date = formatter.date(from: raw) ?? appcastDateFormatterNamedTZ.date(from: raw),
               latest.map({ date > $0 }) ?? true {
                latest = date
            }
            rest = rest[close.upperBound...]
        }
        return latest
    }

    /// Newest `<sparkle:shortVersionString>` among appcast items, or nil
    /// when nothing parses. Picks the item whose `<pubDate>` is the most
    /// recent (same approach as `latestItemDate` above), so the result is
    /// order-independent — correctly handles both ascending and descending
    /// appcasts. This matters because:
    ///   - The repo's `appcast.xml` is historically built in ascending
    ///     order by `release.yml` (oldest first, newest last), but
    ///     Sparkle's documented convention is newest-first.
    ///   - Functions that depend on appcast order silently break when
    ///     the writer changes ("first" / "last" stop being the same
    ///     answer after a prepending fix). Selecting by pubDate removes
    ///     the dependency.
    ///
    /// Falls back to the LAST `<sparkle:shortVersionString>` when no
    /// `<pubDate>` is present (test fixtures, malformed appcasts). This
    /// preserves the test invariant captured by
    /// `testLatestVersionStringIgnoresNonSparkleVersion`: a bare `<version>`
    /// tag (without the `sparkle:` namespace) must be ignored.
    ///
    /// Mirrors `latestItemDate` for symmetry: both pick the item with the
    /// max pubDate, then read the version string from that same item.
    ///
    /// Pure for tests; the view layer only needs `==` against
    /// `CFBundleShortVersionString` (`AppVersion.current`), so semver
    /// sorting is deliberately NOT implemented here.
    static func latestVersionString(inAppcastXML xml: String) -> String? {
        var latestDate: Date?
        var latestVersion: String?
        var idx = xml.startIndex
        // First pass: pubDate-driven selection (order-independent).
        while let pubOpen = xml.range(of: "<pubDate>", range: idx..<xml.endIndex),
              let pubClose = xml.range(of: "</pubDate>",
                                       range: pubOpen.upperBound..<xml.endIndex) {
            let beforePub = xml[idx..<pubOpen.lowerBound]
            let itemStart = beforePub.range(of: "<item>", options: .backwards)?.upperBound
                ?? xml.startIndex
            let itemBody = xml[itemStart..<pubClose.lowerBound]
            let rawDate = String(xml[pubOpen.upperBound..<pubClose.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawVersion: String? = {
                guard let verOpen = itemBody.range(of: "<sparkle:shortVersionString>") else {
                    return nil
                }
                let after = itemBody[verOpen.upperBound..<itemBody.endIndex]
                guard let verClose = after.firstIndex(of: "<") else { return nil }
                let raw = String(after[..<verClose])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            }()
            let date = appcastDateFormatter.date(from: rawDate)
                ?? appcastDateFormatterNamedTZ.date(from: rawDate)
            if let date, let version = rawVersion,
               latestDate.map({ date > $0 }) ?? true {
                latestDate = date
                latestVersion = version
            }
            idx = pubClose.upperBound
        }
        if latestVersion != nil { return latestVersion }
        // Fallback: no pubDate found anywhere — find the LAST
        // <sparkle:shortVersionString>. This matches the original
        // pre-NEW-5 behavior for inputs that don't carry pubDate at all.
        var last: String?
        var scanIdx = xml.startIndex
        while let open = xml.range(of: "<sparkle:shortVersionString>",
                                   range: scanIdx..<xml.endIndex) {
            let after = open.upperBound
            guard let close = xml[after...].firstIndex(of: "<") else { break }
            let raw = String(xml[after..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                last = raw
            }
            scanIdx = close
        }
        return last
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

    /// Persist a new policy and re-resolve the active feed URL.
    @MainActor
    func setPolicy(_ policy: UpdateFeedPolicy) {
        Self.feedPolicy = policy
        // Post-audit-scan fix: cancel the prior task BEFORE assigning the
        // new one. The prior L-2 placement cancelled inside `triggerProbe`,
        // which ran AFTER the previous Task had already been orphaned —
        // and at init time, the startup task cancelled itself on first
        // dispatch (because the post-init call to `currentProbeTask =`
        // inside triggerProbe had nothing to cancel). Cancelling here
        // (1) makes rapid policy switches cleanly chain (no orphan probe)
        // and (2) keeps the startup path from racing itself.
        currentProbeTask?.cancel()
        currentProbeTask = Task { await triggerProbe() }
    }

    /// Run a probe, update feed URL + status. Called at startup and after
    /// `setPolicy`. Spec §3.1 / §3.2.
    /// Concurrency: increments `probeGeneration` before any await; verifies
    /// the captured token still matches after resume before writing back. This
    /// prevents a slow earlier probe from overwriting a faster later one.
    @MainActor
    func triggerProbe() async {
        probeGeneration += 1
        let myGeneration = probeGeneration
        // UPD-1 (2026-07-24 audit): do NOT cancel `currentProbeTask` here —
        // every production caller (init's startAfterFeedProbe at line 123 and
        // setPolicy at line 263) runs `triggerProbe()` INSIDE the Task stored
        // in `currentProbeTask`. The prior `currentProbeTask?.cancel()` aborted
        // the very Task it was running on, so every URLSession fetch threw
        // URLError(.cancelled) before going out — H1 mirror-fallback was
        // silently dead at runtime. The generation-token check below and the
        // cancel in `setPolicy` provide the race protection that was thought
        // to be missing here.
        let channels = UpdateFeedPolicies.knownChannels
        let policy = Self.feedPolicy
        let lastKnown = Self.lastPrimaryItemDate
        let decision = await probeEngine.resolve(
            policy: policy,
            lastKnownDate: lastKnown,
            channels: channels,
            timeout: nil
        )
        // Generation check: a newer `triggerProbe()` ran while we were
        // awaiting — its decision wins, drop ours silently.
        guard myGeneration == probeGeneration else { return }
        guard let decision else { return }
        // UPD-3 (2026-07-24 review): only record a "switch" when the channel
        // actually changed. Previously every probe overwrote
        // lastSwitchReason/lastSwitchAt, so the status panel's "Last switch"
        // lied after each periodic re-probe that kept the same source.
        let didSwitch = decision.usedChannelID != status.currentSource
        feedProvider.resolvedFeedString = decision.chosenURL.absoluteString
        status.currentSource = decision.usedChannelID
        status.lastCheck = Date()
        if didSwitch {
            status.lastSwitchReason = decision.reason.rawValue
            status.lastSwitchAt = Date()
        }
        // Per spec §3.1: only update lastPrimaryItemDate when primary actually
        // fetched (decision carries the body — no second URLSession call).
        // Use `max(old, new)` so out-of-order responses can only ever raise
        // the baseline, never roll it back.
        if let observed = decision.primaryLatestDate {
            let newBaseline: Date
            if let existing = Self.lastPrimaryItemDate {
                newBaseline = observed > existing ? observed : existing
            } else {
                newBaseline = observed
            }
            Self.lastPrimaryItemDate = newBaseline
        }
        // C2 (v2.7.9): publish the latest version string from the same
        // primary appcast body so the settings panel can show "current vs
        // latest". No second URLSession call — reuses the body that the
        // probe already fetched. nil when the primary channel wasn't
        // reached or the body had no parseable shortVersionString.
        if let xml = decision.primaryAppcastXML,
           let latest = Self.latestVersionString(inAppcastXML: xml) {
            status.latestAvailableVersion = latest
        }
        // resetUpdateCycleAfterShortDelay() does not throw on macOS in
        // Sparkle 2.9.4 — only SPUUpdater.start() does. Fire-and-forget.
        updaterController.updater.resetUpdateCycleAfterShortDelay()
    }

    /// ID-UPDATE-0001 (2026-07-31 Round 5): SUFeedURL presence check,
    /// injectable for tests — the test runner bundle has no SUFeedURL key,
    /// so the probe path would never be exercised otherwise.
    var hasFeedURL: () -> Bool = {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
    }

    /// ID-UPDATE-0001: test observation hook fired at the top of
    /// `startUpdater()` so tests can assert the start path was reached.
    var startUpdaterHook: (() -> Void)?

    /// Probe the primary feed; only with persisted (or freshly given) user
    /// consent fall back to the jsDelivr mirror, then start the updater.
    /// The network fetches run off the main thread; Sparkle calls stay on main.
    /// Internal (not private) since ID-UPDATE-0001 so tests can drive the
    /// probe-then-start path directly.
    @MainActor
    func startAfterFeedProbe() async {
        guard hasFeedURL() else {
            startUpdater()
            return
        }
        // ID-LIFE-0006 (2026-07-30 audit): capture generation before await
        // so we can detect mid-probe setPolicy() calls. If a new
        // triggerProbe() ran while we were awaiting, skip startUpdater() to
        // avoid racing the newer probe's writeback.
        // ID-UPDATE-0001 (2026-07-31): triggerProbe() ALWAYS increments the
        // generation exactly once — our own probe. The original guard
        // (`myGeneration == probeGeneration`) could therefore never pass and
        // startUpdater() was dead code: Sparkle never started in production.
        // Our own probe accounts for exactly +1; anything beyond that means
        // a newer probe (e.g. setPolicy) ran while we were awaiting.
        let myGeneration = probeGeneration
        await triggerProbe()
        guard probeGeneration == myGeneration + 1 else { return }
        startUpdater()
    }

    // BUG-032 (2026-07-21): askFallbackConsent (private @MainActor) was
    // dead code — never called. Fallback is handled automatically by
    // FeedProbeEngine's .automatic policy. Method deleted.
    // ID-LINT-0001 (2026-08-13): alertUpdateFallback* L10n keys (and
    // their 7-language .strings entries) cleaned up — see commit that
    // adds Scripts/lint-translations.sh; that script would now FAIL
    // any future re-introduction of dead keys.

    @MainActor
    private func startUpdater() {
        startUpdaterHook?() // ID-UPDATE-0001: test observation hook
        do {
            try updaterController.updater.start()
        } catch {
            NSLog("ClipMemory: Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }
}
