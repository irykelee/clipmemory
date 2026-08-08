import XCTest
@testable import ClipMemory

/// ID-SILENT-0019 (2026-08-08 audit): `pendingFailedIDs.removeAll()` on
/// `.cryptoKeyPrepared(success: true)` was added by `aeedf6e` to mirror
/// `CryptoService.negativeCache.removeAll()`. But the sibling state —
/// `items[].decryptionFailed = true` set by `mergePendingDecryptionFailures`
/// — was NOT reset. User sees blank rows for items that failed to decrypt
/// during the cold-start key-not-ready window; restart heals them but the
/// in-session UX stays broken.
///
/// These tests pin the post-fix contract: on key re-ready, all
/// `decryptionFailed` flags must reset so the next `getDecryptedContent`
/// attempt can re-decrypt (and succeed for transient key-unavailable
/// failures; re-fail for genuinely corrupted data, which is the correct
/// behavior anyway since prewarm would re-mark them).
@MainActor
final class ClipboardStoreDecryptionFlagResetTests: XCTestCase {

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

    /// ID-SILENT-0019 fix: a single item marked `decryptionFailed=true`
    /// (simulating the post-merge state during cold-start key-not-ready
    /// window) must have its flag reset on `.cryptoKeyPrepared(success:)`.
    /// Pre-fix: flag stays true, `getDecryptedContent` short-circuits at
    /// `:1471`, user sees blank row for rest of session.
    func testDecryptionFailedFlagResetOnSuccessNotification() {
        let item = ClipboardItem(content: "captured during key-not-ready", type: .text)
        store.addItem(item)
        let itemID = store.items[0].id
        // Simulate `mergePendingDecryptionFailures` having run on this ID.
        store.items[0].decryptionFailed = true
        XCTAssertTrue(store.items[0].decryptionFailed, "precondition: flag set by merge")

        // ID-TEST-0001 (2026-08-08 audit): observer-driven fulfillment.
        // Count-based observer (vs `expectation(forNotification:)`) so we
        // can also assert exact post count and tolerate the brief race
        // between the success notification and any subsequent
        // addItem-driven re-failures.
        var postCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .cryptoKeyPrepared, object: nil, queue: .main
        ) { _ in postCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": true]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThanOrEqual(postCount, 1, "notification must fire")
        XCTAssertEqual(store.items.first?.id, itemID, "item must remain in store")
        XCTAssertFalse(
            store.items[0].decryptionFailed,
            "ID-SILENT-0019: flag must reset on key re-ready"
        )
    }

    /// Negative: a `success: false` notification must NOT touch
    /// `decryptionFailed` flags (failures are terminal for the in-flight
    /// items; only success should heal).
    func testDecryptionFailedFlagPreservedOnFailureNotification() {
        let item = ClipboardItem(content: "captured", type: .text)
        store.addItem(item)
        store.items[0].decryptionFailed = true

        // ID-TEST-0001: observer-driven (count-based for assertion).
        var postCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .cryptoKeyPrepared, object: nil, queue: .main
        ) { _ in postCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": false]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThanOrEqual(postCount, 1, "observer must fire on failure notification")
        XCTAssertTrue(
            store.items[0].decryptionFailed,
            "failure notification must NOT reset decryptionFailed"
        )
    }

    /// Multi-item coverage: a batch of failed items must all reset.
    /// Guards against the fix only handling the single-item path.
    /// NOTE: `addItem` re-sorts `items` by `createdAt` desc after each
    /// call, so we capture item IDs up front and set flags by ID lookup
    /// (not by index).
    func testMultipleDecryptionFailedFlagsAllReset() {
        var addedIDs: [UUID] = []
        for i in 0..<3 {
            let item = ClipboardItem(content: "item \(i)", type: .text)
            store.addItem(item)
            addedIDs.append(item.id)
        }
        // Set decryptionFailed=true on all 3 by ID (survives sort).
        for id in addedIDs {
            if let idx = store.items.firstIndex(where: { $0.id == id }) {
                store.items[idx].decryptionFailed = true
            }
        }
        XCTAssertTrue(store.items.allSatisfy { $0.decryptionFailed }, "precondition")

        // ID-TEST-0001: observer-driven.
        var postCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .cryptoKeyPrepared, object: nil, queue: .main
        ) { _ in postCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(
            name: .cryptoKeyPrepared, object: nil, userInfo: ["success": true]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThanOrEqual(postCount, 1, "notification must fire")
        XCTAssertTrue(
            store.items.allSatisfy { !$0.decryptionFailed },
            "all decryptionFailed flags must reset on key re-ready"
        )
    }
}
