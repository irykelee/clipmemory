import XCTest
@testable import ClipMemory

/// ID-CRASH-0032 (2026-10-20) — the single-instance guard.
///
/// The clipboard history and the recycle bin are stored as WHOLE-ARRAY
/// replacements: `ClipboardItems` and `ClipboardTrashedItems` are one JSON
/// blob each, and every write replaces the whole array. Two processes each
/// hold their own snapshot of that blob, so the second writer replaces the
/// first writer's blob with its own stale copy — entries the first deleted
/// come back, entries the first added disappear.
///
/// The guard makes the second instance exit before it touches anything. The
/// decision is an exclusive `flock` on a lock file
/// (`SingleInstanceLock`): the kernel releases it when the owner exits —
/// even on SIGKILL — and every copy of the app shares it, because an
/// `/Applications` install and a Debug build in DerivedData have the same
/// bundle id, the same UserDefaults domain and therefore the same data.
final class SingleInstanceGuardTests: XCTestCase {

    private var lockDirectory: URL!
    private var lockURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-instance-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )
        lockURL = lockDirectory.appendingPathComponent(".instance.lock")
    }

    override func tearDownWithError() throws {
        if let lockDirectory {
            try? FileManager.default.removeItem(at: lockDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - The lock itself

    /// A fresh lock can be taken.
    func testFreshLockCanBeAcquired() {
        let lock = SingleInstanceLock(fileURL: lockURL)
        XCTAssertTrue(lock.acquire(timeout: 0), "a fresh lock must be acquirable")
        XCTAssertTrue(lock.isHeld)
        lock.release()
        XCTAssertFalse(lock.isHeld)
    }

    /// The core guarantee: while one instance holds the lock, a second
    /// instance of the app cannot take it.
    func testSecondInstanceCannotAcquireWhileHeld() {
        let first = SingleInstanceLock(fileURL: lockURL)
        let second = SingleInstanceLock(fileURL: lockURL)
        XCTAssertTrue(first.acquire(timeout: 0))
        XCTAssertFalse(
            second.acquire(timeout: 0),
            "a second instance must not be allowed to own the data"
        )
        XCTAssertFalse(second.isHeld, "a refused acquisition must not report itself as held")
        first.release()
    }

    /// The lock is free again once the owner lets go — that is what lets a
    /// relaunching instance take over after the previous one exited.
    func testLockIsReacquirableAfterRelease() {
        let first = SingleInstanceLock(fileURL: lockURL)
        let second = SingleInstanceLock(fileURL: lockURL)
        XCTAssertTrue(first.acquire(timeout: 0))
        first.release()
        XCTAssertTrue(
            second.acquire(timeout: 0),
            "the lock must be free after the owner released it"
        )
        second.release()
    }

    /// A refused acquisition WAITS instead of failing instantly: the
    /// incumbent may simply be shutting down, and its exit releases the
    /// lock. This is the "quit and relaunch" case.
    func testRefusedAcquisitionWaitsForTheTimeout() {
        let first = SingleInstanceLock(fileURL: lockURL)
        let second = SingleInstanceLock(fileURL: lockURL)
        XCTAssertTrue(first.acquire(timeout: 0))
        let started = Date()
        XCTAssertFalse(second.acquire(timeout: 0.3, pollInterval: 0.02))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(
            elapsed, 0.2,
            "the newcomer must actually wait for the incumbent, not give up at once"
        )
        first.release()
    }

    /// The lock file lives in the user's Application Support directory, so
    /// every copy of the app contends for the same lock — not just the
    /// copies installed in the same folder.
    func testDefaultLockFileIsInApplicationSupport() {
        let url = SingleInstanceLock.defaultFileURL
        XCTAssertEqual(url.lastPathComponent, ".instance.lock")
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            "ClipMemory",
            "unexpected lock directory: \(url.path)"
        )
        XCTAssertEqual(
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Application Support",
            "unexpected lock parent directory: \(url.path)"
        )
    }

    /// On a fresh install the app's Application Support folder does not
    /// exist yet, and the guard runs before anything else creates it. The
    /// lock must still be acquirable — otherwise the guard silently
    /// degrades to "no guard" on a fresh install, which is exactly when it
    /// must not.
    func testLockIsAcquirableWhenTheParentDirectoryIsMissing() {
        let freshURL = lockDirectory
            .appendingPathComponent("not-created-yet", isDirectory: true)
            .appendingPathComponent(".instance.lock")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: freshURL.deletingLastPathComponent().path
            ),
            "precondition: the parent directory must not exist yet"
        )
        let lock = SingleInstanceLock(fileURL: freshURL)
        XCTAssertTrue(
            lock.acquire(timeout: 0),
            "the guard must not silently degrade to 'no guard' on a fresh install"
        )
        XCTAssertTrue(lock.isHeld)
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
        lock.release()
    }

    // MARK: - Cross-process

    /// The in-process test above proves the exclusion, but the real
    /// scenario is two *processes*. A foreign process holding the same
    /// lock file must block us.
    ///
    /// Skipped when the system Python is unavailable (the test host needs
    /// a second process to hold the lock).
    func testForeignProcessHoldingTheLockBlocksAcquisition() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: python.path),
            "/usr/bin/python3 is required to run the foreign lock holder"
        )
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.stdout.write("locked\\n")
        sys.stdout.flush()
        time.sleep(30)
        """
        let scriptURL = lockDirectory.appendingPathComponent("holder.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = python
        process.arguments = [scriptURL.path, lockURL.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { process.terminate() }

        let announced = readLine(from: output.fileHandleForReading, timeout: 20)
        XCTAssertEqual(
            announced, "locked",
            "the foreign holder never took the lock — the test proves nothing"
        )

        let lock = SingleInstanceLock(fileURL: lockURL)
        XCTAssertFalse(
            lock.acquire(timeout: 0.5, pollInterval: 0.05),
            "a foreign process holding the lock must block this instance"
        )
    }

    // MARK: - The guard's wiring

    /// The guard must never fire in a test host: the build tool launches
    /// the app binary for every `xcodebuild test`, and the test host must
    /// not lock the user out of their own app while the suite runs.
    func testGuardIsSkippedInATestHost() {
        XCTAssertTrue(
            TestIsolation.isRunningTests,
            "this test runs inside the app-hosted test process"
        )
        // Mirror of the guard's condition in `applicationDidFinishLaunching`.
        // Swift short-circuits `&&`, so the right-hand side — which would
        // take the REAL lock — is never evaluated in a test host.
        let wouldRefuse = !TestIsolation.isRunningTests
            && !SingleInstanceLock.shared.acquire(timeout: 0)
        XCTAssertFalse(wouldRefuse, "the test host must never be refused by the guard")
    }

    /// Reads one line from `handle`, giving up after `timeout` so a stuck
    /// helper cannot hang the whole suite.
    private func readLine(from handle: FileHandle, timeout: TimeInterval) -> String? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let chunk = try? handle.read(upToCount: 1), !chunk.isEmpty else {
                return nil
            }
            if chunk[0] == UInt8(ascii: "\n") { break }
            buffer.append(chunk)
        }
        return String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The "is somebody else running" helper (UX only)
    /// A candidate list that contains only this process is "no other
    /// instance".
    func testNoOtherInstanceWhenOnlyThisProcessRuns() {
        let mine = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(
            AppDelegate.hasOtherLiveInstance(candidateProcessIDs: [mine], myProcessID: mine),
            "this process must not count as another instance"
        )
    }

    /// A candidate list with a second process id IS another instance.
    func testAnotherProcessIdIsAnotherInstance() {
        let mine = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            AppDelegate.hasOtherLiveInstance(
                candidateProcessIDs: [mine, mine + 1],
                myProcessID: mine
            ),
            "a second running instance must be detected"
        )
    }

    /// An empty candidate list is "no other instance" — the common case on
    /// a machine where the app is not running yet.
    func testEmptyCandidateListIsNoOtherInstance() {
        XCTAssertFalse(
            AppDelegate.hasOtherLiveInstance(candidateProcessIDs: [], myProcessID: 42)
        )
    }

    // MARK: - The "is the lock held by somebody else" probe (ID-REVIEW-1030)
    //
    // This probe is what the ZZZ production-pollution guard uses to decide
    // whether its content comparison is *attributable*. It therefore needs
    // BOTH directions proven deterministically — not just "it returned
    // something":
    //
    //   - free lock  → false ⇒ the comparison runs (this is the CI path,
    //                   and the path where the guard has teeth)
    //   - held lock  → true  ⇒ the comparison is skipped (the path that
    //                   keeps a running app's own writes from being blamed
    //                   on the test suite)

    /// Nobody holds the lock ⇒ the probe says "no other instance".
    ///
    /// This is the CI path: with no app running, the ZZZ production-pollution
    /// comparison must actually execute, not be skipped away.
    ///
    /// The lock file does **not** exist yet in this test, so this pins the
    /// `open` failure branch (ENOENT ⇒ "not held"). The sibling test
    /// `testLockProbeReportsFreeAfterTheHolderReleases` pins the other
    /// "not held" branch (the file exists, nobody holds it).
    func testLockProbeReportsFreeWhenNobodyHoldsTheLock() {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lockURL.path),
            "precondition: the lock file must not exist yet — this test pins the "
            + "ENOENT branch, not the 'file exists but free' branch"
        )
        XCTAssertFalse(
            SingleInstanceLock.isHeldByAnotherProcess(fileURL: lockURL),
            "a lock nobody holds must not be reported as held"
        )
    }

    /// Somebody holds the lock ⇒ the probe says "another instance".
    ///
    /// `flock` is held per *open file description*, so a second descriptor
    /// conflicts even inside the same process — which is why this can be
    /// proven without spawning a second process.
    func testLockProbeReportsHeldWhileALockIsHeld() {
        let holder = SingleInstanceLock(fileURL: lockURL)
        XCTAssertTrue(holder.acquire(timeout: 0))
        defer { holder.release() }
        XCTAssertTrue(
            SingleInstanceLock.isHeldByAnotherProcess(fileURL: lockURL),
            "a held lock must be detected"
        )
    }

    /// The holder lets go ⇒ the probe says "no other instance" again.
    /// Without this the probe would latch "held" forever and the ZZZ
    /// comparison would be permanently skipped even after the app quits.
    func testLockProbeReportsFreeAfterTheHolderReleases() {
        let holder = SingleInstanceLock(fileURL: lockURL)
        XCTAssertTrue(holder.acquire(timeout: 0))
        holder.release()
        XCTAssertFalse(
            SingleInstanceLock.isHeldByAnotherProcess(fileURL: lockURL),
            "a released lock must not keep reporting 'held'"
        )
    }

    /// The real scenario is a *foreign process* holding the lock — that is
    /// what "another ClipMemory instance is running" actually means.
    func testLockProbeSeesAForeignProcessHolder() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: python.path),
            "/usr/bin/python3 is required to run the foreign lock holder"
        )
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.stdout.write("locked\\n")
        sys.stdout.flush()
        time.sleep(30)
        """
        let scriptURL = lockDirectory.appendingPathComponent("probe-holder.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = python
        process.arguments = [scriptURL.path, lockURL.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { process.terminate() }

        let announced = readLine(from: output.fileHandleForReading, timeout: 20)
        XCTAssertEqual(
            announced, "locked",
            "the foreign holder never took the lock — the test proves nothing"
        )
        XCTAssertTrue(
            SingleInstanceLock.isHeldByAnotherProcess(fileURL: lockURL),
            "a foreign process holding the lock must be detected"
        )
    }

    // MARK: - The errno decision table (ID-REVIEW-1031)
    //
    // `flock` returning EINTR cannot be provoked deterministically from a
    // test, so the decision table is a pure function and gets asserted
    // directly. The bug this pins: EINTR ("the call was interrupted by a
    // signal") used to be reported as "somebody holds the lock", which made
    // the ZZZ guard skip its production comparison for no reason.

    /// `EWOULDBLOCK` is the only errno that *proves* another holder exists.
    func testErrnoEwouldblockMeansSomebodyHoldsTheLock() {
        XCTAssertEqual(
            SingleInstanceLock.probeDecision(forErrno: EWOULDBLOCK),
            .held,
            "EWOULDBLOCK is the lock being busy — that is a real holder"
        )
    }

    /// `EINTR` means "interrupted", **not** "busy" — it must be retried, and
    /// it must never be reported as "somebody holds the lock".
    func testErrnoIntrMeansInterruptedNotHeld() {
        XCTAssertEqual(
            SingleInstanceLock.probeDecision(forErrno: EINTR),
            .retry,
            "EINTR is a signal interrupt, not proof that another holder exists"
        )
    }

    /// Any other errno means "cannot tell" ⇒ not held (the caller then runs
    /// the content comparison, which is the real backstop).
    func testErrnoOtherMeansCannotTell() {
        XCTAssertEqual(
            SingleInstanceLock.probeDecision(forErrno: ENOTSUP),
            .notHeld,
            "an unknown errno must not be guessed as 'held'"
        )
        XCTAssertEqual(
            SingleInstanceLock.probeDecision(forErrno: EACCES),
            .notHeld,
            "an unknown errno must not be guessed as 'held'"
        )
    }
}
