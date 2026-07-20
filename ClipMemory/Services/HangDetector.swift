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
    private static var timers: (
        heartbeat: DispatchSourceTimer?,
        stack: DispatchSourceTimer?,
        checker: DispatchSourceTimer?
    ) = (nil, nil, nil)
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
        "__libdispatch_source_mgr_invoke",
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
        timers.heartbeat?.cancel(); timers.heartbeat = nil
        timers.stack?.cancel();     timers.stack = nil
        timers.checker?.cancel();   timers.checker = nil
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
}
