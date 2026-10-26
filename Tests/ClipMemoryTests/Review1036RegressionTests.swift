import XCTest
@testable import ClipMemory

/// ID-REVIEW-1036 (2026-10-26) — regression guards for the
/// "unsynchronized static class reference" sweep.
///
/// CI run 40186263416 (2026-10-25) was red because the test HOST aborted:
/// `ServiceContainer.crypto` was a plain `static var`, so a background
/// reader could retain the existential box after the writer had released it
/// ⇒ over-release ⇒ "deallocated with non-zero retain count 2".
///
/// The independent review of ID-REVIEW-1034 then swept the codebase for the
/// same SHAPE and found two more seams whose read points are NOT
/// actor-isolated:
///
/// 1. `ServiceContainer.firstLaunch` — the readers are plain `static`
///    helpers on a view-layer type (`WelcomeView.FirstLaunchManager`), so
///    they are callable from any thread, while the only writer is
///    `setFirstLaunchForTesting` on the test thread.
/// 2. `TestIsolation.defaults` — the canonical `UserDefaults` seam. Its
///    three forwarders (`LanguageManager.defaults` /
///    `UpdateService.defaults` / `WindowManager.defaults`) are
///    `nonisolated(unsafe)`, i.e. NOT actor-isolated, while tests write the
///    seam from `setUp`.
///
/// Both are now lock-protected, mirroring the `crypto` fix. The invariants
/// below pin the two directions: the swap must survive concurrent readers,
/// and the seam must still round-trip exactly what was written into it.
///
/// ⚠️ Both concurrency tests must use the **fresh-instance, no-retention**
/// swap shape (see `assertSeamSurvivesConcurrentSwapAndRead`). Swapping
/// among a POOL of pre-created instances keeps every swapped-out instance
/// alive ⇒ its refcount never reaches zero ⇒ its `dealloc` never runs ⇒ a
/// stale reader pointer cannot fault ⇒ **the mutation would go unnoticed**
/// and the test would have no discriminating power. Measured 2026-10-26:
/// the pool shape survives 5 s of hammering, the fresh-instance shape
/// faults within 0.5 s.
@MainActor final class Review1036RegressionTests: XCTestCase {

    /// How long the readers and the swapper run, in seconds.
    ///
    /// Measured 2026-10-26 with a standalone mirror probe: the final-class
    /// shape needs ~20k swaps at 50k reads before the over-release lands,
    /// while the existential-box shape that crashed CI needs only ~300
    /// (its read-modify-write copies a multi-word buffer, not a single
    /// pointer). A count-based test is therefore brittle — it depends on the
    /// per-operation cost of the seam under test. A DURATION-based one is
    /// not: both sides spin for the same wall-clock window, so the swap
    /// burst genuinely overlaps the readers' hot loop whatever the costs.
    ///
    /// The window is also long enough for the fault to land: measured 3/3
    /// crashes at 0.5 s for the fresh-instance shape.
    private static let window: TimeInterval = 0.5

