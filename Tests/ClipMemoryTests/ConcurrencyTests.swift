import XCTest
@testable import ClipMemory

/// E.2-E.3: Concurrency regression tests for ClipboardMonitor stateLock protection.
/// These tests verify that all mutable shared state protected by OSAllocatedUnfairLock
/// is safe from data races between main thread and timer queue.
///
/// Note: lastChangeCount and lastKnownSourceBundleId are private (H8/H9 fixes).
/// We test the internal-accessible properties (skipNextCapture, excludedBundleIds)
/// which are protected by the same stateLock — this validates the locking mechanism.
final class ConcurrencyTests: XCTestCase {

    // MARK: - E.2.2 skipNextCapture — ClipboardStore write coordination

    func testConcurrentSkipNextCaptureToggle() {
        let monitor = ClipboardMonitor()

        // Initial state: false
        XCTAssertFalse(monitor.skipNextCapture)

        let queue = DispatchQueue(label: "test.skipNextCapture", attributes: .concurrent)
        let group = DispatchGroup()

        // Rapid toggle from multiple threads
        for _ in 0..<200 {
            group.enter()
            queue.async {
                monitor.skipNextCapture = true
                group.leave()
            }
            group.enter()
            queue.async {
                monitor.skipNextCapture = false
                group.leave()
            }
        }

        group.wait()

        // Should not crash; final value is deterministic (last write wins)
        _ = monitor.skipNextCapture
    }

    func testSkipNextCaptureAfterRecordOwnWrite() {
        let monitor = ClipboardMonitor()
        monitor.skipNextCapture = false

        // Simulate ClipboardStore calling recordOwnWrite
        monitor.recordOwnWrite()

        // After recording own write, skipNextCapture should be true
        XCTAssertTrue(monitor.skipNextCapture)

        // Reset and verify
        monitor.skipNextCapture = false
        XCTAssertFalse(monitor.skipNextCapture)
    }

    func testSkipNextCaptureRapidSetAndRead() {
        let monitor = ClipboardMonitor()
        let queue = DispatchQueue(label: "test.skipNextCapture.readwrite", attributes: .concurrent)
        let group = DispatchGroup()

        // Concurrent set and read
        for i in 0..<300 {
            group.enter()
            queue.async {
                monitor.skipNextCapture = i % 2 == 0
                group.leave()
            }
            group.enter()
            queue.async {
                _ = monitor.skipNextCapture
                group.leave()
            }
        }

        group.wait()
        // No crash = PASS
    }

    // MARK: - E.2.3 excludedBundleIds — Set thread safety

    func testConcurrentExcludedBundleIdsModify() {
        let monitor = ClipboardMonitor()

        let bundleIds = [
            "com.example.app1",
            "com.example.app2",
            "com.example.app3",
            "com.passwordmanager",
            "com.lastpass"
        ]

        let queue = DispatchQueue(label: "test.excludedBundleIds", attributes: .concurrent)
        let group = DispatchGroup()

        // Concurrent adds — use atomic compound API (per gate 1b Medium #5 fix)
        for bundleId in bundleIds {
            group.enter()
            queue.async {
                monitor.updateExcludedBundleIds { ids in
                    ids.insert(bundleId)
                }
                group.leave()
            }
        }

        // Concurrent removes — use atomic compound API
        for bundleId in bundleIds {
            group.enter()
            queue.async {
                monitor.updateExcludedBundleIds { ids in
                    ids.remove(bundleId)
                }
                group.leave()
            }
        }

        // Concurrent reads (atomic getter is still safe; kept for symmetry)
        for _ in 0..<100 {
            group.enter()
            queue.async {
                _ = monitor.excludedBundleIds
                group.leave()
            }
        }

        group.wait()

        // Should not crash; Set operations should be thread-safe.
        // Concurrency-correctness check: every surviving id must be one of
        // the bundle IDs we touched (no spuriously-added entries). Whether
        // each id survived insert+remove is timing-dependent under true
        // concurrency, so we don't assert the previous strict `isEmpty` —
        // that flake would fail on multi-core machines where some inserts
        // win their race against matching removes.
        let ids = monitor.excludedBundleIds
        let originalSet = Set(bundleIds)
        let unknownIds = ids.subtracting(originalSet)
        XCTAssertTrue(unknownIds.isEmpty,
                      "excludedBundleIds must not contain entries outside the seed set; got \(unknownIds)")
    }

    func testExcludedBundleIdsContains() {
        let monitor = ClipboardMonitor()
        let testBundleId = "com.test.app"

        // Initially should not contain
        XCTAssertFalse(monitor.excludedBundleIds.contains(testBundleId))

        // Add it via atomic compound API (per gate 1b Medium #5 fix)
        monitor.updateExcludedBundleIds { ids in
            ids.insert(testBundleId)
        }

        // Should now contain
        XCTAssertTrue(monitor.excludedBundleIds.contains(testBundleId))

        // Remove it via atomic compound API
        monitor.updateExcludedBundleIds { ids in
            ids.remove(testBundleId)
        }

        // Should no longer contain
        XCTAssertFalse(monitor.excludedBundleIds.contains(testBundleId))
    }

