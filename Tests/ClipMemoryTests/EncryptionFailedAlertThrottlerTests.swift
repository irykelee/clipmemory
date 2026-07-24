import XCTest
@testable import ClipMemory

/// CLIP-3 (2026-07-24): the throttler decides when AppDelegate may show an
/// `.encryptionFailed` modal. Time is injected via a mutable clock so no test
/// sleeps; no UserDefaults or real app state is touched.
final class EncryptionFailedAlertThrottlerTests: XCTestCase {

    private var currentTime: Date!
    private var throttler: EncryptionFailedAlertThrottler!

    override func setUp() {
        super.setUp()
        currentTime = Date(timeIntervalSince1970: 1_000_000)
        throttler = EncryptionFailedAlertThrottler(window: 60, now: { [unowned self] in self.currentTime })
    }

    override func tearDown() {
        throttler = nil
        currentTime = nil
        super.tearDown()
    }

    private func advance(_ seconds: TimeInterval) {
        currentTime = currentTime.addingTimeInterval(seconds)
    }

    func testFirstFailureShowsAlertWithCountOne() {
        let decision = throttler.recordFailure(source: "addItem")
        XCTAssertTrue(decision.shouldShowAlert, "first failure must surface an alert")
        XCTAssertEqual(decision.failureCount, 1)
    }

    func testFailuresWithinWindowAreSuppressed() {
        _ = throttler.recordFailure(source: "addItem")
        advance(10)
        let second = throttler.recordFailure(source: "addItem")
        advance(20)
        let third = throttler.recordFailure(source: "addItem")
        XCTAssertFalse(second.shouldShowAlert, "repeat within 60s window must be suppressed")
        XCTAssertFalse(third.shouldShowAlert, "repeat within 60s window must be suppressed")
    }

    func testFirstFailureAfterWindowShowsWithCoalescedCount() {
        _ = throttler.recordFailure(source: "addItem")   // shown, count 1
        advance(10)
        _ = throttler.recordFailure(source: "addItem")   // suppressed
        advance(20)
        _ = throttler.recordFailure(source: "addItem")   // suppressed
        advance(31)                                       // 61s since last alert
        let decision = throttler.recordFailure(source: "addItem")
        XCTAssertTrue(decision.shouldShowAlert, "failure after the window must alert again")
        XCTAssertEqual(
            decision.failureCount, 3,
            "the alert must report the 2 suppressed failures plus the current one"
        )
    }

    func testCountResetsAfterAlertShows() {
        _ = throttler.recordFailure(source: "addItem")
        advance(10)
        _ = throttler.recordFailure(source: "addItem")   // suppressed, pending 1
        advance(55)                                       // 65s — window expired
        let second = throttler.recordFailure(source: "addItem")
        XCTAssertEqual(second.failureCount, 2)
        advance(1)
        let third = throttler.recordFailure(source: "addItem")
        XCTAssertFalse(third.shouldShowAlert, "a fresh window opens at the second alert")
    }

    func testSourcesAreThrottledIndependently() {
        _ = throttler.recordFailure(source: "addItem")
        advance(1)
        // A different source inside the window still alerts — H-3's source tag
        // exists so one noisy pipeline doesn't mask a distinct failure kind.
        let other = throttler.recordFailure(source: "ocrBackfill")
        XCTAssertTrue(other.shouldShowAlert)
        XCTAssertEqual(other.failureCount, 1)
        // ...but the original source is still inside its own window.
        let repeatFirst = throttler.recordFailure(source: "addItem")
        XCTAssertFalse(repeatFirst.shouldShowAlert)
    }

    func testSourceKeyFallsBackToUnknownWithoutUserInfo() {
        let bare = Notification(name: .encryptionFailed, object: nil)
        XCTAssertEqual(EncryptionFailedAlertThrottler.sourceKey(for: bare), "unknown")

        let tagged = Notification(
            name: .encryptionFailed,
            object: nil,
            userInfo: ["source": "addItem", "itemType": "text"]
        )
        XCTAssertEqual(EncryptionFailedAlertThrottler.sourceKey(for: tagged), "addItem")
    }

    func testUntaggedFailuresShareOneBucket() {
        _ = throttler.recordFailure(source: "unknown")
        advance(5)
        let decision = throttler.recordFailure(source: "unknown")
        XCTAssertFalse(decision.shouldShowAlert, "untagged posts must group under a single bucket")
    }
}
