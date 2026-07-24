import XCTest
@testable import ClipMemory

/// INFRA-2 (2026-07-24 audit): HangDetector's 5-second stack timer used to
/// call `Thread.callStackSymbols` unconditionally — a 50-200 ms main-thread
/// cost on every tick, so the hang watchdog itself produced periodic jank on
/// perfectly healthy machines. The L-8 comment even claimed the cost "only
/// runs when a hang is in progress" while the code captured every 5 s.
///
/// The fix gates the capture: the stack is walked only when a hang is
/// suspected — an active detection (`firstDetectedAt != nil`) or a heartbeat
/// stale past `thresholdSeconds` (checker hasn't fired yet; those pre-
/// detection frames are the most diagnostically valuable). Healthy ticks
/// return early.
///
/// These tests pin the gate contract:
/// - healthy heartbeat → NO capture (the regression: lastMainStack must
///   stay empty)
/// - stale heartbeat (>= threshold) → capture runs
/// - active detection → capture + recovery still run even with a fresh
///   heartbeat (the gate must not break recovery, which is owned by this
///   timer per spec §4.2 / MEDIUM #7)
final class HangDetectorCaptureGatingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HangDetector._resetForTesting()
    }

    // MARK: - The regression: healthy machines must not pay the capture cost

    /// Fresh heartbeat + no detection → early return, lastMainStack untouched.
    /// Pre-fix this populated lastMainStack on every call — i.e. every 5 s in
    /// production.
    func testRecordStackCapture_healthyHeartbeat_doesNotCapture() {
        HangDetector.recordHeartbeat()  // explicitly fresh
        HangDetector.recordStackCaptureAndMaybeRecover()
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertTrue(s.lastMainStack.isEmpty,
                      "healthy heartbeat must skip the callStackSymbols capture (INFRA-2)")
        XCTAssertNil(s.lastDetectedAt)
        XCTAssertNil(s.firstDetectedAt)
        XCTAssertEqual(s.detectionCount, 0)
    }

    /// Just below the threshold the gate must stay closed. Uses a generous
    /// 5 s margin below the 60 s threshold so timer scheduling jitter on a
    /// loaded CI machine can't flip the result.
    func testRecordStackCapture_justBelowThreshold_doesNotCapture() {
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(
            now.addingTimeInterval(-(HangDetector.thresholdSeconds - 5)))
        HangDetector.recordStackCaptureAndMaybeRecover()
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertTrue(s.lastMainStack.isEmpty,
                      "heartbeat fresher than threshold must skip capture (INFRA-2)")
    }

    // MARK: - Suspected hang: capture must run

    /// Heartbeat stale past the threshold → the gate opens even before the
    /// 30 s checker fires, so the pre-detection frames (the ones that matter
    /// for post-mortem diagnosis) are captured.
    func testRecordStackCapture_staleHeartbeat_captures() {
        HangDetector._seedLastHeartbeatForTesting(
            Date().addingTimeInterval(-(HangDetector.thresholdSeconds + 10)))
        HangDetector.recordStackCaptureAndMaybeRecover()
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertFalse(s.lastMainStack.isEmpty,
                       "stale heartbeat past threshold must trigger capture (INFRA-2)")
    }

    /// Boundary: exactly at the threshold the gate must open (`>=`, matching
    /// checkStaleness's trigger semantics per spec §6.2 reviewer #2).
    func testRecordStackCapture_exactlyAtThreshold_captures() {
        HangDetector._seedLastHeartbeatForTesting(
            Date().addingTimeInterval(-HangDetector.thresholdSeconds))
        HangDetector.recordStackCaptureAndMaybeRecover()
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertFalse(s.lastMainStack.isEmpty,
                       "heartbeat exactly at threshold must trigger capture (>= semantics)")
    }

    // MARK: - The gate must not break recovery

    /// Recovery is owned by the stack timer: with an active detection the
    /// gate stays open even if the heartbeat just recovered, so the capture
    /// runs AND the detection state is cleared.
    func testRecordStackCapture_activeDetection_capturesAndRecoversDespiteFreshHeartbeat() {
        // Seed a detection.
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(now.addingTimeInterval(-70))
        HangDetector.checkStaleness(now: now)
        XCTAssertEqual(HangDetector._snapshotStateForTesting().detectionCount, 1)

        // Heartbeat recovers (main thread alive again) BEFORE the stack timer fires.
        HangDetector.recordHeartbeat()
        HangDetector.recordStackCaptureAndMaybeRecover()

        let s = HangDetector._snapshotStateForTesting()
        XCTAssertFalse(s.lastMainStack.isEmpty,
                       "active detection must keep the capture gate open (INFRA-2)")
        XCTAssertNil(s.lastDetectedAt, "recovery must clear lastDetectedAt")
        XCTAssertNil(s.firstDetectedAt, "recovery must clear firstDetectedAt")
        XCTAssertEqual(s.detectionCount, 0, "recovery must reset detectionCount")
    }

    /// A healthy tick must not manufacture a recovery either: with no prior
    /// detection there is nothing to clear and no state may change.
    func testRecordStackCapture_healthyHeartbeat_doesNotClearOrFabricateState() {
        HangDetector.recordHeartbeat()
        HangDetector.recordStackCaptureAndMaybeRecover()
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertNil(s.lastDetectedAt)
        XCTAssertNil(s.firstDetectedAt)
        XCTAssertEqual(s.detectionCount, 0)
    }
}
