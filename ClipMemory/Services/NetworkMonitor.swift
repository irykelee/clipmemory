import Foundation
import Network
import os.log

/// ID-STORE-0018 (MEDIUM-6 audit fix, 2026-08-15): network reachability
/// observer. Wraps `NWPathMonitor` and posts a notification on every
/// offline → online transition so the app can drain queued writes that
/// piled up while offline.
///
/// Per the audit: the ClipMemory auto-save retry path uses a fixed
/// exponential-backoff timer (H-1 fix, commit `f4a6e72`). When offline
/// for an extended period the timer keeps firing but the save keeps
/// failing; once back online, the next save is only triggered by either
/// (a) the next user copy or (b) the backoff timer eventually expiring
/// at 16 s × 16 = 256 s. If the user walks away for 30 min offline,
/// the queue sits idle for the entire window. NWPathMonitor gives us a
/// tighter signal: as soon as the OS reports `.satisfied`, we force-flush.
///
/// Singleton because (a) only the system-wide path matters, not
/// per-component, and (b) we need the monitor alive for the entire app
/// lifetime (not per-view-controller), so sharing one instance avoids
/// `NWPathMonitor` reference-count churn on every deinit.
///
/// ID-STORE-0021 (audit MEDIUM-14 foundation, 2026-08-16): explicit
/// `@unchecked Sendable` rationale for the Swift 6 migration plan
/// (`docs/SWIFT6_MIGRATION.md` §4 per-module table). Mutable state
/// (`lastSatisfied`, `hasReceivedInitialUpdate`) is protected by
/// `stateLock` (line 49, NSLock) — read/written only inside
/// `handlePathUpdate` (91-96), `stop` (72-75), `resetForTesting`
/// (83-86). `start()` is lock-free: it only wires
/// `monitor.pathUpdateHandler` and calls `monitor.start(queue:)`,
/// never touching the protected pair (init defaults `false`/`false`
/// suffice). Single call site: `AppDelegate.swift:107`, main
/// thread, `applicationDidFinishLaunching`, called once — not
/// restartable. `@unchecked Sendable` is therefore sound: the
/// state pair is atomic via the lock, and `start()` has no
/// ordering constraints that require lock protection.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    /// Posted whenever `NWPathMonitor` reports a transition from
    /// unsatisfied → satisfied. `userInfo` is empty (post itself is the
    /// signal). Observers should NOT expect every-online-event to fire
    /// — the monitor starts in the current state and only emits CHANGES.
    /// If the app launches while already online, no notification fires
    /// until the user goes offline and back online.
    static let didBecomeReachable = Notification.Name("NetworkMonitor.didBecomeReachable")

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(
        label: "com.clipmemory.networkmonitor",
        qos: .utility
    )
    private let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "NetworkMonitor"
    )

    /// Tracks the last-reported state so the `.satisfied` handler can
    /// distinguish "still online" (don't re-post) from "just came back
    /// online" (post the notification). NWPathMonitor delivers an initial
    /// update with the current state; we record it but only fire the
    /// notification on a false → true transition.
    private let stateLock = NSLock()
    private var lastSatisfied: Bool = false
    private var hasReceivedInitialUpdate = false

    private init() {
        self.monitor = NWPathMonitor()
    }

    /// ID-STORE-0018: start the path monitor. Safe to call multiple
    /// times; the monitor handler is a no-op if already started.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: monitorQueue)
        logger.info("ID-STORE-0018: NetworkMonitor started")
    }

    /// ID-STORE-0018: stop the path monitor. The app holds this singleton
    /// for its entire lifetime, so this is only called from tests that
    /// need a clean slate or from future teardown paths.
    func stop() {
        monitor.cancel()
        stateLock.lock()
        lastSatisfied = false
        hasReceivedInitialUpdate = false
        stateLock.unlock()
    }

    /// ID-STORE-0018: test seam — reset the singleton's internal state
    /// without tearing down the underlying `NWPathMonitor` (which would
    /// require waiting for the dispatch queue to drain). Paired with
    /// `start()` to give tests a clean baseline.
    func resetForTesting() {
        stateLock.lock()
        lastSatisfied = false
        hasReceivedInitialUpdate = false
        stateLock.unlock()
    }

    private func handlePathUpdate(_ path: NWPath) {
        let nowSatisfied = (path.status == .satisfied)
        stateLock.lock()
        let wasSatisfied = lastSatisfied
        let isInitial = !hasReceivedInitialUpdate
        lastSatisfied = nowSatisfied
        hasReceivedInitialUpdate = true
        stateLock.unlock()

        // ID-STORE-0018: emit only on offline → online transitions. The
        // first update after launch is recorded as the baseline (isInitial)
        // and does NOT fire — we don't want a flush-on-launch just because
        // the user happened to launch while online.
        guard !isInitial else {
            logger.info("ID-STORE-0018: initial path status: \(String(describing: path.status))")
            return
        }
        guard !wasSatisfied, nowSatisfied else {
            // Either still online (no transition) or went offline (don't
            // need to flush; the next save retry will hit the now-broken
            // backoff). Logging at debug only to avoid noise.
            return
        }

        logger.info("ID-STORE-0018: network became reachable — posting didBecomeReachable")
        NotificationCenter.default.post(
            name: Self.didBecomeReachable,
            object: self
        )
    }
}