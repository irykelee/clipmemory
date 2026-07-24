import XCTest
@testable import ClipMemory

/// BKP-1 (2026-07-24): `.incomplete` marker removal failure must be treated
/// as a backup failure, not swallowed with `try?`.
///
/// The bug: `performBackupUnlocked` finished writing all blobs + Images, then
/// removed the marker with `try?`. When that removal failed (permissions,
/// disk error), the fully-written backup KEPT its `.incomplete` marker — and
/// the next `pruneOldBackups()` unconditionally deletes marker-carrying dirs
/// as crash leftovers (H-6), silently destroying a good backup.
///
/// Triggering the failure deterministically needs a seam: `BackupService`
/// now takes an injectable `FileManager` (same DI style as its paths and
/// UserDefaults). The double below fails only when asked to remove the
/// `.incomplete` marker; everything else delegates to the real implementation.
final class BackupIncompleteMarkerTests: XCTestCase {

    private final class MarkerRemovalFailingFileManager: FileManager {
        override func removeItem(at url: URL) throws {
            if url.lastPathComponent == BackupService.incompleteMarkerName {
                throw NSError(
                    domain: "BackupIncompleteMarkerTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "simulated marker removal failure"]
                )
            }
            try super.removeItem(at: url)
        }
    }

    private var tempRoot: URL!
    private var backupsDir: URL!
    private var imagesDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupIncompleteMarkerTests-\(UUID().uuidString)", isDirectory: true)
        backupsDir = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        suiteName = "BackupIncompleteMarkerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName = suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        backupsDir = nil
        imagesDir = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func seedStoreData() {
        let item = ClipboardItem(content: "marker-bkp1", type: .text)
        defaults.set(try? JSONEncoder().encode([item]), forKey: "ClipboardItems")
    }

    /// Core regression: marker removal failure must surface as a thrown
    /// `BackupError.markerRemovalFailed`, must NOT advance `lastBackupDate`
    /// (so the next launch retries), and the partial-failure defer must
    /// remove the timestamped dir so no marker-carrying dir survives to be
    /// misread by a later prune.
    func testMarkerRemovalFailureIsTreatedAsBackupFailure() {
        let service = BackupService(
            backupsDirectory: backupsDir,
            imagesDirectory: imagesDir,
            defaults: defaults,
            fileManager: MarkerRemovalFailingFileManager()
        )
        seedStoreData()

        XCTAssertThrowsError(try service.backupNow()) { error in
            guard case BackupError.markerRemovalFailed = error else {
                XCTFail("expected BackupError.markerRemovalFailed, got \(error)")
                return
            }
        }

        XCTAssertNil(
            service.lastBackupDate,
            "BKP-1: failed backup must not advance lastBackupDate (next launch must retry)"
        )
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path)) ?? []
        XCTAssertEqual(
            remaining, [],
            "BKP-1: no dir carrying a stale .incomplete marker may survive — it would be pruned as a crash leftover next time"
        )
    }

    /// A failed backup must not poison the NEXT backup: with a healthy
    /// FileManager the retry succeeds and leaves a valid, marker-free dir.
    func testBackupAfterMarkerFailureSucceedsWithHealthyFileManager() throws {
        let failing = BackupService(
            backupsDirectory: backupsDir,
            imagesDirectory: imagesDir,
            defaults: defaults,
            fileManager: MarkerRemovalFailingFileManager()
        )
        seedStoreData()
        XCTAssertThrowsError(try failing.backupNow())

        let healthy = BackupService(
            backupsDirectory: backupsDir,
            imagesDirectory: imagesDir,
            defaults: defaults
        )
        let dir = try healthy.backupNow()
        XCTAssertNotNil(healthy.lastBackupDate)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(".incomplete").path),
            "recovered backup must be a valid, marker-free dir"
        )
    }

    /// Guard the success path against over-correction: with the default
    /// FileManager the marker removal still succeeds and no error is thrown.
    func testSuccessfulBackupRemovesMarkerWithoutThrowing() throws {
        let service = BackupService(
            backupsDirectory: backupsDir,
            imagesDirectory: imagesDir,
            defaults: defaults
        )
        seedStoreData()
        let dir = try service.backupNow()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(".incomplete").path)
        )
        XCTAssertNotNil(service.lastBackupDate)
    }
}
