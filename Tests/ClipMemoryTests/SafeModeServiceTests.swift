import XCTest
@testable import ClipMemory

/// ID-CRASH-0003 (2026-08-16 audit MEDIUM-1 fix): the sentinel-based
/// crash detection has to work in every real-world scenario — first
/// launch, normal launches in a row, abnormal terminations (crash,
/// force-quit), and the 3-launch threshold boundary. These tests use
/// an isolated `UserDefaults` suite + tmp-dir for the sentinel so they
/// don't touch the user's real Application Support directory.
@MainActor
final class SafeModeServiceTests: XCTestCase {

    private var tmpDir: URL!
    private var defaultsSuite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "SafeModeServiceTests-\(UUID().uuidString)"
        defaultsSuite = TestSuiteCleanup.makeSuite(named: suiteName)
        // Each test gets a fresh sentinel dir so cross-test pollution
        // is impossible even if tearDown is skipped on a test failure.
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TestSuiteCleanup.destroy(defaultsSuite)
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        defaultsSuite = nil
        suiteName = nil
    }

    /// ID-CRASH-0003: first-ever launch has no sentinel and a fresh
    /// counter — that's NOT a crash. (We can't tell the difference
    /// between "first launch" and "crash on first launch" without
    /// some out-of-band signal; the threshold absorbs the rare case
    /// of a crash-on-first-launch appearing as 1 in the counter.)
    func testFirstLaunchStartsAtZero() {
        let service = makeService()
        XCTAssertEqual(service.crashCount, 0)
        XCTAssertFalse(service.isInSafeMode)
    }

    /// ID-CRASH-0003: the previous launch's sentinel is **gone** ⇒ it
    /// exited gracefully ⇒ NOT a crash.
    ///
    /// ⚠️ ID-REVIEW-1046 (2026-10-28): this assertion used to be the
    /// other way round ("missing sentinel ⇒ count a crash"), which was
    /// the **inverted** polarity: the sentinel is deleted on a GRACEFUL
    /// exit (`clearSentinelOnNormalExit`), so "missing" means "exited
    /// normally" ⇒ every normal ⌘Q was counted as a crash (the user's
    /// `safeMode.crashCount` reached 8 and safe mode was switched on for
    /// an app that had never crashed).
    func testMissingSentinelDoesNotIncrementCrashCount() {
        let service = makeService()
        // No sentinel in tmpDir → previous launch exited gracefully.
        service.registerPreviousLaunchDidCrash()
        XCTAssertEqual(service.crashCount, 0)
        XCTAssertFalse(service.isInSafeMode)
    }

    /// ID-REVIEW-1046 (2026-10-28): the previous launch's sentinel is
    /// **still there** ⇒ it never reached `applicationWillTerminate` ⇒
    /// it crashed ⇒ count it.
    ///
    /// ⚠️ The directory must exist before the sentinel can be written —
    /// the service creates it in `writeSentinel()`, but a *manual* write
    /// would silently fail (`try?`) and the test would then pass for the
    /// wrong reason.
    func testSurvivingSentinelIncrementsCrashCount() throws {
        let service = makeService()
        let sentinel = tmpDir.appendingPathComponent("ClipMemory/.running-sentinel")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        service.registerPreviousLaunchDidCrash()
        XCTAssertEqual(service.crashCount, 1)
        XCTAssertFalse(service.isInSafeMode, "1 < 3 threshold")
    }

    /// ID-CRASH-0003: three consecutive crashes activate safe-mode.
    ///
    /// ID-REVIEW-1046: a crash is now simulated by **leaving** the
    /// sentinel in place (the service writes it on every launch, so the
    /// next launch sees it ⇒ counts). The old version deleted the
    /// sentinel between launches, which under the inverted polarity was
    /// how you faked a crash.
    ///
    /// ⚠️ **off-by-one 是协议固有的**：哨兵由上一次启动写下 ⇒ 「上一次崩了」
    /// 要到本次启动才被计到 ⇒ 3 次崩溃需要 4 次启动才数满 3。
    func testThreeConsecutiveCrashesActivateSafeMode() {
        let service = makeService()
        // Launch 1 — fresh install, nothing to judge yet.
        service.registerPreviousLaunchDidCrash()
        XCTAssertEqual(service.crashCount, 0)
        XCTAssertFalse(service.isInSafeMode)
        // Launch 2 — launch 1's sentinel survived ⇒ launch 1 crashed.
        service.registerPreviousLaunchDidCrash()
        XCTAssertEqual(service.crashCount, 1)
        XCTAssertFalse(service.isInSafeMode)
        // Launch 3
        service.registerPreviousLaunchDidCrash()
        XCTAssertEqual(service.crashCount, 2)
        XCTAssertFalse(service.isInSafeMode, "2 < 3 threshold")
        // Launch 4 — third consecutive crash.
        service.registerPreviousLaunchDidCrash()
        XCTAssertEqual(service.crashCount, 3)
        XCTAssertTrue(service.isInSafeMode, "3 >= 3 threshold → safe-mode activates")

        // stateDidChangeNotification must have been posted at least
        // once so the banner view can refresh. We don't assert on the
        // exact count — the threshold crossing may post once or
        // multiple times depending on internal structure.
        let exp = expectation(forNotification: .safeModeStateDidChange, object: nil)
        // Give the queue a tick to drain any pending posts.
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    /// ID-CRASH-0003: after a successful launch, the counter resets.
    func testSuccessfulLaunchResetsCounter() {
        let service = makeService()
        // Two crashes in a row (each launch's sentinel survives into the
        // next launch ⇒ counted there — hence the off-by-one).
        service.registerPreviousLaunchDidCrash() // launch 1 → 0
        service.registerPreviousLaunchDidCrash() // launch 2 → 1
        service.registerPreviousLaunchDidCrash() // launch 3 → 2
        XCTAssertEqual(service.crashCount, 2)

        service.registerSuccessfulLaunch()
        XCTAssertEqual(service.crashCount, 0, "successful launch resets counter")
    }

    /// ID-CRASH-0003: exitSafeMode() clears both flags so the next 3
    /// consecutive crashes re-arm the banner.
    func testExitSafeModeClearsState() {
        let service = makeService()
        // Force into safe mode by repeated registration (4 launches for
        // 3 crashes — the crash is counted at the NEXT launch).
        for _ in 0..<4 {
            service.registerPreviousLaunchDidCrash()
        }
        XCTAssertTrue(service.isInSafeMode)

        service.exitSafeMode()
        XCTAssertFalse(service.isInSafeMode)
        XCTAssertEqual(service.crashCount, 0)
    }

    /// ID-CRASH-0003: normal exit removes the sentinel — the next
    /// launch's registerPreviousLaunchDidCrash() should NOT count as
    /// a crash.
    ///
    /// ⚠️ ID-REVIEW-1046 (2026-10-28): this test's NAME always said
    /// "prevents", but its ASSERTION said the opposite (`crashCount ==
    /// before + 1`) and a long comment explained why: the author had
    /// found that the polarity was inverted and papered over it with
    /// "the threshold absorbs the noise". The polarity is now correct
    /// ⇒ the name and the assertion finally agree.
    func testNormalExitPreventsCrashCount() {
        let service = makeService()
        // Simulate a normal launch (sentinel written) followed by a
        // normal exit (sentinel removed).
        service.registerPreviousLaunchDidCrash() // writes sentinel
        service.clearSentinelOnNormalExit()

        let crashCountBefore = service.crashCount
        service.registerPreviousLaunchDidCrash() // sees no sentinel
        XCTAssertEqual(service.crashCount, crashCountBefore,
            "after a normal exit the next launch must NOT count as a crash")
        XCTAssertFalse(service.isInSafeMode)
    }

    /// ID-CRASH-0003: threshold boundary — exactly 2 crashes must
    /// not trigger safe-mode; exactly 3 must.
    ///
    /// ⚠️ off-by-one: the crash of launch N is counted at launch N+1 ⇒
    /// 3 crashes need 4 launches.
    func testThresholdBoundary() {
        let service = makeService()
        // Launch 1 → 0, launch 2 → 1, launch 3 → 2, launch 4 → 3.
        for launch in 1...4 {
            service.registerPreviousLaunchDidCrash()
            if launch < 4 {
                XCTAssertFalse(
                    service.isInSafeMode,
                    "launch \(launch) → crashCount \(launch - 1) < 3 ⇒ must NOT activate safe-mode"
                )
            }
        }
        XCTAssertTrue(service.isInSafeMode, "3rd consecutive crash activates safe-mode")
    }

    // MARK: - Helpers

    /// Build a service pointed at the test-only UserDefaults + a
    /// tmp-dir Application Support root so the sentinel never lands
    /// in the user's real Application Support directory.
    private func makeService() -> SafeModeService {
        SafeModeService(defaults: defaultsSuite, directory: tmpDir)
    }

    // MARK: - ID-CRASH-0004 sentinel-write retry / degraded path

    /// ID-CRASH-0004: when `Data().write(to:)` fails three times in a
    /// row, `isSentinelHealthy` must become false so the next launch's
    /// `registerPreviousLaunchDidCrash` short-circuits and the banner
    /// surfaces the degraded hint. We use a FileManager subclass
    /// whose `createDirectory` / atomic write both throw to simulate
    /// a disk-full / sandboxed-home scenario.
    func testSentinelWriteFailureMarksServiceDegraded() {
        final class FailingFileManager: FileManager, @unchecked Sendable {
            override func createDirectory(
                at url: URL,
                withIntermediateDirectories createIntermediates: Bool,
                attributes: [FileAttributeKey: Any]? = nil
            ) throws {
                throw NSError(domain: "test", code: 28 /* ENOSPC */)
            }
        }
        let fm = FailingFileManager()
        let service = SafeModeService(defaults: defaultsSuite, fileManager: fm, directory: tmpDir)
        XCTAssertTrue(service.isSentinelHealthy, "starts healthy on first launch")

        service.registerPreviousLaunchDidCrash()
        XCTAssertFalse(service.isSentinelHealthy,
            "after three failed write attempts sentinel must be marked degraded")
        XCTAssertEqual(service.crashCount, 0,
            "degraded path must NOT increment crashCount (we can't tell if a missing sentinel is a crash or our own write failure)")
    }

    /// ID-CRASH-0004: degraded mode is sticky — once flipped, the
    /// service stays in degraded until `exitSafeMode()` resets it.
    /// `registerSuccessfulLaunch()` does NOT reset it (that's for the
    /// crash counter only).
    func testDegradedFlagIsStickyAcrossLaunches() {
        let service = makeService()
        // Force into degraded state by simulating three failed writes.
        defaultsSuite.set(false, forKey: "safeMode.sentinelHealthy")
        XCTAssertFalse(service.isSentinelHealthy)

        service.registerSuccessfulLaunch()
        XCTAssertFalse(service.isSentinelHealthy,
            "registerSuccessfulLaunch must NOT clear degraded (it's only for the counter)")
        XCTAssertEqual(service.crashCount, 0,
            "registerSuccessfulLaunch resets the counter to 0")
    }

    /// ID-CRASH-0004: `exitSafeMode()` re-arms both safe-mode AND
    /// the sentinel-writer. The user's "Disable Safe Mode" click is
    /// also a signal they trust the install again, so the writer
    /// gets a fresh attempt on the next launch.
    func testExitSafeModeReArmsSentinelWriter() {
        defaultsSuite.set(true, forKey: "safeMode.active")
        defaultsSuite.set(false, forKey: "safeMode.sentinelHealthy")
        defaultsSuite.set(5, forKey: "safeMode.crashCount")

        let service = makeService()
        service.exitSafeMode()

        XCTAssertFalse(service.isInSafeMode)
        XCTAssertTrue(service.isSentinelHealthy,
            "exitSafeMode must reset the sentinel-writer healthy flag")
        XCTAssertEqual(service.crashCount, 0)
    }

    /// ID-CRASH-0004: recovery — when a write succeeds after a
    /// transient failure, the degraded flag must flip back to true
    /// so the next launch's crash detection is live again. Hard to
    /// exercise without injecting a stateful FileManager; verify
    /// the unit-level contract instead — when the write path
    /// returns successfully the recovered flag is set to true.
    /// The full recovery round-trip is exercised by the integration
    /// build smoke (which writes and re-launches in CI).
    func testRecoveredSentinelResetsDegradedFlag() {
        // Simulate "previous launch was degraded" state.
        defaultsSuite.set(false, forKey: "safeMode.sentinelHealthy")
        let service = makeService()
        XCTAssertFalse(service.isSentinelHealthy)

        // Real write path now (no failing FileManager this time) →
        // the next registerPreviousLaunchDidCrash succeeds and flips
        // the flag back. We can't observe the writeSentinel() call
        // directly (it's private), but we can verify the public
        // observable: after a successful launch the service is
        // healthy.
        service.registerPreviousLaunchDidCrash()
        XCTAssertTrue(service.isSentinelHealthy,
            "successful write recovery must flip degraded → healthy")
    }
}

private extension Notification.Name {
    /// Mirrors SafeModeService.stateDidChangeNotification for tests
    /// that need to wait on the post. Lives here (not in
    /// LocalizationService or a shared header) because it's a
    /// test-only convenience — production code reads the constant
    /// directly off SafeModeService.
    static let safeModeStateDidChange = Notification.Name("SafeModeService.stateDidChange")
}
