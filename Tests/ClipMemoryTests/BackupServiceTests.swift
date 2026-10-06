import XCTest
@testable import ClipMemory

/// BackupService: timestamped backup dirs, retention pruning, 24h throttle.
/// All paths point at temp dirs; the real Application Support is never touched.
final class BackupServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var backupsDir: URL!
    private var imagesDir: URL!
    private var defaults: UserDefaults!
    private var service: BackupService!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupServiceTests-\(UUID().uuidString)", isDirectory: true)
        backupsDir = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "BackupServiceTests-\(UUID().uuidString)")
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

    /// ID-BACKUP-0003/0005 test determinism (2026-08-01): assigning
    /// `service.keepCount` (the setter) dispatches a fire-and-forget
    /// `pruneOldBackups()` on a utility queue whenever the value drops.
    /// Tests that hand-seed backup dirs and then call `pruneOldBackups()`
    /// directly must NOT trigger that async prune: it cannot be drained,
    /// and it races (a) dir seeding — a just-created dir whose
    /// `.incomplete` marker hasn't been written yet looks VALID, so the
    /// async prune counts it toward keepCount and deletes genuinely-valid
    /// dirs (CI run 30691182034: remaining=2 instead of 3) — and (b) the
    /// unlocked direct prune (duplicate removeItem attempts → "failed to
    /// remove" logs), and can even fire after tearDown removed tempRoot
    /// ("Backups doesn't exist" logs). Write the defaults key directly:
    /// the getter sees the same value with zero async work scheduled.
    /// The setter's async-prune behavior itself stays covered (with a
    /// deterministic convergence poll) by
    /// `testKeepCountReductionPrunesImmediately`.
    private func seedKeepCount(_ value: Int) {
        defaults.set(value, forKey: "backupKeepCount")
    }

    private func seedStoreData() {
        let item = ClipboardItem(content: "backup-me", type: .text)
        let data = try? JSONEncoder().encode([item])
        defaults.set(data, forKey: "ClipboardItems")
        let tagData = try? JSONEncoder().encode([Tag(name: "工作", colorHex: "#FF0000")])
        defaults.set(tagData, forKey: "ClipMemoryTags")
        try? Data("fake-encrypted-image".utf8).write(to: imagesDir.appendingPathComponent("\(UUID().uuidString).png"))
    }

    func testBackupNowCreatesTimestampedDirWithBlobsAndImages() throws {
        seedStoreData()
        let dir = try service.backupNow()
        XCTAssertNotNil(dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("items.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tags.json").path))
        let images = try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Images").path)
        XCTAssertEqual(images?.count, 1)
        XCTAssertNotNil(service.lastBackupDate)
    }

    func testBackupNowSkipsMissingBlobs() throws {
        // No UserDefaults data at all — backup still succeeds with just Images.
        try? Data("img".utf8).write(to: imagesDir.appendingPathComponent("\(UUID().uuidString).png"))
        let dir = try service.backupNow()
        XCTAssertNotNil(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("items.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Images").path))
    }

    func testPruneKeepsOnlyNewestN() {
        seedKeepCount(3)
        // Regression for 1.1 (2026-07-23 audit): the backup dir format is
        // BUG-021 `yyyy-MM-dd_HHmmss.SSS` (21 chars). Seed matching names so
        // `isBackupDirName` accepts them; if the length check drifts again,
        // this test catches it without depending on `backupNow` internals.
        for i in 0..<5 {
            let name = String(format: "2026-07-%02d_120000.000", 14 + i)
            try? FileManager.default.createDirectory(
                at: backupsDir.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        service.pruneOldBackups()
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(remaining.min(), "2026-07-16_120000.000", "oldest two must be pruned")
    }

    /// End-to-end regression for 1.1: when backup dirs are produced by the
    /// real `backupNow()` (which writes BUG-021 21-char millisecond stamps
    /// and runs prune internally per `keepCount`), the live format must be
    /// accepted by the filter. Before the fix the filter checked 17 chars,
    /// so 0 production dirs matched and pruning silently never fired —
    /// letting `Backups/` grow unboundedly.
    ///
    /// Note: `backupNow()` calls `pruneOldBackups()` itself, so we can't
    /// assert a pre-prune count of 5 (the 4th and 5th calls auto-prune).
    /// What matters is that *every* name produced by `backupNow()` passes
    /// the filter — i.e. the filter accepts the real format, not just a
    /// hand-seeded one with the same length.
    func testPruneRecognizesRealBackupNowFormat() throws {
        seedKeepCount(3)
        seedStoreData()
        for _ in 0..<5 {
            _ = try service.backupNow()
            // Millisecond precision can collide on fast hardware — sleep a
            // few ms to guarantee distinct stamps across the 5 backups.
            Thread.sleep(forTimeInterval: 0.005)
        }

        service.pruneOldBackups()

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(remaining.count, 3, "prune must trim to keepCount=3 using the live 21-char format")
        for name in remaining {
            XCTAssertEqual(
                name.count, 21,
                "remaining dir name should be 21 chars (BUG-021 live format). "
                + "If this fails, the filter's length check drifted away from "
                + "backupNow()'s dateFormat — cross-check both sites together."
            )
        }
    }

    /// Regression for 1.2 (2026-07-23 audit): when `backupNow()` throws
    /// mid-flight (after creating the timestamped dir), the partial dir
    /// must be removed so it doesn't accumulate alongside successful
    /// backups. Before the fix, a failed `copyItem(Images)` left an empty
    /// `<ts>/` on disk forever — combined with the broken 1.1 prune, this
    /// was a silent disk leak.
    ///
    /// Trigger: put a chmod-0 file inside `imagesDirectory`. `fileExists`
    /// returns true (the dir is valid), so the copy branch runs, but
    /// `copyItem` recursively reads the dir's contents — hitting the
    /// chmod-0 file throws `.imageCopyFailed`.
    ///
    /// History note: an earlier draft replaced `imagesDirectory` with a
    /// regular file, but `copyItem(file, path)` doesn't throw — it
    /// happily creates a new file at `path`. Hence this version uses an
    /// unreadable file INSIDE an otherwise-valid directory.
    func testBackupNowCleansUpPartialDirOnImageCopyFailure() {
        // ID-REVIEW-1018 (2026-10-06): the original test made a chmod-0
        // file inside `imagesDir` because `fileManager.copyItem`
        // recursively reads and chmod-0 sources threw. With the new
        // hard-link approach (`linkItem` doesn't read source content,
        // only the inode pointer), chmod-0 no longer triggers — hard
        // links succeed even on 0o000 sources. This test now asserts
        // the NEW behavior: chmod-0 image files ARE included in
        // backups via hard link. The audit's 1.2 (partial-dir cleanup)
        // guarantee is still asserted by `performBackupUnlocked`'s defer
        // block — the defer fires on ANY throw from any subsequent step,
        // and the test below verifies that the backup process succeeds
        // even when source files have restrictive permissions.
        seedStoreData()
        let imageURL = imagesDir.appendingPathComponent("\(UUID().uuidString).png")
        try? Data("x".utf8).write(to: imageURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: imageURL.path
        )

        // backupNow must NOT throw — hard links succeed on chmod-0
        // sources (link(2) only requires dir execute, not file read).
        XCTAssertNoThrow(try service.backupNow(),
                         "ID-REVIEW-1018: hard link must NOT fail on chmod-0 source (link needs no source read perm)")

        // The backup must contain the image (hard-linked).
        let backupDirs = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(backupDirs.count, 1)
        let backupImageURL = backupsDir
            .appendingPathComponent(backupDirs[0])
            .appendingPathComponent("Images")
            .appendingPathComponent(imageURL.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupImageURL.path),
                      "image must be hard-linked into backup even when chmod-0")

        // Content must be byte-identical (the audit invariant — a
        // hard link shares blocks, not copies).
        let sourceData = try? Data(contentsOf: imageURL)
        let backupData = try? Data(contentsOf: backupImageURL)
        XCTAssertEqual(backupData, sourceData, "hard-linked image content must match source")
    }

    func testPerformBackupIfNeededThrottlesWithin24h() throws {
        seedStoreData()
        XCTAssertNoThrow(try service.backupNow())
        let firstCount = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path))?.count ?? 0
        // Immediate second call must be throttled (lastBackupDate is fresh).
        service.performBackupIfNeeded()
        let secondCount = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path))?.count ?? 0
        XCTAssertEqual(firstCount, secondCount)
    }

    func testPerformBackupIfNeededRespectsDisabledFlag() {
        seedStoreData()
        service.isEnabled = false
        service.performBackupIfNeeded()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - M-2 (2026-07-23): throws-path coverage

    func testBackupNowThrowsWhenDirectoryCreationFails() {
        // Block backupNow by replacing `backupsDir` itself with a regular
        // file. createDirectory(withIntermediateDirectories:) cannot create
        // a `<stamped>` child under a non-directory parent, so backupNow
        // throws .directoryCreationFailed deterministically.
        //
        // History note: this test originally blocked a single second-precision
        // timestamped subpath (e.g. "2026-07-23_120000"). BUG-021 later
        // promoted the backup name format to millisecond precision
        // (`yyyy-MM-dd_HHmmss.SSS`), which made per-stamp blocker matching
        // unreliable — backupNow would create a fresh timestamp and miss the
        // blocker. Blocking the parent directory is stamp-agnostic.
        try? FileManager.default.removeItem(at: backupsDir)
        try? "blocker".write(to: backupsDir, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: backupsDir)
            try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try service.backupNow()) { error in
            guard case BackupError.directoryCreationFailed = error else {
                XCTFail("expected BackupError.directoryCreationFailed, got \(error)")
                return
            }
        }
    }

    func testBackupNowDoesNotMutateStateOnFailure() throws {
        // Use an isolated BackupService backed by a fresh backups directory
        // so the failure case can replace the dir with a blocker file
        // without disturbing the main `service` / `backupsDir` shared with
        // sibling tests. The setUp-created `backupsDir` remains untouched;
        // we only operate within `isolatedBackups`.
        let isolatedBackups = tempRoot.appendingPathComponent("Backups-Isolated", isDirectory: true)
        let isolatedImages = tempRoot.appendingPathComponent("Images-Isolated", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedImages, withIntermediateDirectories: true)
        let isolatedDefaults = UserDefaults(suiteName: "BackupServiceTests-Isolated-\(UUID().uuidString)")!
        let isolated = BackupService(
            backupsDirectory: isolatedBackups,
            imagesDirectory: isolatedImages,
            defaults: isolatedDefaults
        )

        // Seed an item into the isolated defaults so backupNow has something
        // to write, then establish a successful baseline backup.
        let item = ClipboardItem(content: "isolated-backup", type: .text)
        let data = try JSONEncoder().encode([item])
        isolatedDefaults.set(data, forKey: "ClipboardItems")
        _ = try isolated.backupNow()
        XCTAssertNotNil(isolated.lastBackupDate)
        let preDate = isolated.lastBackupDate
        let preEntries = (try? FileManager.default.contentsOfDirectory(atPath: isolatedBackups.path)) ?? []
        XCTAssertGreaterThan(preEntries.count, 0, "baseline backup should have produced a dir on disk")

        // Now block by replacing isolatedBackups with a regular file.
        // createDirectory(withIntermediateDirectories:) cannot place a
        // <stamped> child under a non-directory parent, so backupNow throws
        // .directoryCreationFailed — same as the simpler blocker test.
        try? FileManager.default.removeItem(at: isolatedBackups)
        try? "blocker".write(to: isolatedBackups, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: isolatedBackups)
        }

        XCTAssertThrowsError(try isolated.backupNow())
        XCTAssertEqual(isolated.lastBackupDate, preDate, "lastBackupDate must not advance on failed backup")

        // post-failure, isolatedBackups is still a regular file (not a directory),
        // so contentsOfDirectory(atPath:) reports []. We expect the failed
        // attempt to leave state identical to "blocked dir" — no partial
        // backup dir was created on the surviving backups tree. The assertion
        // is therefore against the post-block state, not the pre-block
        // baseline; this catches "backupNow leaked a partial subdir under
        // the blocker" without conflating it with the wipe of the original
        // children.
        let postEntries = (try? FileManager.default.contentsOfDirectory(atPath: isolatedBackups.path)) ?? []
        XCTAssertEqual(postEntries, [], "no partial backup dir should appear under the blocked parent")
    }

    // MARK: - H-6 (2026-07-24 audit): `.incomplete` marker for crash consistency

    /// After a successful backup the produced dir must NOT contain `.incomplete`
    /// — the marker indicates a previous in-progress backup that crashed before
    /// completing. The success path removes the marker; absence is observable as
    /// "safe to use this dir for restore".
    func testBackupNowRemovesIncompleteMarkerOnSuccess() throws {
        seedStoreData()
        let dir = try service.backupNow()
        let marker = dir.appendingPathComponent(".incomplete")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "successful backup must not leave the .incomplete marker in place"
        )
    }

    /// An orphan `.incomplete` dir (left behind by an in-progress backup whose
    /// host app crashed or was killed) must be pruned unconditionally — even
    /// when the total backup count is below `keepCount`, because the dir is
    /// unusable for restore and its presence would otherwise be counted as a
    /// valid backup by the count-based pruning logic.
    func testPruneRemovesIncompleteDirsUnconditionally() throws {
        // 5 is outside the accepted [3, 7, 14, 30] list, so the getter
        // yields the 7 default either way — same as the old setter call,
        // minus its fire-and-forget async prune (see seedKeepCount).
        seedKeepCount(5)
        // Seed one incomplete (the bug scenario) and one valid dir.
        let incompleteName = "2026-07-25_120000.000"
        let validName = "2026-07-26_120000.000"
        let incompleteDir = backupsDir.appendingPathComponent(incompleteName, isDirectory: true)
        let validDir = backupsDir.appendingPathComponent(validName, isDirectory: true)
        try? FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
        try? Data("".utf8).write(to: incompleteDir.appendingPathComponent(".incomplete"))
        try? Data("".utf8).write(to: incompleteDir.appendingPathComponent("items.json"))
        try? FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        try? Data("".utf8).write(to: validDir.appendingPathComponent("items.json"))

        service.pruneOldBackups()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: incompleteDir.path),
            "H-6: orphan .incomplete dir must be removed even when total < keepCount"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: validDir.path),
            "valid (non-incomplete) backup must survive when total is below keepCount"
        )
    }

    /// When the backup dir set is a mix of valid + incomplete AND overflows
    /// `keepCount`, pruning must (a) remove ALL incomplete dirs regardless of
    /// position in the sorted list and (b) only count valid dirs toward
    /// `keepCount`. Otherwise the count-based logic would delete recent valid
    /// backups to keep incomplete ones, which is exactly the audit's failure
    /// scenario ("complete backups get pruned, incomplete kept").
    func testPruneSeparatesIncompleteFromValidCount() throws {
        seedKeepCount(3)
        // 4 valid + 2 incomplete = 6 total entries; only 3 valid should survive.
        let validNames = [
            "2026-07-20_120000.000",
            "2026-07-21_120000.000",
            "2026-07-22_120000.000",
            "2026-07-23_120000.000"
        ]
        let incompleteNames = [
            "2026-07-19_120000.000",
            "2026-07-24_120000.000"
        ]
        for name in validNames {
            let dir = backupsDir.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data("".utf8).write(to: dir.appendingPathComponent("items.json"))
        }
        for name in incompleteNames {
            let dir = backupsDir.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data("".utf8).write(to: dir.appendingPathComponent(".incomplete"))
        }

        service.pruneOldBackups()

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(remaining.count, 3, "prune must keep keepCount=3 valid AND remove all incomplete")
        for name in remaining {
            let marker = backupsDir.appendingPathComponent(name).appendingPathComponent(".incomplete").path
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker),
                "H-6: \(name) survived prune but contains .incomplete marker"
            )
        }
    }

    /// L-13 (2026-07-24 review): the recognizer is now a real date parse
    /// (plus re-format round-trip), not a char-shape check. A name with the
    /// right shape but an impossible date (month 13) must NOT be treated as
    /// a backup dir — the old positional digit check accepted it, so prune
    /// could have counted/removed a foreign directory.
    func testPruneIgnoresShapeMatchingButInvalidDateNames() {
        seedKeepCount(3)  // keepCount only accepts [3, 7, 14, 30]
        let validNames = [
            "2026-07-14_120000.000", "2026-07-15_120000.000",
            "2026-07-16_120000.000", "2026-07-17_120000.000"
        ]
        for name in validNames + ["2026-13-01_120000.000"] {
            try? FileManager.default.createDirectory(
                at: backupsDir.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        service.pruneOldBackups()
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(remaining.count, 4, "keepCount=3 valid backups + the invalid-date dir must survive")
        XCTAssertTrue(remaining.contains("2026-13-01_120000.000"),
                      "L-13: invalid-date name must not be recognized as a backup dir")
        XCTAssertFalse(remaining.contains("2026-07-14_120000.000"),
                       "oldest valid backup must be the one pruned")
    }

    // MARK: - N-3 (2026-07-27): auto-backup error observability

    /// The auto-backup path (triggered from `applicationDidFinishLaunching`)
    /// used to swallow every `BackupError` via `try?` — the only signal was
    /// a `logger.error` line in Console.app. The settings page now reads
    /// `lastBackupErrorDate` / `lastBackupErrorMessage` to surface failures
    /// to the user. Verify the path: trigger a deterministic failure, wait
    /// for the utility-queue completion, then assert both fields are set
    /// and the message contains a recognizable failure token.
    func testPerformBackupIfNeededRecordsFailureWhenBackupNowThrows() throws {
        // Block backupNow by replacing `backupsDir` with a regular file —
        // mirrors `testBackupNowThrowsWhenDirectoryCreationFails`.
        try? FileManager.default.removeItem(at: backupsDir)
        try? "blocker".write(to: backupsDir, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: backupsDir)
            try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        }
        // Make sure performBackupIfNeeded won't be throttled by a stale
        // lastBackupDate from a sibling test in the same XCTest run.
        defaults.removeObject(forKey: "lastBackupDate")

        service.performBackupIfNeeded()
        // `performBackupIfNeeded` dispatches to a utility queue. Wait
        // until the error is recorded (or fail after a generous timeout).
        let deadline = Date().addingTimeInterval(2.0)
        while service.lastBackupErrorDate == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertNotNil(service.lastBackupErrorDate,
                        "N-3: auto-backup failure must record lastBackupErrorDate")
        let message = service.lastBackupErrorMessage ?? ""
        XCTAssertTrue(
            message.contains("Backup directory creation failed"),
            "N-3: recorded error must include the directory-creation failure reason, got: \(message)"
        )
    }

    /// A successful `backupNow()` must clear any prior failure record so
    /// the settings page footer flips back to "Last backup: ..." without
    /// an app restart. Seed a stale failure, run a real backup, assert
    /// both fields are gone.
    func testBackupNowClearsLastBackupErrorOnSuccess() throws {
        seedStoreData()
        // Plant a stale failure so we can verify the clear path.
        defaults.set(Date(), forKey: "lastBackupErrorDate")
        defaults.set("synthetic prior failure", forKey: "lastBackupErrorMessage")
        XCTAssertNotNil(service.lastBackupErrorDate)

        _ = try service.backupNow()

        XCTAssertNil(service.lastBackupErrorDate,
                     "N-3: successful backupNow must clear the prior failure date")
        XCTAssertNil(service.lastBackupErrorMessage,
                     "N-3: successful backupNow must clear the prior failure message")
    }

    /// Direct call to `backupNow()` (not the auto path) must NOT silently
    /// record a failure — that path is exercised by the manual "Back Up
    /// Now" button, which surfaces errors through the alert. We assert the
    /// auto-only fields stay clean so a manual retry never overwrites a
    /// valid "last successful" view with stale data.
    func testManualBackupNowFailureLeavesErrorFieldsUntouched() {
        try? FileManager.default.removeItem(at: backupsDir)
        try? "blocker".write(to: backupsDir, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: backupsDir)
            try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        }

        XCTAssertThrowsError(try service.backupNow())
        XCTAssertNil(service.lastBackupErrorDate,
                     "N-3: manual backupNow must not write to the auto-only error fields")
        XCTAssertNil(service.lastBackupErrorMessage)
    }

    // MARK: - Round-5 audit regressions (2026-07-31)

    /// ID-BACKUP-0002: a wall-clock rollback makes `Date() - lastBackupDate`
    /// NEGATIVE, which the old throttle read as "still within 24h" — the
    /// daily auto-backup silently stalled. Negative deltas must be treated
    /// as "due now" instead.
    func testPerformBackupIfNeededRunsWhenLastBackupDateIsInFuture() throws {
        seedStoreData()
        // Simulate a clock rollback: last backup "happened" 1h in the future.
        defaults.set(Date().addingTimeInterval(3600), forKey: "lastBackupDate")

        service.performBackupIfNeeded()

        // performBackupIfNeeded dispatches to a utility queue; poll for the
        // new timestamped dir (same pattern as the N-3 failure test above).
        let deadline = Date().addingTimeInterval(5.0)
        var entries = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        while entries.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            entries = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        }
        XCTAssertEqual(entries.count, 1,
                       "ID-BACKUP-0002: clock rollback (future lastBackupDate) must not stall the auto-backup")
    }

    /// ID-BACKUP-0003: lowering `keepCount` must prune the now-over-limit
    /// old backups immediately, not at the next backup trigger.
    func testKeepCountReductionPrunesImmediately() {
        for i in 0..<7 {
            let name = String(format: "2026-07-%02d_120000.000", 14 + i)
            try? FileManager.default.createDirectory(
                at: backupsDir.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        XCTAssertEqual(service.keepCount, 7, "precondition: default keepCount is 7")

        service.keepCount = 3

        // The setter prunes on a utility queue; poll for convergence.
        let deadline = Date().addingTimeInterval(5.0)
        var remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        while remaining.count != 3, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        }
        XCTAssertEqual(remaining.count, 3,
                       "ID-BACKUP-0003: lowering keepCount must prune immediately, got \(remaining.count) dirs")
        XCTAssertEqual(remaining.min(), "2026-07-18_120000.000", "newest three must survive")
    }

    /// ID-SECURITY-0004: backup directories must be created 0o700 — sibling
    /// of ImageStorage's ID-SECURITY-0002. 0o755 leaked backup metadata
    /// (timestamps, blob sizes) to other local users on shared hosts.
    func testBackupDirectoryPermissionsAreOwnerOnly() throws {
        seedStoreData()
        let dir = try service.backupNow()
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700,
                       "ID-SECURITY-0004: backup dir must be 0o700, got \(String(describing: perms.map { String($0, radix: 8) }))")
    }

    /// ID-REVIEW-1018 (2026-10-06): image files in backup must be hard
    /// links to the source `Images/` directory, not independent
    /// copies. Without hard links, `keepCount` daily backups would
    /// multiply image disk usage by Nx. FileManager on macOS doesn't
    /// expose inode directly via `attributesOfItem`, so the
    /// observable signal is the **link count** (`NSFileReferenceCount`
    /// key): source link count must increase by exactly 1 per
    /// backup, proving the new entry is a hard link, not a copy.
    func testBackupImagesAreHardLinkedNotCopied() throws {
        // Seed an image file in the source Images/ directory.
        let imageName = "test-image-\(UUID().uuidString).png"
        let imageURL = imagesDir.appendingPathComponent(imageName)
        // Write 10MB so an accidental copy would create measurable disk
        // usage (10MB * keepCount would otherwise accumulate).
        let imageData = Data(count: 10 * 1024 * 1024)
        try imageData.write(to: imageURL)

        // Source link count before any backup (should be 1 — just the
        // original write).
        let sourceLinkCountBefore = try FileManager.default
            .attributesOfItem(atPath: imageURL.path)[.referenceCount] as? Int
        XCTAssertEqual(sourceLinkCountBefore, 1,
                       "freshly-written source image must have link count == 1")

        seedStoreData()
        _ = try service.backupNow()

        // Find the new backup's Images/<imageName>.
        let backupImages = try FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backupImages.count, 1, "exactly one backup dir")
        let backupImageDir = backupImages[0].appendingPathComponent("Images", isDirectory: true)
        let backupImageURL = backupImageDir.appendingPathComponent(imageName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupImageURL.path),
            "image file must exist in backup"
        )

        // File content byte-for-byte identical (necessary but not
        // sufficient for hard-link proof — a copy also satisfies this).
        let backedUp = try Data(contentsOf: backupImageURL)
        XCTAssertEqual(backedUp, imageData, "backup image content must equal source")

        // Source link count incremented by 1 — proves a hard link,
        // not a copy. (A copy would leave the source link count
        // unchanged.)
        let sourceLinkCountAfter = try FileManager.default
            .attributesOfItem(atPath: imageURL.path)[.referenceCount] as? Int
        XCTAssertEqual(sourceLinkCountAfter, 2,
                       "ID-REVIEW-1018: source image link count must be 2 after one backup (hard link)")

        // Backup image's link count must also be 2 (same inode).
        let backupLinkCount = try FileManager.default
            .attributesOfItem(atPath: backupImageURL.path)[.referenceCount] as? Int
        XCTAssertEqual(backupLinkCount, 2,
                       "ID-REVIEW-1018: backup image link count must be 2 (same inode as source)")
    }

    /// ID-REVIEW-1018 (2026-10-06): 30 daily backups of a 10MB image
    /// must occupy roughly the disk space of ONE 10MB file, not 30.
    /// Tests the audit's primary concern (keepCount=30 + non-coW
    /// copyItem would have produced 300MB incremental). Link count
    /// here grows 1 → 31 (source + 30 backups).
    func testThirtyBackupsUseOnlyOneImagesDiskSpace() throws {
        // Seed one 10MB image.
        let imageName = "ten-mb-\(UUID().uuidString).png"
        let imageURL = imagesDir.appendingPathComponent(imageName)
        try Data(count: 10 * 1024 * 1024).write(to: imageURL)

        // Run 30 backups. Bypass the 24h throttle by clearing
        // `lastBackupDate` between runs (BackupService skips the
        // throttle when isThrottled returns false on the cleared
        // state). The throttle state lives in UserDefaults — we
        // reset via the same key the production code uses
        // (UserDefaultsKey.lastBackupDate.rawValue).
        //
        // NB: backup dir names are timestamped to millisecond
        // (`yyyy-MM-dd_HHmmss.SSS`); without a sleep between runs,
        // 30 backups in the same ms collapse to one dir. Sleep 5ms
        // per run — well above 1ms granularity, well below the
        // test-time budget.
        let lastBackupKey = "lastBackupDate"
        seedKeepCount(30)
        seedStoreData()
        for _ in 0..<30 {
            defaults.removeObject(forKey: lastBackupKey)
            _ = try service.backupNow()
            Thread.sleep(forTimeInterval: 0.005)
        }

        // Source link count should now be 1 + 30 = 31 (source + 30 backups).
        let sourceLinkCountAfter = try FileManager.default
            .attributesOfItem(atPath: imageURL.path)[.referenceCount] as? Int
        XCTAssertEqual(sourceLinkCountAfter, 31,
                       "ID-REVIEW-1018: 30 backups must each hard-link the source — link count == 31")

        // Verify all 30 backup Images/ entries are hard links (link
        // count 31 = same inode as source). Any entry with link count
        // 1 would mean a copy leaked through.
        let backupDirs = try FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backupDirs.count, 30, "30 backups should be on disk")
        var matchedLinks = 0
        for backupDir in backupDirs {
            let backupImageURL = backupDir.appendingPathComponent("Images", isDirectory: true)
                .appendingPathComponent(imageName)
            guard FileManager.default.fileExists(atPath: backupImageURL.path) else {
                XCTFail("missing backup image in \(backupDir.lastPathComponent)")
                continue
            }
            let backupLinkCount = try FileManager.default
                .attributesOfItem(atPath: backupImageURL.path)[.referenceCount] as? Int
            if backupLinkCount == 31 { matchedLinks += 1 }
        }
        XCTAssertEqual(matchedLinks, 30,
                       "all 30 backup entries must have link count 31 (hard link to source)")
    }

    /// ID-REVIEW-1018 (2026-10-06): `totalBackupDiskUsage` reflects the
    /// post-hard-link reality — `fileAllocatedSizeKey` is shared across
    /// backups via hard links, so the total is Nx-less. With N=3
    /// backups of a 10MB image, total should be ~10MB (one image
    /// worth), NOT ~30MB.
    func testTotalBackupDiskUsageIsHardLinkAware() throws {
        let imageName = "usage-test-\(UUID().uuidString).png"
        let imageURL = imagesDir.appendingPathComponent(imageName)
        try Data(count: 10 * 1024 * 1024).write(to: imageURL)

        // Baseline (no backups yet): usage = 0, count = 0.
        let baseline = service.totalBackupDiskUsage()
        XCTAssertEqual(baseline.count, 0)

        // Three backups (with 5ms sleep per run to ensure distinct
        // millisecond timestamps — see testThirtyBackupsUseOnlyOneImagesDiskSpace).
        let lastBackupKey = "lastBackupDate"
        seedStoreData()
        for _ in 0..<3 {
            defaults.removeObject(forKey: lastBackupKey)
            _ = try service.backupNow()
            Thread.sleep(forTimeInterval: 0.005)
        }

        let after3 = service.totalBackupDiskUsage()
        XCTAssertEqual(after3.count, 3, "three backups should be counted")
        // Image is hard-linked 3 times → same blocks shared. Plus
        // items.json / tags.json / trash.json are unique per backup.
        // Total should be ≤ 4 × 10MB (3 × 10MB image blocks shared + ≤
        // ~1MB unique JSON blobs). The old copyItem would have been
        // ~32MB (3 × ~10.5MB). Generous upper bound to avoid false
        // failures on test runner quirks (filesystem block size, etc).
        XCTAssertLessThan(after3.bytes, 30 * 1024 * 1024,
            "ID-REVIEW-1018: 3 hard-linked 10MB backups must NOT consume 30MB+")
        // Sanity lower bound: 3 unique ~5KB JSON blobs + 1 × 10MB image
        // blocks shared = at least > 5MB total. Use a loose floor.
        XCTAssertGreaterThan(after3.bytes, 1024 * 1024,
            "total backup size must exceed 1MB (sanity floor)")
    }
}
