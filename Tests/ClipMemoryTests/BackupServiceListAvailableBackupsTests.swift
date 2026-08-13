import XCTest
@testable import ClipMemory

final class BackupServiceListAvailableBackupsTests: XCTestCase {
    var tmpDir: URL!
    var imagesDir: URL!
    var service: BackupService!
    let defaults = UserDefaults(suiteName: "test-list-available-\(UUID().uuidString)")!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-list-\(UUID().uuidString)", isDirectory: true)
        imagesDir = tmpDir.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        service = BackupService(backupsDirectory: tmpDir, imagesDirectory: imagesDir, defaults: defaults, fileManager: FileManager.default)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    /// Helper: creates a timestamped dir + (optionally) .incomplete marker.
    private func makeBackup(name: String, incomplete: Bool = false, files: [String: Data] = [:]) throws -> URL {
        let dir = tmpDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Always create Images/ subdirectory so countPNGs sees an empty dir → 0 (not nil).
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Images", isDirectory: true), withIntermediateDirectories: true)
        if incomplete {
            try Data().write(to: dir.appendingPathComponent(BackupService.incompleteMarkerName))
        }
        for (rel, data) in files {
            try data.write(to: dir.appendingPathComponent(rel))
        }
        return dir
    }

    func testEmptyBackupsDirectoryReturnsEmpty() throws {
        XCTAssertEqual(service.listAvailableBackups(), [])
    }

    func testSingleValidBackupAppearsWithCorrectCounts() throws {
        _ = try makeBackup(
            name: "2026-08-01_120000.000",
            files: [
                "items.json": Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\"}]".utf8),
                "tags.json": Data("[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"t\",\"colorHex\":\"#fff\",\"isAutoSuggested\":false,\"createdAt\":0}]".utf8),
            ]
        )
        let result = service.listAvailableBackups()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].directoryName, "2026-08-01_120000.000")
        XCTAssertEqual(result[0].itemsCount, 1)
        XCTAssertEqual(result[0].tagsCount, 1)
        XCTAssertEqual(result[0].imagesCount, 0)
        XCTAssertFalse(result[0].isIncomplete)
    }

    func testIncompleteKeptWithMarkerSet() throws {
        _ = try makeBackup(name: "2026-08-01_120000.000")
        _ = try makeBackup(name: "2026-08-02_120000.000", incomplete: true)
        let result = service.listAvailableBackups()
        XCTAssertEqual(result.count, 2)
        let incomplete = result.first(where: { $0.isIncomplete })
        XCTAssertNotNil(incomplete)
        XCTAssertEqual(incomplete?.directoryName, "2026-08-02_120000.000")
    }

    func testNonTimestampedDirectoryExcluded() throws {
        _ = try makeBackup(name: "not-a-timestamp")
        XCTAssertEqual(service.listAvailableBackups(), [])
    }

    func testMissingItemsJSONProducesNilCount() throws {
        _ = try makeBackup(name: "2026-08-01_120000.000", files: ["tags.json": Data("[]".utf8)])
        let result = service.listAvailableBackups()
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].itemsCount)
        XCTAssertEqual(result[0].tagsCount, 0)
    }

    func testNewestFirstSort() throws {
        _ = try makeBackup(name: "2026-08-01_120000.000")
        _ = try makeBackup(name: "2026-08-03_120000.000")
        _ = try makeBackup(name: "2026-08-02_120000.000")
        let result = service.listAvailableBackups()
        XCTAssertEqual(result.map(\.directoryName), [
            "2026-08-03_120000.000",
            "2026-08-02_120000.000",
            "2026-08-01_120000.000",
        ])
    }
}
