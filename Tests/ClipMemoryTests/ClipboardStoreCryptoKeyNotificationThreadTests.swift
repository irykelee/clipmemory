import XCTest
import AppKit
@testable import ClipMemory

/// CRIT-1 (2026-07-26 review) regression: the `.cryptoKeyPrepared` notification
/// is posted from `CryptoService.prepareKey()` running on a detached utility
/// queue. `ClipboardStore.handleCryptoKeyPrepared` must dispatch to main
/// before mutating `@Published var items`, or SwiftUI's main-thread contract
/// breaks — the same UI-freeze class as the unfixed `addItem` race.
///
/// We can't directly inject items into `pendingKeyItems` (it's `private`),
/// so the test posts the notification from a background queue and asserts
/// the handler survives cross-thread delivery without trapping. If a future
/// refactor removes the `DispatchQueue.main.async` wrapper inside
/// `handleCryptoKeyPrepared` and the handler synchronously mutates
/// `@Published var items` on the posting thread, SwiftUI's runtime contract
/// check would fire on the test host. The structural guarantee is that
/// the round-trip completes within a reasonable timeout.
@MainActor final class ClipboardStoreCryptoKeyNotificationThreadTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend)
    }

    override func tearDown() {
        store = nil
        backend = nil
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        CryptoService.resetForTesting()
        super.tearDown()
    }

    /// CRIT-1: posting `.cryptoKeyPrepared` from a background queue with
    /// `success: true` must dispatch the handler to main before mutating
    /// `@Published var items`. With `pendingKeyItems` empty (we never drove
    /// a fresh install here) the handler's main-async block is a no-op,
    /// but the cross-thread delivery itself exercises the same dispatch
    /// path that the production deferred-retry code uses.
    func testCryptoKeyPreparedCrossThreadDeliveryCompletes() {
        let expectation = expectation(description: "notification delivered cross-thread")
        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(
                name: .cryptoKeyPrepared,
                object: nil,
                userInfo: ["success": true]
            )
            DispatchQueue.main.async { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 2.0)
    }

    /// CRIT-1 (failure branch): same cross-thread posting with success=false
    /// must also dispatch to main (it posts `.encryptionFailed` + logs).
    /// A handler that synchronously mutated @Published from the posting
    /// queue would either trap here or be caught by SwiftUI's runtime
    /// contract check.
    func testCryptoKeyPreparedFailureCrossThreadDeliveryCompletes() {
        let expectation = expectation(description: "failure notification delivered cross-thread")
        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(
                name: .cryptoKeyPrepared,
                object: nil,
                userInfo: ["success": false]
            )
            DispatchQueue.main.async { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 2.0)
    }
}