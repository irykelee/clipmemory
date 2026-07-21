import Foundation
import os.log

/// ABC §C observability: watchdog that detects main-thread hangs >60s and
/// logs `Thread.callStackSymbols` to surface post-mortem root cause for
/// bugs like 2026-07-19 21:35 "sidebar OK but main empty".
///
/// Architecture (3 timers, per spec §4.1):
/// - heartbeat (main, 1s) — refreshes `state.lastHeartbeat`
/// - stack (main, 5s)     — captures `Thread.callStackSymbols`; checks recovery
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

        static let initial = State(
            lastHeartbeat: Date(),
            lastMainStack: [],
            lastDetectedAt: nil,
            firstDetectedAt: nil,
            detectionCount: 0
        )
    }

    private static let state = OSAllocatedUnfairLock<State>(initialState: .initial)
    // 3 timer refs split as individual optionals (avoids Large-Tuple lint rule)
    private static var heartbeatTimer: DispatchSourceTimer?
    private static var stackTimer: DispatchSourceTimer?
    private static var checkerTimer: DispatchSourceTimer?
    // main-thread only; set at end of `start()` after all 3 timer `resume()` calls
    // (per spec §10.2 + gate 1b Ma — avoids permanent no-op if a future API throws mid-setup,
    // since `stop()` per §10.2 deliberately does NOT reset isStarted).
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
            !noiseFilter.contains { noise in frame.contains(noise) }
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
        state.withLock { $0 = State(lastHeartbeat: Date(), lastMainStack: [], lastDetectedAt: nil, firstDetectedAt: nil, detectionCount: 0) }
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
        state.withLock { s in
            (s.lastHeartbeat, s.lastDetectedAt, s.firstDetectedAt, s.detectionCount, s.lastMainStack)
        }
    }

    /// Test-only. Seed `lastHeartbeat` to a fixed instant for staleness tests.
    internal static func _seedLastHeartbeatForTesting(_ date: Date) {
        state.withLock { $0.lastHeartbeat = date }
    }
    // swiftlint:enable identifier_name large_tuple

    // MARK: - Mutation API: heartbeat (spec §4.2 / §4.3)

    /// Refresh `state.lastHeartbeat` to the current `Date()`.
    /// Invoked by the heartbeat timer (main queue, 1s).
    static func recordHeartbeat() {
        state.withLock { $0.lastHeartbeat = Date() }
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
        let snapshot = state.withLock { s -> (elapsed: TimeInterval, count: Int, firstDetectedAt: Date?, stack: [String]) in
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
        state.withLock { s in
            guard s.detectionCount < maxDetectionCount else { return }
            s.lastDetectedAt = now
            s.firstDetectedAt = s.firstDetectedAt ?? now
            s.detectionCount += 1
        }
    }

    // MARK: - Mutation API: stack capture + recovery (spec §4.2 + §7)

    /// Captures `Thread.callStackSymbols` (this thread is the main queue per
    /// the timer setup in `start()`, so the captured frames belong to main).
    /// Empty-stack rule (reviewer #3, spec §4.2): if the captured stack is
    /// empty, do NOT overwrite `lastMainStack` — preserve the previously-captured
    /// (pre-hang) frames so the diagnostic value survives.
    ///
    /// Recovery detection (spec §4.2 / MEDIUM #7 — recovery is owned by the
    /// stack timer, not the heartbeat): if the snapshot shows a prior
    /// detection (`firstDetectedAt != nil`), compute `downtime = now - firstDetectedAt`,
    /// emit `logger.info("hang.recovered downtime=...")`, and clear
    /// `lastDetectedAt` / `firstDetectedAt` / `detectionCount` in a single
    /// locked write.
    static func recordStackCaptureAndMaybeRecover() {
        let now = Date()
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
        let recoveryDowntime: TimeInterval? = state.withLock { s -> TimeInterval? in
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
        state.withLock { $0 = .initial }
        // NOTE: `isStarted = true` is set at the END of this function (after all 3 timer
        // resume() calls), per gate 1b Ma — see the final line of `start()`.

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

        // Per gate 1b Ma: set `isStarted = true` AFTER all 3 timer `resume()` calls (and
        // their timer field assignments) so any exception / future-throwing API call
        // in the timer-setup path leaves `start()` re-callable. `stop()` per spec §10.2
        // deliberately does NOT clear `isStarted`, so a failure mid-setup before this line
        // would otherwise make the watchdog permanently inert for the rest of the process.
        isStarted = true
    }

    /// Cancel all 3 timers in reverse-start order. Idempotent: no-op if
    /// `start()` wasn't called (the timer fields are nil). Does NOT reset
    /// `state` and does NOT clear `isStarted` — process lifetime is one
    /// start + one stop (terminate) per spec §10.2 "故意的不对称".
    static func stop() {
        checkerTimer?.cancel();   checkerTimer = nil
        stackTimer?.cancel();     stackTimer = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
    }
}
