import XCTest
@testable import ClipMemory

/// Spec §6.1 (formatter tests) + §6.2 (state tests).
/// State tests use `_resetForTesting()` in setUp to avoid timer tuple
/// residue leaking between cases (spec §6.4 + §6.3 HIGH #6).
final class HangDetectorTests: XCTestCase {

    // MARK: - §6.1 Pure formatter tests (8 cases)

    func testFormatHangDetected_zeroElapsed() {
        XCTAssertEqual(
            HangDetector.formatHangDetected(elapsed: 0, threshold: 60),
            "hang.detected elapsed=0.00s threshold=60s"
        )
    }

    func testFormatHangDetected_longElapsed() {
        XCTAssertEqual(
            HangDetector.formatHangDetected(elapsed: 72.34, threshold: 60),
            "hang.detected elapsed=72.34s threshold=60s"
        )
    }

    func testFormatHangRecovered_zeroDowntime() {
        XCTAssertEqual(
            HangDetector.formatHangRecovered(downtime: 0),
            "hang.recovered downtime=0.00s"
        )
    }

    func testFormatHangRecovered_longDowntime() {
        XCTAssertEqual(
            HangDetector.formatHangRecovered(downtime: 1234.56),
            "hang.recovered downtime=1234.56s"
        )
    }

    func testFormatStackTruncated_short_emitsAllFrames() {
        let stack = ["frame_a", "frame_b", "frame_c"]
        XCTAssertEqual(
            HangDetector.formatStackTruncated(stack: stack),
            "frame_a\nframe_b\nframe_c"
        )
    }

    func testFormatStackTruncated_long_truncatesAt20() {
        let stack = (0..<50).map { "frame_\($0)" }
        let result = HangDetector.formatStackTruncated(stack: stack)
        // First 20 frames present, last preview frame is frame_19.
        XCTAssertTrue(result.contains("frame_19"), "preview should include frame_19; got:\n\(result)")
        // Truncation marker reports the 30 dropped frames.
        XCTAssertTrue(result.contains("...(truncated 30 more)"), "missing truncation marker; got:\n\(result)")
        // frame_49 would only appear if non-truncated.
        XCTAssertFalse(result.contains("frame_49"), "frame_49 should have been truncated; got:\n\(result)")
    }

    func testFormatStackTruncated_empty() {
        XCTAssertEqual(
            HangDetector.formatStackTruncated(stack: []),
            "(empty)"
        )
    }

    func testFormatStackTruncated_filtersDispatchNoise() {
        let stack = [
            "AppDelegate.applicationDidFinishLaunching",
            "_dispatch_main_queue_drain",
            "ContentView.refreshDisplayedItemsCacheSoon",
            "_dispatch_root_queue_drain",
            "HangDetector.recordHeartbeat",
            "_dispatch_source_latch_and_call",
            "__libdispatch_source_mgr_invoke",
        ]
        let result = HangDetector.formatStackTruncated(stack: stack)
        // App frames must remain.
        XCTAssertTrue(result.contains("AppDelegate.applicationDidFinishLaunching"))
        XCTAssertTrue(result.contains("ContentView.refreshDisplayedItemsCacheSoon"))
        XCTAssertTrue(result.contains("HangDetector.recordHeartbeat"))
        // All four dispatch noise patterns must be filtered out.
        for noise in [
            "_dispatch_main_queue_drain",
            "_dispatch_root_queue_drain",
            "_dispatch_source_latch_and_call",
            "__libdispatch_source_mgr_invoke"
        ] {
            XCTAssertFalse(result.contains(noise), "dispatch noise \(noise) should have been filtered; got:\n\(result)")
        }
    }

    func testFormatStackTruncated_filtersDispatchNoise_realisticFrames() {
        // Real `Thread.callStackSymbols` returns frames like
        // "<idx> <module> <addr> <symbol> + <offset>", NOT bare symbol names.
        // This test catches the whole-string-vs-substring bug the existing
        // bare-symbol test missed.
        let stack = [
            "0   ClipMemory                0x000000010a3b4ef0 -[AppDelegate applicationDidFinishLaunching:] + 96",
            "1   libdispatch.dylib         0x0000000100002ac3 _dispatch_main_queue_drain + 372",
            "2   ClipMemory                0x000000010a3b5200 -[ContentView refreshDisplayedItemsCacheSoon] + 56",
            "3   libdispatch.dylib         0x00000001000028d5 _dispatch_source_latch_and_call + 47",
        ]
        let result = HangDetector.formatStackTruncated(stack: stack)
        // App frames must remain (their full-frame strings kept).
        XCTAssertTrue(result.contains("AppDelegate"))
        XCTAssertTrue(result.contains("ContentView"))
        // Dispatch noise frames must be filtered (their substrings removed from result).
        XCTAssertFalse(result.contains("_dispatch_main_queue_drain"), "must filter realistic main_queue_drain frame")
        XCTAssertFalse(result.contains("_dispatch_source_latch_and_call"), "must filter realistic source_latch frame")
        XCTAssertFalse(result.contains("_dispatch_root_queue_drain"), "must filter realistic root_queue_drain frame")
        XCTAssertFalse(result.contains("__libdispatch_source_mgr_invoke"), "must filter realistic source_mgr_invoke frame")
    }

    // MARK: - setUp (for §6.2 state tests)

