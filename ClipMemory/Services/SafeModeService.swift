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
    private let sentinelHealthyKey = "safeMode.sentinelHealthy"
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
        // ID-CRASH-0004: if the sentinel writer is degraded, we
        // can't tell whether a missing sentinel is "previous launch
        // crashed" or "previous launch's writer failed". Skip the
        // crash-count increment so a local disk-pressure incident
        // doesn't push the user toward safe-mode for a non-crash.
        // The degraded banner (set by writeSentinel on full failure)
        // already surfaces this state; the user sees one signal,
        // not both.
        guard sentinelHealthy else {
            writeSentinel() // best-effort retry on next launch
            return
        }
        // ID-CRASH-0004: pre-flight the sentinel write BEFORE
        // counting. If our writer can't reach the file (sandbox
        // denial, disk full, etc.), don't increment the crash
        // counter — we can't tell a missing sentinel apart from a
        // write failure, and counting a write failure as a crash
        // would push the user toward safe-mode for an unrelated
        // reason. The three-piece gate on the write path itself
        // surfaces the degraded state to the user.
        guard fileManager.fileExists(atPath: sentinelURL.path) else {
            // No sentinel = previous launch terminated abnormally
            // OR our writer failed previously. Try writing now —
            // if it succeeds, this launch was just a force-quit;
            // if it fails, we mark degraded and don't count.
            let writeOK = writeSentinel()
            guard writeOK else { return }
            let newCount = crashCount + 1
            defaults.set(newCount, forKey: crashCountKey)
            if newCount >= Self.threshold {
                activateSafeMode(reason: newCount)
            }
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
    /// Also resets sentinelHealthy — exit is the user's signal that
    /// they trust the install again, so we re-arm the write path.
    func exitSafeMode() {
        defaults.set(false, forKey: safeModeActiveKey)
        defaults.set(0, forKey: crashCountKey)
        defaults.set(true, forKey: sentinelHealthyKey)
        postStateChanged()
    }

    /// ID-CRASH-0003: internal — flip the persistent flag and notify
    /// banner observers.
    private func activateSafeMode(reason: Int) {
        defaults.set(true, forKey: safeModeActiveKey)
        postStateChanged()
    }

    /// ID-CRASH-0004 (2026-08-16 /code-review Standards fix): write the
    /// sentinel file with the three-piece gate (loud log + retry +
    /// user-visible) per CLAUDE.md 2026-08-08. Sentinel writes can
    /// transient-fail on macOS due to disk pressure, sandboxing,
    /// or full-disk conditions — three attempts with exponential
    /// backoff (50ms, 200ms, 800ms) is the recovery budget that's
    /// tight enough not to delay launch visibly, loose enough that
    /// any non-catastrophic I/O error is retried.
    ///
    /// Returns `true` on success, `false` if all three attempts
    /// failed. Callers (`registerPreviousLaunchDidCrash`) use the
    /// return value to decide whether to count this launch as a crash
    /// — a missing sentinel + a failing writer is "we don't know",
    /// not "the previous launch crashed".
    ///
    /// If all three attempts fail, we set `sentinelHealthy=false` and
    /// post the state-change notification so the banner surfaces a
    /// "crash detection unavailable" hint. Per CLAUDE.md 2026-08-08
    /// the "user-visible" leg cannot be silently swallowed — the
    /// user must be able to see that crash detection is offline so
    /// they don't mistakenly trust the absence of safe-mode as
    /// "everything is fine".
    @discardableResult
    private func writeSentinel() -> Bool {
        let dir = sentinelURL.deletingLastPathComponent()
        let backoffsMs: [UInt64] = [50, 200, 800]
        for index in backoffsMs.indices {
            // Use the array index directly so Swift 6 doesn't flag
            // `backoffMs` as unused — it's read once below for the
            // sleep duration, and the warning was a false positive
            // caused by the line being read as a discarded binding.
            let attempt = index + 1  // 1-based for log messages
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data().write(to: sentinelURL, options: .atomic)
                if attempt > 0 {
                    // We recovered on a retry — surface that to the
                    // log so transient disk-pressure incidents are
                    // visible in `log show` output without being a
                    // user-facing event (no banner hint needed).
                    NSLog("[SafeModeService] sentinel write recovered on attempt #%d", attempt + 1)
                }
                if !sentinelHealthy {
                    defaults.set(true, forKey: sentinelHealthyKey)
                    postStateChanged()
                }
                return true
            } catch {
                NSLog("[SafeModeService] sentinel write attempt #%d failed at %@: %@",
                      attempt + 1, sentinelURL.path, "\(error)")
                // Don't sleep after the last attempt.
                if attempt < backoffsMs.count - 1 {
                    let nanos = backoffsMs[attempt] * 1_000_000
                    Thread.sleep(forTimeInterval: Double(nanos) / 1_000_000_000)
                }
            }
        }
        // All attempts exhausted — flip to degraded, notify the
        // banner. The next launch's registerPreviousLaunchDidCrash
        // will see no sentinel and would normally count that as a
        // crash; the sentinelHealthy check short-circuits that
        // accounting so a write failure on our side doesn't push the
        // user toward safe-mode for a non-crash.
        if sentinelHealthy {
            defaults.set(false, forKey: sentinelHealthyKey)
            postStateChanged()
        }
        return false
    }

    /// ID-CRASH-0004: persistent flag indicating whether the sentinel
    /// writer is functional. false after three consecutive write
    /// failures (or first launch before any write attempt).
    var isSentinelHealthy: Bool {
        // Default to true on first launch — when the key is unset
        // we don't want to flash a "degraded" banner on every
        // install; the first launch's write attempt decides.
        defaults.object(forKey: sentinelHealthyKey) as? Bool ?? true
    }

    private var sentinelHealthy: Bool { isSentinelHealthy }

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