    /// Runs `read` on four background queues and `swap` on a fifth for the
    /// same wall-clock window, then waits for both sides.
    ///
    /// With an unsynchronized seam this aborts the test host — the exact
    /// failure mode that silently skipped 426 tests in CI run
    /// 40186263416. With the lock it simply completes.
    private func assertSeamSurvivesConcurrentSwapAndRead(
        read: @escaping () -> Void,
        swap: @escaping () -> Void
    ) {
        let readers = 4
        let deadline = Date().addingTimeInterval(Self.window)
        let readersDone = expectation(description: "background readers finished")
        readersDone.expectedFulfillmentCount = readers
        let swapsDone = expectation(description: "swapper finished")

        for _ in 0..<readers {
            DispatchQueue.global(qos: .userInitiated).async {
                while Date() < deadline {
                    for _ in 0..<1_000 { read() }
                }
                readersDone.fulfill()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            while Date() < deadline {
                for _ in 0..<1_000 { swap() }
            }
            swapsDone.fulfill()
        }

        wait(for: [readersDone, swapsDone], timeout: 60)
    }

    // MARK: - 1. firstLaunch must survive a concurrent swap + read

    /// The crypto crash, applied to the sibling seam. The readers below keep
    /// using the service AFTER the getter returned (that is the pattern in
    /// `FirstLaunchManager.isFirstLaunch`), so a swap that released the box
    /// too early would corrupt the reference count.
    func testFirstLaunchSeamSurvivesConcurrentSwapAndRead() {
        let original = ServiceContainer.firstLaunch
        defer { ServiceContainer.setFirstLaunchForTesting(original) }

        assertSeamSurvivesConcurrentSwapAndRead(
            read: { _ = ServiceContainer.firstLaunch.hasLaunched },
            swap: { ServiceContainer.setFirstLaunchForTesting(FirstLaunchService()) }
        )

        // The seam must still hand back a usable service.
        let current = ServiceContainer.firstLaunch
        XCTAssertTrue(current === ServiceContainer.firstLaunch,
                      "the seam must hand back the same instance on repeated reads")
    }

    // MARK: - 2. TestIsolation.defaults under concurrent swap + read

    /// Same SHAPE as the case above, on the canonical `UserDefaults` seam.
    ///
    /// The swapper creates a **fresh instance for the same suite name** on
    /// every swap and retains **none** of them. That is what makes this
    /// test discriminating:
    ///
    /// * the swapped-out instance's only strong reference is the seam's
    ///   storage slot ⇒ the writer's release drops it to **zero** ⇒ its
    ///   `dealloc` runs;
    /// * a reader that retained a stale pointer then uses freed memory.
    ///
    /// Measured 2026-10-26 with a standalone mirror probe of this exact
    /// shape (removing the lock ⇒ crash): **3/3 crashes within 0.5 s**,
    /// signature `EXC_BAD_ACCESS` inside
    /// `-[NSUserDefaults objectForKey:]` → `_CFPreferences` — i.e. the
    /// reader operated on a deallocated instance.
    ///
    /// ⚠️ The earlier version of this test swapped among 4 instances held
    /// in an array. That array kept every swapped-out instance **alive** ⇒
    /// refcount never reached zero ⇒ no `dealloc` ⇒ the mutation was
    /// **not catchable** ⇒ the test had no discriminating power. The
    /// conclusion "this type's over-release is unobservable" was **wrong**:
    /// the real variable is the **strong-reference structure of the swap**,
    /// not the referenced type. (Earlier note claiming Foundation caches
    /// `UserDefaults` per suite name was **measured false**:
    /// `UserDefaults(suiteName: "x") === UserDefaults(suiteName: "x")` is
    /// `false`, and a `UserDefaults` subclass's `deinit` does run.)
    ///
    /// One suite name for every instance ⇒ the test does not create
    /// thousands of preference domains on disk.
    func testTestIsolationDefaultsSurvivesConcurrentSwapAndRead() {
        let original = TestIsolation.defaults
        defer { TestIsolation.setDefaults(original) }

        let suiteName = "Review1036-\(UUID().uuidString)"

        assertSeamSurvivesConcurrentSwapAndRead(
            read: { _ = TestIsolation.defaults.object(forKey: "maxClipboardItems") },
            swap: { TestIsolation.setDefaults(UserDefaults(suiteName: suiteName)!) }
        )

        // The seam must still hand back a usable store.
        let current = TestIsolation.defaults
        XCTAssertTrue(current === TestIsolation.defaults,
                      "the seam must hand back the same instance on repeated reads")
    }

    // MARK: - 3. The seam must still round-trip exactly what was written

    /// The getter must return the very instance that was written in — a
    /// copy or a stale value would break the "tests reassign the seam and
    /// the services pick it up transparently" contract (ID-CRASH-0029 /
    /// ID-CRASH-0066).
    func testFirstLaunchSeamRoundTripsTheWrittenInstance() {
        let original = ServiceContainer.firstLaunch
        defer { ServiceContainer.setFirstLaunchForTesting(original) }

        let replacement = FirstLaunchService()
        ServiceContainer.setFirstLaunchForTesting(replacement)

        XCTAssertTrue(ServiceContainer.firstLaunch === replacement,
                      "the seam must return exactly the instance that was set")
    }

    /// Same for the canonical `UserDefaults` seam.
    func testTestIsolationDefaultsRoundTripsTheWrittenInstance() {
        let original = TestIsolation.defaults
        defer { TestIsolation.setDefaults(original) }

        let replacement = makeTestDefaults()
        defer { removeTestDefaults(replacement) }
        TestIsolation.setDefaults(replacement)

        XCTAssertTrue(TestIsolation.defaults === replacement,
                      "the seam must return exactly the instance that was set")
    }
}
