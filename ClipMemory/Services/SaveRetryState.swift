import Foundation

/// H-1 (2026-08-08 audit): exponential-backoff state for save retries.
///
/// The pre-fix `flushSave()` catch block restored `needsSave = true` and
/// posted a notification, but never rescheduled `saveTimer` — so a save
/// failure would only be retried when the next user mutation happened to
/// trigger `saveImmediately()`. In the common case (user copies once and
/// walks away) the failure was permanent for the session.
///
/// This struct drives an autonomous retry with exponential backoff:
/// 500ms → 1s → 2s → 4s → 8s → 16s, then capped. Pure decision logic,
/// no DispatchSourceTimer coupling, so the ladder is unit-testable
/// without time control.
///
/// On success the counter resets to 0 so a recovered-then-broken-again
/// disk walks the ladder from the bottom again — not from the cap value.
struct SaveRetryState: Equatable {
    private(set) var consecutiveFailures: Int = 0
    let baseBackoff: TimeInterval
    let maxBackoff: TimeInterval

    init(baseBackoff: TimeInterval = 0.5, maxBackoff: TimeInterval = 16.0) {
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    /// Next backoff in seconds: `baseBackoff * 2^(n-1)` capped at `maxBackoff`.
    /// n=1: 0.5s, n=2: 1.0s, n=3: 2.0s, n=4: 4.0s, n=5: 8.0s, n≥6: maxBackoff.
    var nextBackoffSeconds: TimeInterval {
        guard consecutiveFailures > 0 else { return baseBackoff }
        // 2^(n-1) but bounded so we never overflow Int or blow past the cap
        // before the min(...) check. With baseBackoff=0.5 and maxBackoff=16,
        // the multiplier cap of 32 = 16/0.5 lands exactly at maxBackoff.
        let rawMultiplier = min(Double(1 << min(consecutiveFailures - 1, 30)), maxBackoff / baseBackoff)
        return min(baseBackoff * rawMultiplier, maxBackoff)
    }
}