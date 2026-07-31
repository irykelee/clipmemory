import XCTest
import AppKit
import Combine
@testable import ClipMemory

/// ID-MON-0001 (2026-07-31 audit) regression tests: the old `skipNextCapture`
/// contract skipped "the next changeCount bump" blindly — an external app's
/// write landing inside the skip window was swallowed as if it were our own
/// write, silently losing a history entry. The monitor must now only skip a
/// change whose content fingerprint matches the one recorded for our own
/// write (changeCount + fingerprint double check).
///
/// Tests drive `checkClipboard()` directly (internal seam added for this
/// purpose) against `NSPasteboard.general`, following the precedent of
/// CopyOcrTextOwnWriteTests. They never touch the real store, Keychain, or
/// backup directories — captures go to a stub delegate.
final class ClipboardMonitorSkipWindowTests: XCTestCase {

    private final class SkipWindowStubDelegate: ClipboardMonitorDelegate {
        var captured: [ClipboardItem] = []
        func sensitiveClearHoursForMonitor() -> Int { 0 }
        func captureRichTextSettingForMonitor() -> Bool { true }
        var captureRichTextPublisher: AnyPublisher<Bool, Never> {
            Empty().eraseToAnyPublisher()
        }
        func monitorDidCaptureItem(_ item: ClipboardItem) { captured.append(item) }
        func ocrEnabledForMonitor() -> Bool { false }
        func monitorDidRecognizeText(_ text: String, forImageItemId id: UUID, contentHash: String?) {}
    }

    override func setUp() {
        super.setUp()
        NSPasteboard.general.clearContents()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    /// Runs queued main-queue blocks: recordOwnWrite's fingerprint capture
    /// and checkClipboard's async delegate handoff.
    private func spinMain(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The audit's failure scenario: our own write is followed by an
    /// EXTERNAL write inside the same skip window. The external change must
    /// be captured, not swallowed.
    func testExternalChangeDuringSkipWindowIsCaptured() {
        let pasteboard = NSPasteboard.general
        let monitor = ClipboardMonitor()
        let delegate = SkipWindowStubDelegate()
        monitor.delegate = delegate

        // M-4 production order: recordOwnWrite() BEFORE clearContents/write.
        monitor.recordOwnWrite()
        pasteboard.clearContents()
        pasteboard.setString("clipmemory own write", forType: .string)
        spinMain() // let the deferred fingerprint capture run
        XCTAssertNotNil(monitor.ownWriteFingerprint,
                        "precondition: own-write fingerprint captured after the write")

        // An external app changes the clipboard inside the skip window.
        pasteboard.clearContents()
        pasteboard.setString("external paste", forType: .string)
        monitor.checkClipboard()
        spinMain() // let the async monitorDidCaptureItem handoff run

        XCTAssertEqual(delegate.captured.map(\.content), ["external paste"],
                       "ID-MON-0001: external change inside the skip window must not be swallowed")
        XCTAssertFalse(monitor.skipNextCapture,
                       "the stale skip flag must be dropped once an external change is detected")
    }

    /// Control: a change whose payload matches our own write must still be
    /// skipped — the anti-recapture loop stays intact.
    func testOwnWriteMatchingFingerprintIsStillSkipped() {
        let pasteboard = NSPasteboard.general
        let monitor = ClipboardMonitor()
        let delegate = SkipWindowStubDelegate()
        monitor.delegate = delegate

        monitor.recordOwnWrite()
        pasteboard.clearContents()
        pasteboard.setString("clipmemory own write", forType: .string)
        spinMain()

        monitor.checkClipboard()
        spinMain()

        XCTAssertTrue(delegate.captured.isEmpty,
                      "our own write must still be skipped (no duplicate history entry)")
        XCTAssertFalse(monitor.skipNextCapture,
                       "the skip flag is consumed by our own landed write")
        XCTAssertNil(monitor.ownWriteFingerprint,
                     "the recorded fingerprint is cleared when the flag is consumed")
    }

    /// The own write landed but the deferred fingerprint capture hasn't run
    /// yet (main queue busy): the tick must keep the flag and capture nothing
    /// — deciding without the fingerprint would reintroduce the blind skip.
    func testFingerprintPendingKeepsFlagAndCapturesNothing() {
        let pasteboard = NSPasteboard.general
        let monitor = ClipboardMonitor()
        let delegate = SkipWindowStubDelegate()
        monitor.delegate = delegate

        monitor.recordOwnWrite()
        pasteboard.clearContents()
        pasteboard.setString("clipmemory own write", forType: .string)
        // Deliberately NO run-loop spin: the main-async fingerprint capture
        // is still queued, so _ownWriteFingerprintReady == false.
        monitor.checkClipboard()

        XCTAssertTrue(monitor.skipNextCapture,
                      "flag must be kept while the fingerprint is pending")
        XCTAssertTrue(delegate.captured.isEmpty,
                      "nothing may be captured or swallowed while undecided")
        spinMain() // drain the queued fingerprint capture before tearDown
    }
}