    override func setUp() {
        super.setUp()
        HangDetector._resetForTesting()
    }

    // MARK: - §6.2 State manipulation tests (4 of 8 in this task; remaining 4 land in Tasks 3 + 4)

    func testRecordHeartbeat_updatesTimestamp() {
        let before = Date()
        HangDetector.recordHeartbeat()
        let after = Date()
        let s = HangDetector._snapshotStateForTesting()
        // Allow ±0.1s slack for clock granularity (spec §6.2 LOW #14 tightening).
        XCTAssertGreaterThanOrEqual(s.lastHeartbeat, before.addingTimeInterval(-0.1))
        XCTAssertLessThanOrEqual(s.lastHeartbeat, after.addingTimeInterval(0.1))
    }

    func testCheckStaleness_recentHeartbeat_noStateChange() {
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(now.addingTimeInterval(-10))
        HangDetector.checkStaleness(now: now)
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertNil(s.lastDetectedAt)
        XCTAssertNil(s.firstDetectedAt)
        XCTAssertEqual(s.detectionCount, 0)
    }

    func testCheckStaleness_exactlyAtThreshold_writesDetection() {
        // Per spec §6.2 + reviewer #2: `>=` (not `>`) means elapsed=60 must trigger.
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(now.addingTimeInterval(-60))
        HangDetector.checkStaleness(now: now)
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertNotNil(s.lastDetectedAt)
        XCTAssertNotNil(s.firstDetectedAt)
        XCTAssertEqual(s.detectionCount, 1)
    }

    func testCheckStaleness_staleHeartbeat_writesDetection() {
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(now.addingTimeInterval(-70))
        HangDetector.checkStaleness(now: now)
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertNotNil(s.lastDetectedAt)
        XCTAssertNotNil(s.firstDetectedAt)
        XCTAssertEqual(s.detectionCount, 1)
    }

    // MARK: - §6.2 State tests continued (Task 3: cap-at-5 + firstDetectedAt-once)

    func testCheckStaleness_staleHeartbeat_writesFirstDetectedAtOnlyOnce() {
        // 3 consecutive stale checks with the same `now`: firstDetectedAt must stay
        // pinned to the first call's timestamp (per spec §3 firstDetectedAt field doc).
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(now.addingTimeInterval(-70))
        HangDetector.checkStaleness(now: now)
        let first = HangDetector._snapshotStateForTesting().firstDetectedAt
        HangDetector.checkStaleness(now: now)
        HangDetector.checkStaleness(now: now)
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertEqual(s.detectionCount, 3)
        XCTAssertEqual(s.firstDetectedAt, first, "firstDetectedAt must remain pinned at the first detection time")
    }

    func testCheckStaleness_repeatedDetection_capsAt5() {
        // 6 consecutive stale checks: cap should hold at exactly 5 (per spec §5
        // LOW #15: "checker may log only when detectionCount < 5, regardless of
        // elapsed time since last log").
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(now.addingTimeInterval(-70))
        for _ in 0..<6 {
            HangDetector.checkStaleness(now: now)
        }
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertEqual(s.detectionCount, 5, "cap must hold at exactly 5 even with 6 consecutive stale checks")
    }

    // MARK: - §6.2 State tests continued (Task 4: stack capture + recovery)

    func testRecordStackCapture_capturesNonEmptyStack() {
        // Capture the test runner's call stack; on macOS 13 + XCTest it's reliably non-empty.
        // Per gate 1b H2: this test now actually asserts what its name promises. The
        // _snapshotStateForTesting() helper was widened in Task 1 Step 4 to expose
        // `lastMainStack` (5 fields instead of 4) so we can verify the population.
        HangDetector.recordStackCaptureAndMaybeRecover()
        let s = HangDetector._snapshotStateForTesting()
        XCTAssertGreaterThan(s.lastMainStack.count, 0, "recordStackCaptureAndMaybeRecover must populate lastMainStack from Thread.callStackSymbols")
        // Sanity: no detection triggered, so the recovery path doesn't run either.
        XCTAssertNil(s.lastDetectedAt, "no detection → recovery path must not clear nonexistent state")
        XCTAssertEqual(s.detectionCount, 0)
    }

    func testRecordStackCapture_clearsDetectionStateWhenRecovered() {
        // 1. Seed detection by setting stale heartbeat + calling checkStaleness once.
        let now = Date()
        HangDetector._seedLastHeartbeatForTesting(now.addingTimeInterval(-70))
        HangDetector.checkStaleness(now: now)
        let seeded = HangDetector._snapshotStateForTesting()
        XCTAssertEqual(seeded.detectionCount, 1)
        XCTAssertNotNil(seeded.firstDetectedAt)

        // 2. Simulate recovery: capture stack. Implementation must detect the prior
        //    detection and clear lastDetectedAt / firstDetectedAt / detectionCount.
        HangDetector.recordStackCaptureAndMaybeRecover()

        // 3. State must now show zeroed-out detection metadata.
        let cleared = HangDetector._snapshotStateForTesting()
        XCTAssertNil(cleared.lastDetectedAt, "recovery must clear lastDetectedAt")
        XCTAssertNil(cleared.firstDetectedAt, "recovery must clear firstDetectedAt (the downtime baseline is no longer valid)")
        XCTAssertEqual(cleared.detectionCount, 0, "recovery must reset detectionCount to 0")
    }
}
