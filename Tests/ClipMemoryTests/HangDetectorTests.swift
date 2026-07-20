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
}
