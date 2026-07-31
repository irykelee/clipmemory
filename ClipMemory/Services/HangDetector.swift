import Foundation
import os.log

/// ABC §C observability: watchdog that detects main-thread hangs >60s and
/// logs `Thread.callStackSymbols` to surface post-mortem root cause for
/// bugs like 2026-07-19 21:35 "sidebar OK but main empty".
///
/// ID-LIFE-0024 (2026-07-31 audit, decision: ACCEPT AS-IS): the captured
/// stack is the RECOVERY-moment stack, not the in-hang stack. The stack
/// timer runs on the main queue, so while the main thread is genuinely
/// blocked it cannot fire; by the time it fires, the hang is over and
/// `Thread.callStackSymbols` yields the timer-drain frames of the recovery
/// moment (which is why `noiseFilter` often collapses the preview to
/// `"(empty)"`). Treat logged stacks as a coarse reference signal only —
/// they have no post-mortem value for the real hang site. Capturing the
/// actual in-hang main stack would require sampling the main thread from
/// the checker thread via mach APIs (`thread_get_state`), a deliberate
/// architecture change that was NOT taken.
///
/// Architecture (3 timers, per spec §4.1):
/// - heartbeat (main, 1s) — refreshes `state.lastHeartbeat`
/// - stack (main, 5s)     — checks recovery; captures `Thread.callStackSymbols`
///   ONLY when a hang is suspected (detection active or heartbeat stale past
///   threshold). See INFRA-2 note on `recordStackCaptureAndMaybeRecover` and
///   the ID-LIFE-0024 caveat above (recovery-moment stack, reference only).
/// - checker (.utility, 30s) — reads `elapsed` and emits detection log when stale
///
/// Mirrors `UIObservability`'s split (per spec §2): pure `formatXxx` helpers +
/// thin `logXxx` wrappers. Tests assert state, not log calls (os.Logger is a
/// concrete type and can't be injected for assertions).
enum HangDetector {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "Hang")

    // MARK: - State

    private struct State {
        var lastHeartbeat: Date
        // No explicit cap on `lastMainStack` length — `Thread.callStackSymbols`
        // can in theory produce thousands of frames (deep recursion). A typical
        // capture is ~30-50 lines; memory pressure is negligible. v2 may add
        // a depth cap if real-world captures get unwieldy.
        var lastMainStack: [String]
        var lastDetectedAt: Date?     // nil = healthy; non-nil = currently in a hang
        var firstDetectedAt: Date?    // written once per hang (used to compute downtime accurately)
        var detectionCount: Int       // detection logs emitted for the current hang; capped at `maxDetectionCount`
    }

    // NSLock because state may be touched from main queue (heartbeat timer +
