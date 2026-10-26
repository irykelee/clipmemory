import XCTest
@testable import ClipMemory

/// ID-REVIEW-1034 (2026-10-26) — regression guards for the CI incident in
/// run 40186263416 (2026-10-25).
///
/// The chain that turned one test-host crash into an unrelated failure
/// hundreds of lines later:
///
/// 1. `DecryptionFailedLoopTests.testPreFailedItemReturnsNilImmediately`
///    crashed the host — `ServiceContainer.crypto` was a plain `static var`,
///    so a background reader could retain the existential box after the
///    writer had released it (over-release ⇒ "deallocated with non-zero
///    retain count 2").
/// 2. xcodebuild relaunched the host ("Restarting after unexpected exit,
///    crash, or test timeout") and continued with the REMAINING classes.
/// 3. The relaunched process never re-ran `AAASuiteBootstrapTests`
///    (alphabetically first ⇒ already done), so the shared-suite cleanup
///    observer — registered there — was never installed.
/// 4. `IntegrationTests.testTrimToMaxItemsRemovesOldest` had published
///    `maxClipboardItems = 3` into the shared suite (its "restore" targeted
///    `UserDefaults.standard`, the wrong domain ⇒ a no-op).
/// 5. `QuickBarViewTests.testComputeDisplayedItemsEmptySearchReturnsPrefix`
///    read that stale `3`, trimmed its 10-item fixture to 3, and failed
///    with `("3") is not equal to ("8")`.
///
/// Four independent invariants are pinned here — one per link in that chain.
@MainActor final class Review1034RegressionTests: XCTestCase {

    // MARK: - 1. The crypto seam must survive a concurrent swap + read

