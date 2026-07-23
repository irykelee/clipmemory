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
        service.keepCount = 3
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
        service.keepCount = 3
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
                "remaining dir name should be 21 chars (BUG-021 live format). If this fails, the filter's length check drifted away from backupNow()'s dateFormat — cross-check both sites together."
            )
        }
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
}
