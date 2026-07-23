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
        for i in 0..<5 {
            let name = String(format: "2026-07-%02d_120000", 14 + i)
            try? FileManager.default.createDirectory(
                at: backupsDir.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        service.pruneOldBackups()
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(remaining.min(), "2026-07-16_120000", "oldest two must be pruned")
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
        // Block the next backup dir by placing a regular file at the
        // timestamped path. createDirectory(withIntermediateDirectories:)
        // throws when the parent path collides with a non-directory.
        let blocker = backupsDir.appendingPathComponent("2026-07-23_120000")
        try? "blocker".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }
        XCTAssertThrowsError(try service.backupNow()) { error in
            guard case BackupError.directoryCreationFailed = error else {
                XCTFail("expected BackupError.directoryCreationFailed, got \(error)")
                return
            }
        }
    }

    func testBackupNowDoesNotMutateStateOnFailure() throws {
        seedStoreData()
        // Establish a baseline successful backup so lastBackupDate is populated
        // and a backup dir exists on disk.
        _ = try service.backupNow()
        XCTAssertNotNil(service.lastBackupDate)
        let preDate = service.lastBackupDate
        let preEntries = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []

        // Force next backup to throw at createDirectory with the same blocker
        // pattern. The failed call must NOT advance lastBackupDate (that
        // assignment sits AFTER all try blocks) and must NOT leave a
        // partially-written backup directory.
        let blocker = backupsDir.appendingPathComponent("2026-07-23_999999")
        try? "blocker".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }

        XCTAssertThrowsError(try service.backupNow())
        XCTAssertEqual(service.lastBackupDate, preDate, "lastBackupDate must not advance on failed backup")
        let postEntries = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(postEntries, preEntries, "no partial backup dir should appear on disk")
    }
}