    /// The crash itself: `ServiceContainer.crypto` used to be an unsynchronised
    /// global read by background queues (contentHash backfill, ImageStorage
    /// encrypt/decrypt) and written by tests on the main thread. The
    /// read-modify-write of the existential box was not atomic ⇒ over-release
    /// ⇒ the Swift runtime aborted the process.
    ///
    /// The lock makes the load-and-retain atomic with respect to the swap.
    /// The readers below deliberately keep using the service AFTER the getter
    /// returned (that is the pattern in `getDecryptedContent` /
    /// `decryptWithReason`), so a swap that released the box too early would
    /// corrupt the reference count.
    func testCryptoSeamSurvivesConcurrentSwapAndRead() {
        let original = ServiceContainer.crypto
        defer { ServiceContainer.setCryptoForTesting(original) }

        let readCount = 50_000
        let swapCount = 300
        let readers = 4
        let finished = expectation(description: "background readers finished")
        finished.expectedFulfillmentCount = readers

        for reader in 0..<readers {
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<readCount {
                    // Touch the service so the existential box is really
                    // retained and used — not merely loaded.
                    _ = ServiceContainer.crypto.isOldFormat("Zm9v")
                    if i == readCount / 2 {
                        // Yield so the writers get a chance to interleave.
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                finished.fulfill()
            }
        }

        for i in 0..<swapCount {
            let key = Data((0..<32).map { UInt8((i &+ $0) & 0xFF) })
            ServiceContainer.setCryptoForTesting(CryptoService(customKeyData: key))
        }

        wait(for: [finished], timeout: 60)

        // The seam must still hand back a usable service.
        XCTAssertNotNil(ServiceContainer.crypto.encrypt("probe"))
    }

    // MARK: - 2. An injected defaults suite must fully isolate the store

    /// The victim's perspective: a store that got its OWN defaults suite must
    /// resolve `maxItems` from THAT suite, even when the process-shared
    /// suite holds a different (stale) value. This is the invariant
    /// `QuickBarViewTests` now depends on.
    func testStoreWithInjectedDefaultsResolvesMaxItemsFromThatSuite() {
        let sharedSuite = UserDefaults(suiteName: "ClipboardStore-XCTest-isolation")!
        // A value that is neither the default (100) nor the injected one, so
        // the two sources are distinguishable in both directions.
        sharedSuite.set(7, forKey: "maxClipboardItems")
        defer { sharedSuite.removeObject(forKey: "maxClipboardItems") }

        let injected = makeTestDefaults()
        injected.set(87, forKey: "maxClipboardItems")
        defer { removeTestDefaults(injected) }

        let store = ClipboardStore(backend: MemoryStorageBackend(), defaults: injected)
        XCTAssertEqual(store.maxItems, 87,
                       "maxItems must be resolved from the INJECTED suite, never from the shared one")

        // The write path must land in the injected suite as well — and must
        // NOT leak into the shared suite.
        store.maxItems = 91
        XCTAssertEqual(injected.object(forKey: "maxClipboardItems") as? Int, 91)
        XCTAssertNotEqual(sharedSuite.object(forKey: "maxClipboardItems") as? Int, 91,
                          "the store must not write into the process-shared suite")
    }

    /// The end-to-end shape of the CI failure: 10 items, a cap of 3 read
    /// from the shared suite, and the display cap of 8 — the exact numbers
    /// behind `("3") is not equal to ("8")`.
    func testStoreWithInjectedDefaultsKeepsAllItemsWhenSharedSuiteIsDirty() {
        let sharedSuite = UserDefaults(suiteName: "ClipboardStore-XCTest-isolation")!
        sharedSuite.set(3, forKey: "maxClipboardItems")
        defer { sharedSuite.removeObject(forKey: "maxClipboardItems") }

        let injected = makeTestDefaults()
        defer { removeTestDefaults(injected) }
        let store = ClipboardStore(backend: MemoryStorageBackend(), defaults: injected)

        for i in 1...10 {
            store.addItem(ClipboardItem(content: "item \(i)", type: .text))
        }

        XCTAssertEqual(store.items.count, 10,
                       "a dirty shared suite must not trim this store's items")
    }

    // MARK: - 3. The shared-suite cleanup must really remove what was written

    /// The cleanup the observer performs before every test case. If this
    /// stops removing the value, every test that reads store settings from
    /// the shared suite becomes order-dependent again.
    func testSharedSuiteCleanupRemovesValuesWrittenByAnotherTest() {
        let sharedSuite = UserDefaults(suiteName: "ClipboardStore-XCTest-isolation")!
        sharedSuite.set(3, forKey: "maxClipboardItems")
        XCTAssertEqual(sharedSuite.object(forKey: "maxClipboardItems") as? Int, 3,
                       "precondition: the value must be readable before the cleanup runs")

        XCTestIsolationSuiteBootstrap.clearSharedSuites()

        XCTAssertNil(sharedSuite.object(forKey: "maxClipboardItems"),
                     "the cleanup must remove what the previous test wrote")
    }

    // MARK: - 4. A write into the shared suite must be DETECTED

    /// The amplifier: the observer used to be registered in
    /// `AAASuiteBootstrapTests.class func setUp()`. That class is
    /// alphabetically FIRST, so a host that `xcodebuild` relaunched after a
    /// crash never re-ran it ⇒ no observer ⇒ the shared suite kept its
    /// stale values for the rest of the run.
    ///
    /// The observer still depends on that class running (Swift forbids
    /// overriding `+load`), so the incident is prevented structurally:
    /// no test writes into the shared suite any more. This test pins the
    /// detection that turns a future violation from an invisible state
    /// change into a named failure.
    func testWriteIntoSharedSuiteIsDetected() {
        let sharedSuite = UserDefaults(suiteName: XCTestIsolationSuiteBootstrap.clipboardStoreSuiteName)!
        sharedSuite.set(3, forKey: XCTestIsolationSuiteBootstrap.guardedSharedSuiteKey)
        defer {
            sharedSuite.removeObject(forKey: XCTestIsolationSuiteBootstrap.guardedSharedSuiteKey)
            // Do not leave the synthetic violation in the record — the
            // ZZZ canary asserts the record is empty.
            XCTestIsolationSuiteBootstrap.forgetViolations(forTestCase: "SelfTest")
        }

        XCTestIsolationSuiteBootstrap.recordSharedSuiteViolationIfPresent(testCase: "SelfTest")
        XCTAssertTrue(
            XCTestIsolationSuiteBootstrap.sharedSuiteViolations.contains { $0.contains("SelfTest") },
            "a write into the shared isolation suite must be recorded"
        )
    }
}
