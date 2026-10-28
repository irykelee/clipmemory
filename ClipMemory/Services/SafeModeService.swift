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
    /// ID-REVIEW-1046 (2026-10-28): the app's shared instance.
    ///
    /// ⚠️ `countsCrashes` is **false in a test process** — and that is not
    /// a convenience, it is the only correct behaviour there:
    ///
    /// * A test process has **no "previous launch"** to judge ⇒ the
    ///   crash counters are meaningless ⇒ but the SENTINEL FILE still has
    ///   to be written, because that write is what proves the test host
    ///   never touches the user's own sentinel (ID-REVIEW-1045's
    ///   「同族第 9 例」guard).
    /// * The bookkeeping writes `safeMode.crashCount` / `safeMode.active`
    ///   / `safeMode.sentinelHealthy` into the **process-shared**
    ///   `SafeModeService-XCTest-isolation` suite. The app's startup runs
    ///   on the main run loop, i.e. at a moment that is **not attributable
    ///   to any test** ⇒ the ZZZ canary ends up blaming an innocent
    ///   bystander for the app's own write (measured 2026-10-28: the
    ///   canary named `TrashStoreMainActorTests`, a test that never
    ///   touches SafeMode). The same shape as the async-writer problem
    ///   the bootstrap documents for `ImageIntegrity.scannedMtimes`.
    ///   ⇒ Skip the bookkeeping in a test process ⇒ the shared suite
    ///   stays pristine ⇒ the canary keeps its teeth for **real**
    ///   test-side leaks.
    static let shared = SafeModeService(countsCrashes: !TestIsolation.isRunningTests)

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

    // P1-AUDIT-2026-09-22 (P2-9): central `UserDefaultsKey` rawValues.
    private var crashCountKey: String { UserDefaultsKey.safeModeCrashCount.rawValue }
    private var safeModeActiveKey: String { UserDefaultsKey.safeModeActive.rawValue }
    private var sentinelHealthyKey: String { UserDefaultsKey.safeModeSentinelHealthy.rawValue }
    private let sentinelFilename = ".running-sentinel"

    /// Lazily-resolved sentinel path. Tilde expansion keeps the file
    /// inside Application Support so it survives Spotlight / Disk
    /// Cleanup sweeps that target the home directory root.
    /// `directoryOverride` lets tests redirect to a tmp-dir without
    /// touching the user's real Application Support directory.
    ///
    /// ID-REVIEW-1045 (2026-10-28): the **test host** must not touch the
    /// user's sentinel either. `SafeModeService.xcTestDefaults` isolates
    /// the three UserDefaults keys, but the sentinel is a **FILE** and
    /// its path was NOT isolated ⇒ the test host deleted and rewrote
    /// `~/Library/Application Support/ClipMemory/.running-sentinel` on
    /// every run (measured 2026-10-28: the file's inode AND mtime both
    /// changed across a single test run).
    ///
    /// ⇒ Why that matters to the user: the sentinel is the crash
    /// detector's memory of "the previous launch exited normally".
    /// The test host deleting it makes the real app believe its previous
    /// launch crashed (⇒ a spurious crash count, possibly a spurious
    /// safe-mode entry), and the test host rewriting it makes the real
    /// app believe the previous launch was clean (⇒ a real crash is not
    /// counted). Both directions weaken a user-visible safety net.
    ///
    /// ⇒ Same isolation pattern as `ImageStorage` (`Images-Tests`) and
    /// `CryptoService` (`Keys-Tests`): a dedicated test-only directory
    /// under Application Support. Production behaviour is unchanged
    /// (`isRunningTests` is false in production).
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
            .appendingPathComponent(Self.sentinelDirectoryName(isRunningTests: TestIsolation.isRunningTests),
                                    isDirectory: true)
            .appendingPathComponent(sentinelFilename)
    }

    /// ID-REVIEW-1045: the **pure** decision seam — which directory holds
    /// the crash sentinel.
    ///
    /// Split out so the production half is directly assertable: in a test
    /// host the probe is always true, so "production ⇒ the user's own
    /// directory" could not be checked from inside the test process.
    nonisolated static func sentinelDirectoryName(isRunningTests: Bool) -> String {
        isRunningTests ? "ClipMemory/SafeMode-Tests" : "ClipMemory"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let directoryOverride: URL?
    /// Whether this instance keeps the crash bookkeeping at all.
    ///
    /// ID-REVIEW-1046 (2026-10-28): `false` for the app's shared instance
    /// **in a test process** (see the note on `shared`). Every unit test
    /// constructs its own service ⇒ the default `true` keeps the full
    /// behaviour under test.
    private let countsCrashes: Bool
    /// Whether THIS launch detected that the previous run crashed.
    ///
    /// ID-REVIEW-1046 (2026-10-28, independent verifier measured): the
    /// counter's streak must survive a launch that *detected* a crash —
    /// otherwise the threshold can never be reached (the launch that
    /// detects a crash is itself a successful launch, so an unconditional
    /// reset would wipe the crash it just counted).
    private var detectedCrashThisLaunch = false

    /// ID-REVIEW-1011 (code-review-2026-10-01 v2.9.6 safe-mode seam):
    /// XCTest isolation helper. Mirrors `ClipboardStore.xcTestDefaults`
    /// and `HotKeyManager.xcTestDefaults`: returns `.standard` when not
    /// under XCTest (production), an isolated suite keyed
    /// `SafeModeService-XCTest-isolation` otherwise. `init(defaults:)`
    /// defaults to this so under XCTest the 3 sentinel keys
    /// (`safeMode.active` / `safeMode.crashCount` /
    /// `safeMode.sentinelHealthy`) don't pollute the production
    /// `com.clipmemory.app` suite.
    nonisolated static var xcTestDefaults: UserDefaults {
        // ID-CRASH-0031 (2026-10-20): shared multi-signal probe — the
        // env var alone is not a reliable "am I under XCTest" test.
        if !TestIsolation.isRunningTests {
            return .standard
        }
        return UserDefaults(suiteName: "SafeModeService-XCTest-isolation") ?? .standard
    }

    init(
        defaults: UserDefaults = SafeModeService.xcTestDefaults,
        fileManager: FileManager = .default,
        directory: URL? = nil,
        countsCrashes: Bool = true
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.directoryOverride = directory
        self.countsCrashes = countsCrashes
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

    /// ID-REVIEW-1046 (2026-10-28): the key that marks the one-shot
    /// reconciliation of the state the INVERTED sentinel polarity left
    /// behind. See `reconcileLegacyCrashPolarity()`.
    nonisolated static let legacyCrashPolarityMigrationKey = "safeMode.polarityFixedV1"

    /// ID-REVIEW-1046 (2026-10-28): **一次性**清理旧极性误置的状态。
    ///
    /// ## 为什么要清理
    ///
    /// 旧实现把哨兵极性写反了（协议是「哨兵**存在** ⇔ 上次**没有**正常
    /// 退出 ⇒ 崩溃」，实现却按「哨兵**不存在** ⇒ 崩溃」计数）⇒ **每一次
    /// 正常退出都被记成一次崩溃**。用户机器上的实测后果：
    /// `safeMode.crashCount` 涨到 8、`safeMode.active` 被置为 true
    /// （阈值 3）⇒ **用户正被一个从未崩溃过的 app 挡在安全模式外面**。
    ///
    /// ## 为什么该清（**强论证**，不是「证明」）
    ///
    /// 旧极性下，计数**只**在「上次没有哨兵」时 +1；而按协议
    /// （`clearSentinelOnNormalExit` 在**正常退出**时删哨兵），「上次没有
    /// 哨兵」**绝大多数**对应「上次**正常退出**」⇒ **旧极性记下来的绝大多数
    /// 「崩溃」都是一次正常退出** ⇒ 计数与安全模式标志**几乎必然是假的**。
    ///
    /// ⚠️ **订正（ID-REVIEW-1046 独立核验 P2-1）**：本节原先写的是「『上次
    /// 没有哨兵』**唯一**对应『上次正常退出』⇒ 计数与安全模式标志
    /// **100% 是假的**」⇒ **那是过头的**：「上次没有哨兵」还有另外几种成因 ——
    /// ① **启动早期的崩溃**（崩在哨兵写下之前 ⇒ 那次崩溃在旧极性下**确实**
    /// 被计了 ⇒ 计数里**可能有真计数**）；② 全新安装；③ ID-REVIEW-1045 的
    /// 测试宿主删过用户的哨兵；④ 用户或清理工具删了它。
    /// ⇒ ⇒ 正确表述是「**绝大多数是假的**」⇒ 清理仍是**还原**，但不再声称
    /// 是「证明」。
    ///
    /// **补强论证**（即便计数里混着真计数，清理依然正确）：
    /// * `safeMode.active` 只可能由 `activateSafeMode()`（崩溃路径）置真，
    ///   用户只能**清**不能置 ⇒ 它**只能**来自那条误计数路径；
    /// * 翻正后的极性下，计数语义是「距上一次干净启动的连续崩溃数」⇒
    ///   迁移把计数清零后，**新语义下本来就要从 0 起步** ⇒ 迁移不是
    ///   「额外抹掉」什么，只是**提前**做了新语义要求的第一步。
    ///
    /// ## 只做一次
    ///
    /// 迁移标记（`legacyCrashPolarityMigrationKey`）保证它**只**跑一次：
    /// 迁移之后新产生的合法安全模式不会被第二次清理掉。
    func reconcileLegacyCrashPolarity() {
        // ID-REVIEW-1046: a test process keeps no crash bookkeeping at all
        // (see `shared`) ⇒ the migration has nothing to reconcile there.
        guard countsCrashes else { return }
        guard defaults.object(forKey: Self.legacyCrashPolarityMigrationKey) == nil else { return }
        defaults.set(true, forKey: Self.legacyCrashPolarityMigrationKey)

        let wasActive = defaults.bool(forKey: safeModeActiveKey)
        let count = defaults.integer(forKey: crashCountKey)
        guard wasActive || count > 0 else { return }

        defaults.set(false, forKey: safeModeActiveKey)
        defaults.set(0, forKey: crashCountKey)
        postStateChanged()
        NSLog("[SafeModeService] ID-REVIEW-1046: cleared the spurious safe-mode state "
              + "(active=\(wasActive), crashCount=\(count)) left by the inverted sentinel polarity")
    }

    /// ID-CRASH-0003: called on applicationDidFinishLaunching, before
    /// any work that could prime caches. Detects whether the previous
    /// launch crashed (**the sentinel is still there** — it is written at
    /// launch and deleted on a graceful exit) and either increments the
    /// counter (below threshold) or activates safe mode.
    ///
    /// ⚠️ ID-REVIEW-1046: this call must happen **as early as possible**
    /// in the launch: the sentinel it writes is the only evidence that
    /// the previous run reached this point ⇒ a crash BEFORE this call
    /// leaves no sentinel ⇒ the next launch cannot tell "crashed" from
    /// "exited gracefully" ⇒ that crash is never counted.
    ///
    /// Must be called exactly once per launch. Calling it twice in
    /// the same launch would double-count a single previous crash.
    func registerPreviousLaunchDidCrash() {
        // ID-REVIEW-1046: a test process has no "previous launch" to judge
        // ⇒ no crash bookkeeping ⇒ no writes into the process-shared
        // SafeMode suite (which the ZZZ canary watches — an app-startup
        // write there is not attributable to any test, so the canary would
        // blame a bystander).
        //
        // The SENTINEL FILE is still written — into the TEST-ISOLATED
        // directory (ID-REVIEW-1045's 同族第 9 例 fix) — because that
        // write is exactly what proves the test host never touches the
        // user's own sentinel.
        guard countsCrashes else {
            writeSentinel()
            return
        }
        // ID-REVIEW-1046: reconcile the state the inverted polarity left
        // behind BEFORE the crash accounting runs (the accounting below
        // then sees the restored, truthful counter).
        reconcileLegacyCrashPolarity()
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
        // counter — we can't tell "the previous run crashed" apart
        // from "our writer failed", and counting a write failure as
        // a crash would push the user toward safe-mode for an
        // unrelated reason. The three-piece gate on the write path
        // itself surfaces the degraded state to the user.
        //
        // ID-REVIEW-1046 (2026-10-28): the POLARITY FIX.
        //
        // The protocol (see this file's header comment,
        // `clearSentinelOnNormalExit()` and
        // `AppDelegate.applicationWillTerminate`):
        //
        //   * the sentinel is WRITTEN at launch,
        //   * it is DELETED on a GRACEFUL exit,
        //   * ⇒ "the sentinel is STILL THERE at the next launch" means
        //     "the previous run never reached applicationWillTerminate"
        //     ⇒ THAT is the crash signal.
        //
        // The old code had it backwards — it counted a crash when the
        // sentinel was MISSING, i.e. exactly when the previous run had
        // exited gracefully. Measured consequences on the user's own
        // machine: every normal ⌘Q was counted as a crash
        // (`safeMode.crashCount` reached 8, `safeMode.active` was
        // switched on for an app that had never crashed), and real
        // crashes were never detected at all.
        let sentinelSurvived = fileManager.fileExists(atPath: sentinelURL.path)
        detectedCrashThisLaunch = sentinelSurvived
        // The sentinel on disk belongs to the PREVIOUS launch — ours
        // must be fresh, so drop it before writing our own.
        _ = try? fileManager.removeItem(at: sentinelURL)
        if sentinelSurvived {
            // The previous launch did NOT exit gracefully ⇒ it crashed.
            let writeOK = writeSentinel()
            guard writeOK else { return }
            let newCount = crashCount + 1
            defaults.set(newCount, forKey: crashCountKey)
            if newCount >= Self.threshold {
                activateSafeMode(reason: newCount)
            }
            return
        }
        // No sentinel ⇒ the previous launch exited gracefully ⇒ NOT a
        // crash. Just take the sentinel for this launch.
        writeSentinel()
    }

    /// ID-CRASH-0003: called after the launch's startup work
    /// completes successfully (sentinel written, OCR backfill
    /// queued, backup triggered if needed). Resets the counter so a
    /// future crash starts a fresh 3-launch window.
    func registerSuccessfulLaunch() {
        // ID-REVIEW-1046: no bookkeeping in a test process (see `shared`).
        guard countsCrashes else { return }
        // ⚠️ ID-REVIEW-1046 (independent verifier, measured): the reset
        // MUST be conditional. A launch that just DETECTED a crash is
        // itself a successful launch ⇒ an unconditional reset would wipe
        // the crash it just counted ⇒ the counter could never exceed 1 ⇒
        // **the 3-consecutive-crash threshold would be unreachable** and
        // safe mode would be dead code (the verifier's probe: 8
        // consecutive crashes ⇒ the counter stayed 0).
        //
        // ⇒ the streak is broken only by a launch that did NOT follow a
        // crash (i.e. the previous run exited gracefully).
        //
        // ⚠️ Because the decision is "did THIS launch detect a crash",
        // the CALL SITE's position does not matter ⇒ moving it next to
        // `registerPreviousLaunchDidCrash()` is harmless. (The ledger's
        // earlier text claimed that position was fatal — corrected in
        // §46; the claim was true for the UNCONDITIONAL reset.)
        guard !detectedCrashThisLaunch else { return }
        defaults.set(0, forKey: crashCountKey)
    }

    /// ID-CRASH-0003: called when the user clicks "Disable Safe Mode"
    /// on the banner. Returns to normal launch mode and resets the
    /// counter so the next 3 consecutive crashes re-arm safe mode.
    /// Also resets sentinelHealthy — exit is the user's signal that
    /// they trust the install again, so we re-arm the write path.
    func exitSafeMode() {
        // ID-REVIEW-1046: in a test process the bookkeeping is off ⇒ don't
        // write into the process-shared SafeMode suite (the ZZZ canary
        // watches it, and a write there is not attributable to any test).
        guard countsCrashes else { return }
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
                    // ID-REVIEW-1046: in a test process the bookkeeping is
                    // off ⇒ don't write into the shared SafeMode suite.
                    if countsCrashes {
                        defaults.set(true, forKey: sentinelHealthyKey)
                        postStateChanged()
                    }
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
        // cannot distinguish "the previous run crashed" from "our own
        // writer failed" ⇒ the sentinelHealthy check short-circuits that
        // accounting so a write failure on our side doesn't push the
        // user toward safe-mode for a non-crash.
        if sentinelHealthy {
            // ID-REVIEW-1046: in a test process the bookkeeping is off ⇒
            // don't write into the shared SafeMode suite (the ZZZ canary
            // watches it, and an app-startup write there is not
            // attributable to any test).
            if countsCrashes {
                defaults.set(false, forKey: sentinelHealthyKey)
                postStateChanged()
            }
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
    /// is DELETED here ⇒ the next launch finds no sentinel ⇒ it concludes
    /// "the previous run exited gracefully" ⇒ no crash is counted.
    ///
    /// ⚠️ ID-REVIEW-1046: the polarity used to be the other way round
    /// (this doc used to say "the sentinel being ABSENT on the next
    /// launch means the previous run didn't exit normally") ⇒ every
    /// normal exit was counted as a crash. The header comment of this
    /// file and `AppDelegate.applicationWillTerminate` have always
    /// described the CORRECT polarity; the implementation did not match
    /// them until ID-REVIEW-1046.
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