    func testExcludedBundleIdsConcurrentReadAfterWrite() {
        let monitor = ClipboardMonitor()
        let queue = DispatchQueue(label: "test.excludedBundleIds.readwrite", attributes: .concurrent)
        let group = DispatchGroup()

        let bundleIds = ["com.test1", "com.test2", "com.test3"]

        // Writers — use atomic compound API (per gate 1b Medium #5 fix)
        for id in bundleIds {
            for _ in 0..<50 {
                group.enter()
                queue.async {
                    monitor.updateExcludedBundleIds { ids in
                        ids.insert(id)
                    }
                    group.leave()
                }
            }
        }

        // Readers
        for _ in 0..<200 {
            group.enter()
            queue.async {
                _ = monitor.excludedBundleIds.contains("com.test1")
                _ = monitor.excludedBundleIds.count
                group.leave()
            }
        }

        group.wait()
        // No crash = PASS
    }

    // MARK: - E.3 Integration: All state modified simultaneously

    func testAllInternalStateModifiedConcurrently() {
        let monitor = ClipboardMonitor()

        let queue = DispatchQueue(label: "test.allState", attributes: .concurrent)
        let group = DispatchGroup()

        // skipNextCapture toggler
        for i in 0..<100 {
            group.enter()
            queue.async {
                monitor.skipNextCapture = i % 2 == 0
                group.leave()
            }
        }

        // excludedBundleIds modifier — use atomic compound API (per gate 1b Medium #5 fix)
        let bundleIds = ["com.test1", "com.test2", "com.test3"]
        for id in bundleIds {
            group.enter()
            queue.async {
                monitor.updateExcludedBundleIds { ids in
                    ids.insert(id)
                }
                group.leave()
            }
        }

        // All readers
        for _ in 0..<100 {
            group.enter()
            queue.async {
                _ = monitor.skipNextCapture
                _ = monitor.excludedBundleIds
                _ = monitor.excludedBundleIds.contains("com.test1")
                group.leave()
            }
        }

        group.wait()

        // No crash = PASS (ThreadSanitizer would catch any real data races)
        XCTAssertTrue(true, "All concurrent access completed without crash")
    }

    // MARK: - E.2.1 skipNextCapture — simulates H8/H9 recordOwnWrite pattern

    func testRecordOwnWriteAndCheckClipboardSequence() {
        let monitor = ClipboardMonitor()

        // Simulate the pattern: ClipboardStore writes to pasteboard,
        // then calls recordOwnWrite, then checkClipboard sees skipNextCapture=true
        monitor.skipNextCapture = false

        // Step 1: ClipboardStore writes
        monitor.recordOwnWrite()  // Sets skipNextCapture = true
        XCTAssertTrue(monitor.skipNextCapture)

        // Step 2: checkClipboard sees skipNextCapture, resets it
        monitor.skipNextCapture = false
        XCTAssertFalse(monitor.skipNextCapture)

        // Step 3: Normal flow continues
        monitor.recordOwnWrite()
        XCTAssertTrue(monitor.skipNextCapture)
    }

    func testConcurrentRecordOwnWrite() {
        let monitor = ClipboardMonitor()
        let queue = DispatchQueue(label: "test.recordOwnWrite", attributes: .concurrent)
        let group = DispatchGroup()

        // Multiple threads calling recordOwnWrite simultaneously
        for _ in 0..<100 {
            group.enter()
            queue.async {
                monitor.recordOwnWrite()
                group.leave()
            }
        }

        // Concurrent reads
        for _ in 0..<100 {
            group.enter()
            queue.async {
                _ = monitor.skipNextCapture
                group.leave()
            }
        }

        group.wait()
        // No crash = PASS
    }

    // MARK: - E.3 ThreadSanitizer validation

    func testNoDataRaceWithThreadSanitizer() {
        // This test is designed to be run with ThreadSanitizer enabled.
        // It exercises the exact pattern from H8/H9 fixes:
        // - Timer queue writes to lastChangeCount (private, but we test skipNextCapture analog)
        // - Main thread reads/writes skipNextCapture
        // - Multiple threads access excludedBundleIds

        let monitor = ClipboardMonitor()
        let queue = DispatchQueue(label: "test.tsan", attributes: .concurrent)
        let group = DispatchGroup()

        // Simulate timer queue: rapid writes
        for i in 0..<100 {
            group.enter()
            queue.async {
                monitor.skipNextCapture = i % 2 == 0
                group.leave()
            }
        }

        // Simulate main thread: reads during writes
        for _ in 0..<100 {
            group.enter()
            queue.async {
                _ = monitor.skipNextCapture
                _ = monitor.excludedBundleIds
                monitor.recordOwnWrite()
                group.leave()
            }
        }

        group.wait()
        // If ThreadSanitizer is enabled, any data race would cause a failure here
    }
}