// stack timer + checker timer .utility queue). Originally
// OSAllocatedUnfairLock but C-1 (2026-07-24 audit) flagged it as
// macOS 14+ only; per-tick interaction (~once per 1s/5s/30s) is below
// any contention threshold where NSLock vs unfair lock is measurable.
    private static let stateLock = NSLock()
    private static var state: State = State(
        lastHeartbeat: Date(),
        lastMainStack: [],
        lastDetectedAt: nil,
        firstDetectedAt: nil,
        detectionCount: 0
    )

    /// Single-lock access to the State struct. Mirrors the API surface of
    /// `OSAllocatedUnfairLock.withLock` so call sites only need a
    /// receiver-name swap (withStateLock { ... } → withStateLock { ... }).
    private static func withStateLock<R>(_ block: (inout State) throws -> R) rethrows -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try block(&state)
    }
    // 3 timer refs split as individual optionals (avoids Large-Tuple lint rule)
    private static var heartbeatTimer: DispatchSourceTimer?
    private static var stackTimer: DispatchSourceTimer?
    private static var checkerTimer: DispatchSourceTimer?
    // main-thread only; set at end of `start()` after all 3 timer `resume()` calls
    // (per spec §10.2 + gate 1b Ma — avoids permanent no-op if a future API throws mid-setup).
    // ID-LIFE-0022 (2026-07-31 audit): `stop()` now RESETS this flag — the
    // original §10.2 "故意的不对称" left it true after stop(), making any
    // later `start()` a permanent no-op (stopped watchdog could never restart).
    private static var isStarted: Bool = false

    // MARK: - Tunables (internal so tests can read; mutable by amending `let` if ever needed)

    static let thresholdSeconds: TimeInterval = 60
    static let stackCaptureIntervalSeconds: TimeInterval = 5
    static let checkerIntervalSeconds: TimeInterval = 30
    static let maxDetectionCount: Int = 5

    // MARK: - Pure format helpers (spec §6.1)

    /// `"hang.detected elapsed=72.34s threshold=60s"`
    static func formatHangDetected(elapsed: TimeInterval, threshold: TimeInterval) -> String {
        String(format: "hang.detected elapsed=%.2fs threshold=%.0fs", elapsed, threshold)
    }

    /// `"hang.recovered downtime=1234.56s"`
    static func formatHangRecovered(downtime: TimeInterval) -> String {
        String(format: "hang.recovered downtime=%.2fs", downtime)
    }

    // Hoisted out of `formatStackTruncated` so the Set isn't rebuilt on every call.
    // 4-entry literal so cost is trivial, but `static let` matches the file's other
    // module-level `static let logger / state / thresholdSeconds` convention
    // (per gate 1b Lb).
    private static let noiseFilter: Set<String> = [
        "_dispatch_main_queue_drain",
        "_dispatch_root_queue_drain",
        "_dispatch_source_latch_and_call",
        "__libdispatch_source_mgr_invoke"
    ]

    /// L-4 (2026-07-25 audit): pre-compile the noise filter into one regex so
    /// each frame is searched once instead of once per noise symbol.
    /// Patterns are escaped so dispatch symbol underscores/dots stay literal.
    private static let noiseFilterRegex: NSRegularExpression = {
        let pattern = noiseFilter
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Returns the first 20 frames of `stack` joined with `\n`, with `"(empty)"` for
    /// empty/no-usable input and a `"...(truncated N more)"` marker if there are more
    /// than 20 frames. Filters known dispatch noise so the surviving frames are useful
    /// for diagnosis (per spec §6.1 + reviewer #8 LOW #18).
    ///
    /// Note (gate 1b Ld): `stack = []` and `stack = [全是 noise 帧]` both produce
    /// `"(empty)"`. Semantically distinct inputs collapse to the same output —
    /// intentional (we don't have useful frames in either case).
    static func formatStackTruncated(stack: [String]) -> String {
        // Substring match: real `Thread.callStackSymbols` returns frames like
        // "0   libdispatch.dylib  0x... _dispatch_main_queue_drain + 16" with index +
        // module + address + offset, so bare-symbol whole-string match never matches
        // production frames. Per gate 1b post-review fix.
        let filtered = stack.filter { frame in
            let range = NSRange(frame.startIndex..., in: frame)
            return noiseFilterRegex.firstMatch(in: frame, options: [], range: range) == nil
        }
        if filtered.isEmpty {
            return "(empty)"
        }
        let preview = filtered.prefix(20)
        if filtered.count <= 20 {
            return preview.joined(separator: "\n")
        }
        let dropped = filtered.count - 20
        return preview.joined(separator: "\n") + "\n...(truncated \(dropped) more)"
    }

    // MARK: - Test helpers (per spec §6.5 + plan add-ons; underscore-prefixed to discourage production use)

    // swiftlint:disable identifier_name large_tuple
    // Test helper names start with `_` (convention to discourage production use)
    // and `_snapshotStateForTesting` returns a 5-tuple for atomic snapshot reads.
    // Brief §6.5 mandates these exact signatures.

    /// Test-only. Resets state to fresh State(lastHeartbeat: Date(), others empty),
    /// cancels all 3 timers, and sets isStarted = false.
    /// Note: uses **explicit State construction** (not `.initial`) to avoid
    /// `static let` lazy single-eval freezing `lastHeartbeat` across test cases.
    /// MUST be called in setUp. MUST NOT be called concurrently with start() / stop().
    internal static func _resetForTesting() {
        withStateLock { $0 = State(lastHeartbeat: Date(), lastMainStack: [], lastDetectedAt: nil, firstDetectedAt: nil, detectionCount: 0) }
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        stackTimer?.cancel();     stackTimer = nil
        checkerTimer?.cancel();   checkerTimer = nil
        isStarted = false
    }

    /// Test-only. Read-only snapshot of the five state fields the test suite asserts on.
    /// (5th field `lastMainStack` added per gate 1b H2 so `testRecordStackCapture_capturesNonEmptyStack`
    /// can actually read what it writes — pre-fix the test was named for stack non-emptiness but only
    /// asserted detection metadata.)
    internal static func _snapshotStateForTesting() -> (
        lastHeartbeat: Date,
        lastDetectedAt: Date?,
        firstDetectedAt: Date?,
        detectionCount: Int,
        lastMainStack: [String]
    ) {
        withStateLock { s in
            (s.lastHeartbeat, s.lastDetectedAt, s.firstDetectedAt, s.detectionCount, s.lastMainStack)
        }
    }

    /// Test-only. Seed `lastHeartbeat` to a fixed instant for staleness tests.
    internal static func _seedLastHeartbeatForTesting(_ date: Date) {
        withStateLock { $0.lastHeartbeat = date }
    }

    /// Test-only. Exposes `isStarted` so the ID-LIFE-0022 regression test can
    /// assert stop() re-arms the watchdog for a later start().
    internal static var _isStartedForTesting: Bool { isStarted }
    // swiftlint:enable identifier_name large_tuple

    // MARK: - Mutation API: heartbeat (spec §4.2 / §4.3)

    /// Refresh `state.lastHeartbeat` to the current `Date()`.
    /// Invoked by the heartbeat timer (main queue, 1s).
    static func recordHeartbeat() {
        withStateLock { $0.lastHeartbeat = Date() }
    }

    // MARK: - Mutation API: staleness check (spec §4.2 / §4.3 / §7)

    /// If the gap between `now` and `state.lastHeartbeat` exceeds
    /// `thresholdSeconds`, emit a detection log (error) and update state.
    /// Otherwise no-op. Idempotent across calls; periodic checker calls
    /// from `.global(.utility)` queue are independent of main thread.
    ///
    /// Implementation uses a single `withLock` per call (per MEDIUM #8):
    /// snapshot only the values needed for decision outside the lock,
    /// then re-enter the lock briefly to mutate state (Task 3 introduces
    /// the cap-at-5 + firstDetectedAt-once writes).
    static func checkStaleness(now: Date) {
        // swiftlint:disable:next large_tuple
        let snapshot = withStateLock { s -> (elapsed: TimeInterval, count: Int, firstDetectedAt: Date?, stack: [String]) in
            (now.timeIntervalSince(s.lastHeartbeat), s.detectionCount, s.firstDetectedAt, s.lastMainStack)
        }
        guard snapshot.elapsed >= thresholdSeconds, snapshot.count < maxDetectionCount else {
            return
        }
        // Emit logs outside the lock (per MEDIUM #8 — logger calls must never hold the lock).
        logHangDetected(elapsed: snapshot.elapsed, threshold: thresholdSeconds, count: snapshot.count + 1)
        logStackTruncated(stack: snapshot.stack)
        logHangMainStackFull(stack: snapshot.stack)
        // Mutate state inside the lock + re-check cap (per spec §4.2 single-lock
        // pattern + gate 1b H1): the inner cap guard prevents a concurrent
        // stack-timer recovery between the outer snapshot read (L174) and this
        // re-entry from resetting detectionCount to 0 and then us blindly
        // overwriting firstDetectedAt / pushing detectionCount back to 1.
        //
        // Note: the cap re-check ONLY guards the state write above. The three
        // `logger.error(...)` calls at L181-183 already ran with the outer-snapshot
        // count; a recovery landing in the snapshot→re-entry slice produces ≤1
        // spurious `hang.detected` log at the recovery moment. Self-heals within
        // ≤5s on the next stack-timer fire (which re-emits `hang.recovered` for
        // the freshly-cleared state).
        withStateLock { s in
            guard s.detectionCount < maxDetectionCount else { return }
            s.lastDetectedAt = now
            s.firstDetectedAt = s.firstDetectedAt ?? now
            s.detectionCount += 1
        }
    }

    // MARK: - Mutation API: stack capture + recovery (spec §4.2 + §7)

    /// Captures `Thread.callStackSymbols` (this thread is the main queue per
    /// the timer setup in `start()`, so the captured frames belong to main) —
    /// but ONLY when a hang is suspected (INFRA-2 gating, see inline note):
    /// with a fresh heartbeat and no active detection this returns early
    /// without walking the stack.
    ///
    /// ID-LIFE-0024 (2026-07-31 audit, accepted as-is): because this timer
    /// lives on the main queue, it CANNOT fire while the main thread is
    /// actually blocked — the frames captured here are always the
    /// recovery-moment stack (often pure dispatch noise), never the in-hang
    /// stack. Value is a coarse "a hang happened around here" reference
    /// signal only; see the file-header note for the full rationale.
    ///
    /// Empty-stack rule (reviewer #3, spec §4.2): if the captured stack is
    /// empty, do NOT overwrite `lastMainStack` — preserve the previously-captured
    /// (pre-hang) frames so the diagnostic value survives.
    ///
    /// Recovery detection (spec §4.2 / MEDIUM #7 — recovery is owned by the
    /// stack timer, not the heartbeat): if the snapshot shows a prior
    /// detection (`firstDetectedAt != nil`), compute `downtime = now - firstDetectedAt`,
    /// emit `logger.info("hang.recovered downtime=...")`, and clear
    /// `lastDetectedAt` / `firstDetectedAt` / `detectionCount` in a single
    /// locked write. Recovery still runs under the gate: an active detection
    /// always satisfies the capture condition.
    static func recordStackCaptureAndMaybeRecover() {
        let now = Date()
        // INFRA-2 (2026-07-24 audit): gate the capture. The L-8 comment below
        // claimed the 50-200 ms `Thread.callStackSymbols` cost "only runs when
        // a hang is in progress, not every 5 s on a healthy machine" — false:
        // the capture ran unconditionally on every 5 s tick, so the watchdog
        // itself was a source of periodic main-thread jank. Now the stack is
        // walked only when a hang is suspected: either the checker already
        // flagged one (firstDetectedAt != nil) or the heartbeat is stale past
        // the threshold (checker hasn't fired yet — capture BEFORE the first
        // detection is exactly the frames we want for post-mortem diagnosis).
        // When healthy there is nothing to recover (firstDetectedAt == nil
        // implies the recovery block below is a no-op), so we return early.
        let hangSuspected = withStateLock { s in
            s.firstDetectedAt != nil || now.timeIntervalSince(s.lastHeartbeat) >= thresholdSeconds
        }
        guard hangSuspected else { return }
        // L-8 (2026-07-24 audit) was a `DispatchQueue.global.async` capture
        // to avoid the 50-200 ms `Thread.callStackSymbols` cost. Post-audit
        // scan caught the regression: `Thread.callStackSymbols` reports the
        // CURRENT thread's symbols — dispatching it to a utility queue
        // records the utility thread's stack, not the captured main stack.
        // The watchdog's diagnostic value vanished. Reverted to sync
        // capture on main. The 50-200 ms cost is acceptable because INFRA-2
        // (above) gates it: it only runs while a hang is suspected, not
        // every 5 s on a healthy machine, and it runs on the watchdog's own
        // timer, separate from UI renders.
        let newStack = Thread.callStackSymbols
        // Empty-stack rule (spec §4.2 reviewer #3): if `newStack` is empty, leave
        // `lastMainStack` untouched (preserve pre-hang frames for diagnosis).
        // Breadcrumb emitted OUTSIDE any lock per MEDIUM #8 (gate 1b Md: this debug
        // log is the spec-mandated trail for "why didn't we get a fresh stack" debugging).
        if newStack.isEmpty {
            logger.debug("hang.stack_capture empty=\(true, privacy: .public)")
        }
        // Per gate 1b Mc: collapse the original 3 separate `withLock` calls (snapshot +
        // stack-write + recovery-clear) into a single post-snapshot lock so stack-write
        // and recovery-clear are atomic relative to a concurrent checker read.
        let recoveryDowntime: TimeInterval? = withStateLock { s -> TimeInterval? in
            if !newStack.isEmpty {
                s.lastMainStack = newStack
            }
            if let first = s.firstDetectedAt {
                let downtime = now.timeIntervalSince(first)
                s.lastDetectedAt = nil
                s.firstDetectedAt = nil
                s.detectionCount = 0
                return downtime
            }
            return nil
        }
        // Recovery log OUTSIDE lock (per MEDIUM #8).
        if let downtime = recoveryDowntime {
            logHangRecovered(downtime: downtime)
        }
    }

    // MARK: - Detection log wrappers (per spec §7 + reviewer #4 privacy syntax)

    /// `logger.error("hang.detected elapsed=Xs threshold=Ys detection_count=N")`.
    private static func logHangDetected(elapsed: TimeInterval, threshold: TimeInterval, count: Int) {
        logger.error("\(formatHangDetected(elapsed: elapsed, threshold: threshold), privacy: .public) detection_count=\(count, privacy: .public)")
    }

    /// `logger.error("hang.main_stack lines=N first_line=...")` — single-line preview.
    private static func logStackTruncated(stack: [String]) {
        let preview = formatStackTruncated(stack: stack)
        let firstLine = preview.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "(empty)"
        logger.error("hang.main_stack lines=\(stack.count, privacy: .public) first_line=\(firstLine, privacy: .public)")
    }

    /// `logger.error("hang.main_stack_full\n<full stack>")` — multi-line; each newline emits its own log entry under os.Logger.
    private static func logHangMainStackFull(stack: [String]) {
        let body = stack.isEmpty ? "(empty)" : stack.joined(separator: "\n")
        logger.error("hang.main_stack_full\n\(body, privacy: .public)")
    }

    /// `logger.info("hang.recovered downtime=Xs")`.
    /// Uses `firstDetectedAt` (not `lastDetectedAt`) so the downtime
    /// reflects the true hang duration (first detection → recovery),
    /// not just (last detection → recovery) which would understate it.
    private static func logHangRecovered(downtime: TimeInterval) {
        logger.info("\(formatHangRecovered(downtime: downtime), privacy: .public)")
    }

    // MARK: - Lifecycle (spec §10.1 / §10.2)

    /// Start all 3 timers. Re-entry guarded via `isStarted`. Idempotent:
    /// a second `start()` while already started is a no-op.
    ///
    /// Order matters (per spec §4.1 LOW #17 — handler MUST be bound before resume):
    /// `makeTimerSource` → `schedule` → `setEventHandler` → `resume`.
    ///
    /// Capture warning (per CRITICAL reviewer #7 in spec §4.1): the timer
    /// closures MUST NOT capture `hb`/`st`/`ch` in a `[weak ...]` form —
    /// when the closure runs in the timer's queue, the local var has
    /// already gone out of scope (start() returned). Call the static
    /// entry point directly instead.
    static func start() {
        guard !isStarted else { return }
        // L-9 (2026-07-24 audit): previous design set `isStarted = true` at the very
        // end of `start()`, AFTER all 3 timer `resume()` calls. The narrow
        // window between the first `resume()` and the final assignment allowed
        // a re-entrant call (e.g. a concurrent `recordHeartbeat()` triggered by
        // a 1-second tick that landed before `start()` returned) to read
        // `isStarted == false`. Setting the flag immediately after the re-entry
        // guard closes the window. `stop()` still unconditionally resets it,
        // so the cycle invariant — `isStarted == true` ⇔ `start()` ran without
        // a matching `stop()` — is preserved.
        isStarted = true
        // INFRA-4 (2026-07-24 review): do NOT assign `.initial` here — it is a
        // `static let` whose `lastHeartbeat: Date()` is evaluated once at
        // first access and frozen. If anything touched `.initial` before
        // start(), the heartbeat baseline would be a stale timestamp and the
        // checker could immediately false-report a hang. Construct a fresh
        // State instead (same pattern as `_resetForTesting`).
        withStateLock { $0 = State(lastHeartbeat: Date(), lastMainStack: [], lastDetectedAt: nil, firstDetectedAt: nil, detectionCount: 0) }

        let mainQueue = DispatchQueue.main
        let utilityQueue = DispatchQueue.global(qos: .utility)

        // Heartbeat: main, 1s — `recordHeartbeat()`
        let hb = DispatchSource.makeTimerSource(queue: mainQueue)
        hb.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        hb.setEventHandler {
            HangDetector.recordHeartbeat()
        }
        hb.resume()
        heartbeatTimer = hb

        // Stack capture + recovery: main, 5s — `recordStackCaptureAndMaybeRecover()`
        let st = DispatchSource.makeTimerSource(queue: mainQueue)
        st.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        st.setEventHandler {
            HangDetector.recordStackCaptureAndMaybeRecover()
        }
        st.resume()
        stackTimer = st

        // Checker: .utility, 30s — `checkStaleness(now:)` reading snapshot for stale detection
        let ch = DispatchSource.makeTimerSource(queue: utilityQueue)
        ch.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(1))
        ch.setEventHandler {
            HangDetector.checkStaleness(now: Date())
        }
        ch.resume()
        checkerTimer = ch

        // L-9 fix already set `isStarted = true` immediately after the
        // re-entry guard at the top of start(); no need to set again here.
        // (Original code had a duplicate assignment to close a tiny race
        // window; L-9 closed it earlier in the function and stop() still
        // unconditionally clears the flag in its terminator.)
    }

    /// Cancel all 3 timers in reverse-start order. Idempotent: no-op if
    /// `start()` wasn't called (the timer fields are nil). Does NOT reset
    /// `state`. ID-LIFE-0022 (2026-07-31 audit): now DOES clear `isStarted`
    /// — the original §10.2 "故意的不对称" (stop() leaves isStarted true)
    /// made a stopped watchdog impossible to restart: a later `start()`
    /// exited at the re-entry guard and the watchdog stayed permanently
    /// dead (test teardown/restart, delegate replacement, future runtime
    /// watchdog toggle).
    static func stop() {
        checkerTimer?.cancel();   checkerTimer = nil
        stackTimer?.cancel();     stackTimer = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        isStarted = false
    }
}
