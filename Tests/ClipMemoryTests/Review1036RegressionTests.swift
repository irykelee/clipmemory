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
        XCTAssertNotNil(ServiceContainer.firstLaunch)
    }

    // MARK: - 2. TestIsolation.defaults under concurrent swap + read

    /// Same SHAPE as the case above, on the canonical `UserDefaults` seam.
    ///
    /// ⚠️ This test is deliberately NOT presented as the proof that the
    /// `defaults` lock works — for THAT type the over-release is **not
    /// observable**, and the mutation cannot be caught. Measured
    /// 2026-10-26 with a standalone mirror probe, same process, same
    /// duration-based hammering:
    ///
    /// * a plain `final class` reference → crashes within 0.5 s with
    ///   "deallocated with non-zero retain count 2";
    /// * a `UserDefaults` reference → **survives 5 s** of continuous
    ///   swapping, because Foundation keeps a per-suite cache alive, so the
    ///   instance's refcount never reaches zero and the over-release has no
    ///   dealloc to trip over.
    ///
    /// ⇒ **Exploitability depends on the lifetime semantics of the
    /// referenced type, not only on the shape of the static.** The lock on
    /// `TestIsolation.defaults` is still correct (the read-modify-write is
    /// non-atomic either way, and the three forwarders are
    /// `nonisolated(unsafe)`), but this test only pins that the seam stays
    /// usable under concurrency — it does NOT falsify the lock.
    ///
    /// The lock's real proof is the `firstLaunch` case above, whose type
    /// (`FirstLaunchService`) has no such cache and whose crash signature
    /// is byte-identical to the CI incident.
    func testTestIsolationDefaultsSurvivesConcurrentSwapAndRead() {
        let original = TestIsolation.defaults
        defer { TestIsolation.setDefaults(original) }

        let alternatives = (0..<4).map { _ in makeTestDefaults() }
        defer { alternatives.forEach { removeTestDefaults($0) } }
        var index = 0

        assertSeamSurvivesConcurrentSwapAndRead(
            read: { _ = TestIsolation.defaults.object(forKey: "maxClipboardItems") },
            swap: {
                TestIsolation.setDefaults(alternatives[index % alternatives.count])
                index += 1
            }
        )

        // The seam must still hand back a usable store.
        XCTAssertNotNil(TestIsolation.defaults)
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
