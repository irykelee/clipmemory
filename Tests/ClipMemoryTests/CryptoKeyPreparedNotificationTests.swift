import XCTest
@testable import ClipMemory

/// P0-2 T6: handleCryptoKeyPrepared dismiss reset via .cryptoKeyPrepared
/// notification. Verifies success-gating: only success:true resets dismissed,
/// failure notifications leave it alone.
@MainActor
final class CryptoKeyPreparedNotificationTests: XCTestCase {

    // M12 (2026-08-01): per-test injected store replaces ClipboardStore.shared —
    // each instance registers its own .cryptoKeyPrepared observer in init, so
    // posting the notification exercises the same handler. Fresh instance
    // starts with empty diagnostics (prior shared-state resets unnecessary).
    private var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        store = ClipboardStore(backend: MemoryStorageBackend())
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        store = nil
        super.tearDown()
    }

    func testDismissedResetOnSuccessNotification() {
        store.diagnostics = DecryptionDiagnostics(
            keyUnavailable: false, dataCorruptedCount: 3, internalErrorCount: 0, dismissed: true
        )

        // Post success notification
        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": true]
        )

        // Observer runs on queue: .main — yield to let it fire
        let exp = expectation(description: "wait observer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(store.diagnostics.dismissed, "success notification must reset dismissed")
        XCTAssertEqual(store.diagnostics.dataCorruptedCount, 3, "other fields must be preserved")
    }

    func testDismissedNotResetOnFailureNotification() {
        store.diagnostics = DecryptionDiagnostics(
            keyUnavailable: true, dataCorruptedCount: 0, internalErrorCount: 0, dismissed: true
        )

        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": false]
        )

        let exp = expectation(description: "wait observer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(store.diagnostics.dismissed, "failure notification must NOT reset dismissed")
    }

    // MARK: - ID-STORE-NEG-CACHE-SYNC (2026-08-07)

    /// Verifies that `.cryptoKeyPrepared(success: true)` clears the
    /// `pendingFailedIDs` buffer — mirrors CryptoService's
    /// `negativeCache.removeAll()` on the same event so the two
    /// failed-state tracking layers stay aligned. Without the fix,
    /// items whose decrypt failed (`.dataCorrupted` / `.internalError`)
    /// right before the key re-ready event get merged into
    /// `items[].decryptionFailed = true` on the next main-loop tick,
    /// permanently skipping the item for the rest of the session
    /// (`prewarmDecryptionCache:1651` short-circuits on the flag).
    func testPendingFailedIDsClearedOnSuccessNotification() {
        let id = UUID()
        store.testAddPendingFailedID(id)
        XCTAssertTrue(
            store.testContainsPendingFailedID(id),
            "precondition: pendingFailedIDs must contain the staged id"
        )

        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": true]
        )

        let exp = expectation(description: "wait observer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(
            store.testContainsPendingFailedID(id),
            "pendingFailedIDs must be cleared on key re-ready (mirrors negativeCache.removeAll)"
        )
    }

    /// Negative case: a `success: false` notification must NOT touch the
    /// buffer — failures are terminal for the in-flight items, so a
    /// pendingFailedIDs snapshot stays valid for whatever follows.
    func testPendingFailedIDsPreservedOnFailureNotification() {
        let id = UUID()
        store.testAddPendingFailedID(id)

        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": false]
        )

        let exp = expectation(description: "wait observer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(
            store.testContainsPendingFailedID(id),
            "failure notification must NOT clear pendingFailedIDs"
        )
    }
}
