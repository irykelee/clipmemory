import Foundation

/// P1-AUDIT-2026-09-22 (P1-7): state machine of `NetworkMonitor` was
/// untestable because the production class held `NWPathMonitor` directly
/// and could not be swapped. Per the audit, the existing 4 tests
/// asserted singleton identity / constant values / reset idempotency
/// only — the actual path state transitions had no coverage.
///
/// P1-AUDIT-2026-09-22 (P1-7 follow-up): the original protocol draft
/// exposed `path: NWPath?`, but the Network framework's `NWPath` has
/// no public initializer on macOS (verified against
/// `Network.framework/.../Network.swiftmodule/.../macos.swiftinterface`
/// — `NWPath` exposes only `let` properties and `static func ==`),
/// so a mock cannot construct a synthetic `NWPath` to drive state.
/// Per the audit's documented fallback (brief Step 1.2 note), the
/// protocol exposes only the boolean convenience. Production callers
/// that need the full `NWPath` can downcast to the concrete
/// `NetworkMonitor` type or read the underlying `NWPathMonitor`'s
/// `currentPath` directly.
protocol NetworkMonitorProtocol: AnyObject {
    /// Convenience: true if the last observed path was satisfied.
    /// Mirrors `NWPath.status == .satisfied` from the real monitor.
    var isConnected: Bool { get }

    /// Start monitoring. Idempotent (calling `start()` twice is a no-op).
    func start()

    /// Stop monitoring. Idempotent (calling `stop()` after `stop()` is a no-op).
    func stop()

    /// Reset to initial state — primarily for tests.
    func reset()
}