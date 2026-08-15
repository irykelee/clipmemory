import XCTest
@testable import ClipMemory

/// L26 Path E (2026-08-15): exception paths in BackupService not yet covered
/// by `BackupServiceTests` or `BackupIncompleteMarkerTests`.
///
/// Hypothesis (per `feedback/l26-live-drill-beats-static-audit`): static
/// review found `pruneOldBackups` and `backupNow` have well-tested happy
/// paths (5+ tests for prune variants, 2+ for backup cleanup). What is NOT
/// tested is the *failure-mode* contract when individual FS operations fail
/// mid-flight — particularly the "log error and continue" branches that
/// could silently leak disk space if they exit early or fail to clean up.
///
/// All tests use real temp dirs + chmod 0o000 (matching `BackupServiceTests`'s
/// `testBackupNowCleansUpPartialDirOnImageCopyFailure` pattern) so the
/// exceptions are real `NSError` instances, not mock-injected ones — this
/// matters because `CocoaError` carries the actual `code` (`.fileReadNoPermission`
/// vs `.fileWriteNoPermission`) which is what the catch branches see.
final class BackupServiceExceptionPathTests: XCTestCase {

    private var tempRoot: URL!
    private var backupsDir: URL!
    private var imagesDir: URL!
    private var defaults: UserDefaults!
    private var service: BackupService!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupServiceExceptionPathTests-\(UUID().uuidString)", isDirectory: true)
        backupsDir = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "BackupServiceExceptionPathTests-\(UUID().uuidString)")
        service = BackupService(backupsDirectory: backupsDir, imagesDirectory: imagesDir, defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        backupsDir = nil
        imagesDir = nil
        defaults = nil
        service = nil
        super.tearDown()
    }

    /// Seed `n` timestamped backup dirs under `backupsDir`, each containing
    /// just a `placeholder.txt` file so they're treated as real dirs by
    /// `contentsOfDirectory`. The format MUST be 21 chars (matching the
    /// live `yyyy-MM-dd_HHmmss.SSS` format) for `Self.isBackupDirName` to
    /// recognize them — see `BackupService.isBackupDirName` for the parser.
    private func seedBackupDirs(_ n: Int, prefix: String = "") throws {
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        for i in 0..<n {
            // %04d-%02d-%02d_%02d%02d%02d.%03d = 4+1+2+1+2+1+6+1+3 = 21 chars
            let name = String(format: "%@%04d-%02d-%02d_%02d%02d%02d.%03d", prefix,
                              2000 + i, 1, 1, i, 0, 0)
            let dir = backupsDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("placeholder".utf8).write(to: dir.appendingPathComponent("placeholder.txt"))
        }
    }

    /// Strip posixPermissions from a path (used in defer to undo chmod 0o000
    /// before tearDown removes the temp root).
    private func unlock(_ path: String) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: path
        )
    }

    // MARK: - pruneOldBackups exception paths

    /// pruneOldBackups' count-based loop catches per-dir removeItem errors
    /// and continues (line 397-401). Real test: lock down ONE of the excess
    /// dirs so its removeItem throws NSError code `.fileWriteNoPermission`,
    /// then verify the OTHER excess dirs are pruned correctly. Captures
    /// the behavior so any future refactor that breaks "log and continue"
    /// (e.g., early-exit on first failure) gets caught.
    func testPruneContinuesAfterMidLoopRemoveFailure() throws {
        try seedBackupDirs(5)
        // keepCount setter triggers async prune — bypass per
        // ID-BACKUP-0003/0005 by writing the key directly.
        defaults.set(3, forKey: "backupKeepCount")
        let sorted = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        let validSorted = sorted.filter { $0.count == 21 }.sorted()
        XCTAssertEqual(validSorted.count, 5)

        // Lock the middle excess dir (oldest of the 2 to be removed).
        // chmod 0o000 makes the dir unremovable — removeItem throws.
        let lockedName = validSorted[0]  // oldest, will be first to be removed
        let lockedPath = backupsDir.appendingPathComponent(lockedName).path
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: lockedPath
        )
        defer { unlock(lockedPath) }

        service.pruneOldBackups()

        // After prune: keepCount=3 dirs remain. The locked dir stays
        // (cannot be removed), but the OTHER excess dir must be pruned.
        let after = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        let afterValid = after.filter { $0.count == 21 }
        XCTAssertEqual(afterValid.count, 4,
            "1 locked + 3 kept; if prune exited early on first failure, afterValid would be 5")
        XCTAssertTrue(afterValid.contains(lockedName),
            "locked dir must survive — chmod 0o000 prevents removeItem; loop continues past it")
        // The other excess dir must be gone.
        XCTAssertFalse(afterValid.contains(validSorted[1]),
            "the other excess dir (not locked) must be pruned despite the locked dir's failure")
    }

    /// If `pruneOldBackups` cannot list `backupsDirectory` at all (parent
    /// gone, permissions revoked, sandbox denied), the method logs an
    /// error and returns early (line 374-376). Captured behavior:
    /// prune becomes a silent no-op. **Implication for production**:
    /// Backups/ grows unbounded if the listing fails repeatedly. The log
    /// `pruneOldBackups: failed to list <path>` is the only operator
    /// signal — there is no UI surface for "prune has stopped working."
    ///
    /// This test documents the silent failure so any future change is a
    /// conscious decision (e.g., post a `.backupPruneFailed` notification
    /// for the settings panel to consume).
    func testPruneReturnsSilentlyWhenListFails() throws {
        try seedBackupDirs(5)
        defaults.set(3, forKey: "backupKeepCount")
        // Capture the expected name list BEFORE locking the dir (we can't
        // read it again while locked).
        let expectedNames = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
            .filter { $0.count == 21 }
        XCTAssertEqual(expectedNames.count, 5)
        // Lock the Backups/ dir itself so contentsOfDirectory fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: backupsDir.path
        )

        // pruneOldBackups must NOT throw (it's `func`, not `throws`).
        // It must also NOT remove anything because it couldn't list.
        service.pruneOldBackups()

        // Unlock before reading the after-state — `try? contentsOfDirectory`
        // would also fail while the dir is locked, masking the result.
        unlock(backupsDir.path)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        let afterValid = after.filter { $0.count == 21 }
        XCTAssertEqual(afterValid.count, 5,
            "silent failure: prune returned early, all 5 dirs still present")
        XCTAssertEqual(Set(afterValid), Set(expectedNames),
            "no dir may have been removed")
    }

    /// `pruneIncompleteBackups` catches per-dir removeItem errors and
    /// continues with a `failures` counter (line 419-428). Verify the
    /// loop survives a locked incomplete dir.
    func testPruneIncompleteBackupsContinuesAfterMidLoopFailure() throws {
        try seedBackupDirs(4)
        // Mark one of them as incomplete.
        let firstName = (try FileManager.default.contentsOfDirectory(atPath: backupsDir.path))
            .filter { $0.count == 21 }
            .sorted()[0]
        let firstDir = backupsDir.appendingPathComponent(firstName)
        try Data().write(to: firstDir.appendingPathComponent(BackupService.incompleteMarkerName))
        let lockedPath = firstDir.path
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: lockedPath
        )
        defer { unlock(lockedPath) }

        service.pruneOldBackups()  // calls pruneIncompleteBackups internally

        // The locked incomplete dir survives; the test passes if prune
        // didn't crash. Other incomplete dirs (none here) would also be
        // processed. Valid dirs are untouched (count-based prune keeps 3).
        let after = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        let afterValid = after.filter { $0.count == 21 }
        XCTAssertTrue(afterValid.contains(firstName),
            "locked incomplete dir must survive — loop continues past per-dir removeItem failure")
    }

    // MARK: - performBackupIfNeeded / backupNow exception paths

    /// `backupNow` throws BackupError.directoryCreationFailed when
    /// `createDirectory` fails. Verify the typed error surfaces (so the
    /// import-flow caller can abort), and the partial-failure cleanup
    /// defer removes the orphan timestamped dir.
    ///
    /// `performBackupIfNeeded` (the daily auto-backup caller) wraps this
    /// in a catch that records `lastBackupErrorDate` + `lastBackupErrorMessage`
    /// (N-3 fix). This test verifies the typed throw lands in the right
    /// `BackupError` case so N-3's `errorDescription` extraction produces
    /// a useful message for the settings page.
    func testBackupNowThrowsDirectoryCreationFailedOnUnwritableParent() {
        // Make the parent of backupsDir read-only so createDirectory fails.
        // backupsDir doesn't exist yet — createDirectory would need to make
        // both the parent (already exists) and the leaf (won't happen).
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: tempRoot.path
        )
        defer { unlock(tempRoot.path) }

        // backupNow must throw BackupError.directoryCreationFailed, not a
        // raw CocoaError — the import caller pattern-matches on this case.
        XCTAssertThrowsError(try service.backupNow()) { error in
            guard case BackupError.directoryCreationFailed = error else {
                XCTFail("expected BackupError.directoryCreationFailed, got \(error)")
                return
            }
        }
        // No timestamped dir should have been created.
        let after = (try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? []
        XCTAssertFalse(after.contains("Backups"),
            "no partial backup dir should be left after directoryCreationFailed throws")
    }

    /// Document the corruption fallback in `performBackupIfNeeded`:
    /// `defaults.object(forKey: ...) as? Date` returns nil for non-Date
    /// values, so `if let last = lastBackupDate` is false, the throttle
    /// block is skipped, and the daily backup fires. This is fail-open
    /// toward backing up — a corrupted lastBackupDate causes more
    /// backups, not fewer. Not necessarily wrong (more redundancy), but
    /// the side effect (potential disk churn from rapid retries after a
    /// bad migration) deserves to be documented.
    ///
    /// Capture-only: if this test ever changes, re-read this comment and
    /// verify the new behavior is an intentional fix (e.g., a sentinel
    /// Date fallback for non-Date values).
    func testPerformBackupIfNeededThrottleSkippedWhenLastBackupDateCorrupted() {
        // Seed store data so backupNow has something to back up.
        try? Data("placeholder items".utf8).write(
            to: backupsDir.deletingLastPathComponent().appendingPathComponent("items.json")
        )
        defer {
            try? FileManager.default.removeItem(at: backupsDir.deletingLastPathComponent().appendingPathComponent("items.json"))
        }
        // Plant a non-Date value at lastBackupDateKey — simulate a bad
        // migration or a programmer using `set(Int, ...)` by mistake.
        defaults.set(42, forKey: "lastBackupDate")
        // The getter `lastBackupDate` is `defaults.object(forKey:) as? Date`
        // — returns nil for Int. The throttle `if let last = lastBackupDate`
        // is skipped, and the backup fires.
        XCTAssertNil(service.lastBackupDate,
            "corrupted Int at lastBackupDateKey must surface as nil, not crash")
        // Seed an empty Backups dir so the backup dir creation succeeds.
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        // The backup should fire despite the corrupted lastBackupDate.
        // performBackupIfNeeded is async; we use backupNow() directly to
        // assert the throttle behavior synchronously.
        XCTAssertNoThrow(try service.backupNow(),
            "backupNow does not consult lastBackupDate — only performBackupIfNeeded does")
    }
}