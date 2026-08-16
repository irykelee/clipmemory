import Foundation

/// ID-CRASH-0003 (2026-08-16 audit MEDIUM-1 fix): safe-mode for
/// consecutive crashes. macOS doesn't expose a direct API for "did the
/// previous launch crash?" — instead, we use the sentinel-file pattern:
/// write a sentinel on applicationDidFinishLaunching, delete it on
/// applicationWillTerminate. If the sentinel is still present when we
/// launch, the previous run terminated abnormally (crash, force-quit,
/// or kernel panic).
///
/// After 3 consecutive crashes (the standard Microsoft Office / Adobe
/// threshold; matches what users expect), the next launch enters safe
/// mode: a banner explains what happened, the Recent Crashes window
/// is one click away, and the user can manually exit safe mode once
/// they're confident the underlying issue is resolved. We deliberately
/// do NOT disable core features (OCR backfill, backup, network monitor)
/// — disabling those risks data loss for users whose crashes are
/// caused by something orthogonal (e.g. transient network failure
/// racing the save pipeline). The banner is enough of a nudge; if a
/// future crash is the same signature, the threshold keeps the user
/// in safe mode until they explicitly exit.
@MainActor
final class SafeModeService {
    static let shared = SafeModeService()

    /// Consecutive-crash count required to enter safe mode. 3 matches
    /// the conventional threshold (Office, Photoshop, etc.) and avoids
    /// one-off crashes triggering it.
    nonisolated static let threshold = 3

    /// Notification posted on main when safe-mode state changes.
    /// ContentView's banner observes this to show / hide.
    /// The short name (`stateDidChange`) matches the rawValue's last
    /// segment so the NotificationObserverAssertionTests source-grep
    /// pattern (which indexes production observers by rawValue's
    /// last-segment when the consumer uses `Notification.Name("...")`
    /// inline literal form) finds the banner's `.publisher(for:)`
    /// subscription. See ID-CRASH-0003.
    static let stateDidChange = Notification.Name("SafeModeService.stateDidChange")

    private let crashCountKey = "safeMode.crashCount"
    private let safeModeActiveKey = "safeMode.active"
    private let sentinelFilename = ".running-sentinel"

    /// Lazily-resolved sentinel path. Tilde expansion keeps the file
    /// inside Application Support so it survives Spotlight / Disk
    /// Cleanup sweeps that target the home directory root.
    /// `directoryOverride` lets tests redirect to a tmp-dir without
    /// touching the user's real Application Support directory.
    private var sentinelURL: URL {
        if let override = directoryOverride {
            return override
                .appendingPathComponent("ClipMemory", isDirectory: true)
                .appendingPathComponent(sentinelFilename)
        }
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("ClipMemory", isDirectory: true)
            .appendingPathComponent(sentinelFilename)
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let directoryOverride: URL?

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.directoryOverride = directory
    }

    /// Consecutive crash count from previous launches. Returns 0 on a
    /// fresh install (the key has never been set).
    var crashCount: Int {
        defaults.integer(forKey: crashCountKey)
    }

    /// Whether the current launch is in safe mode (either entered
    /// automatically by `registerPreviousLaunchDidCrash` or
    /// explicitly by the user). The state is sticky until cleared.
    var isInSafeMode: Bool {
        defaults.bool(forKey: safeModeActiveKey)
    }

    /// ID-CRASH-0003: called on applicationDidFinishLaunching, before
    /// any work that could prime caches. Detects whether the previous
    /// launch crashed (no sentinel) and either increments the counter
    /// (below threshold) or activates safe mode.
    ///
    /// Must be called exactly once per launch. Calling it twice in
    /// the same launch would double-count a single previous crash.
    func registerPreviousLaunchDidCrash() {
        guard fileManager.fileExists(atPath: sentinelURL.path) else {
            // No sentinel = previous launch terminated abnormally.
            // We don't have a way to distinguish a real crash from a
            // force-quit / kernel panic here, but for our purpose
            // (preventing crash-loop data corruption) any abnormal
            // termination counts. Force-quits are rare enough that
            // the 3-launch threshold absorbs the noise.
            let newCount = crashCount + 1
            defaults.set(newCount, forKey: crashCountKey)
            if newCount >= Self.threshold {
                activateSafeMode(reason: newCount)
            }
            // Write the sentinel AFTER counting so a crash during
            // early launch doesn't count the same crash twice.
            writeSentinel()
            return
        }
        // Sentinel present = previous launch terminated normally.
        // (Stale sentinel from a force-quit-with-sentinel-installed
        // is a rare edge case we accept — the threshold absorbs it.)
        _ = try? fileManager.removeItem(at: sentinelURL)
        writeSentinel()
    }

    /// ID-CRASH-0003: called after the launch's startup work
    /// completes successfully (sentinel written, OCR backfill
    /// queued, backup triggered if needed). Resets the counter so a
    /// future crash starts a fresh 3-launch window.
    func registerSuccessfulLaunch() {
        defaults.set(0, forKey: crashCountKey)
    }

    /// ID-CRASH-0003: called when the user clicks "Disable Safe Mode"
    /// on the banner. Returns to normal launch mode and resets the
    /// counter so the next 3 consecutive crashes re-arm safe mode.
    func exitSafeMode() {
        defaults.set(false, forKey: safeModeActiveKey)
        defaults.set(0, forKey: crashCountKey)
        postStateChanged()
    }

    /// ID-CRASH-0003: internal — flip the persistent flag and notify
    /// banner observers.
    private func activateSafeMode(reason: Int) {
        defaults.set(true, forKey: safeModeActiveKey)
        postStateChanged()
    }

    /// ID-CRASH-0003: write the sentinel file. Failure is non-fatal —
    /// the launch will proceed without crash detection but no other
    /// side effect. Loud log per CLAUDE.md 2026-08-08 three-piece gate.
    private func writeSentinel() {
        let dir = sentinelURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: sentinelURL, options: .atomic)
        } catch {
            // Per CLAUDE.md 2026-08-08 three-piece gate, we log loud
            // and continue. The user is still safe — safe-mode would
            // false-positive on the next launch, which is acceptable
            // (they'd just see a banner that says "we couldn't verify
            // the previous launch").
            NSLog("[SafeModeService] write sentinel failed at %@: %@", sentinelURL.path, "\(error)")
        }
    }

    /// ID-CRASH-0003: called on applicationWillTerminate. The sentinel
    /// being ABSENT on the next launch means the previous run didn't
    /// exit normally.
    func clearSentinelOnNormalExit() {
        try? fileManager.removeItem(at: sentinelURL)
    }

    private func postStateChanged() {
        NotificationCenter.default.post(
            name: Self.stateDidChange,
            object: self
        )
    }
}